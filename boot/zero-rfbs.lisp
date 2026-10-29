;;;; zero-rfbs.lisp — the Zero's desk as an RFB server over the board's SOCKETS.
;;;;
;;;; zero-rfb.lisp serves the desk on net/ip.lisp's single TCP connection, from the USB thread,
;;;; for a gateway at the other end of the cable.  The gateway now runs ON the board
;;;; (zero-gateway.lisp) and reaches the desk over LOOPBACK -- which is modus's many-connection
;;;; TCP (net/tcp-conns.lisp), not the kernel's one connection -- so this is the same server on
;;;; SB-BSD-SOCKETS.
;;;;
;;;; NO THREADS OF ITS OWN.  It used to be a listener thread and, per client, a reader and a sender
;;;; -- and modus never gives an exited thread's slot back, so every session the phone opened cost
;;;; the board two of its twelve slots for good.  It now runs on an event loop (cl-transport's,
;;;; the gateway's own NET-LOOP when RFBS-START is given it): the listener and each client are
;;;; socket watches, the client's messages are parsed from whatever bytes have arrived, and the
;;;; sender is a 10 ms timer.  Writes do not wait: a loopback write appends to the peer's buffer.
;;;;
;;;; RFB 3.8, security None, out of the HDMI scanout buffer (32-bit XRGB, BGRX in memory; swapped
;;;; to RGBX when the client asks for red at shift 0, noVNC's default).  ZRLE when the client
;;;; offers it (one persistent zlib stream per client, cram), else TRLE, else Raw: a raw 640x480
;;;; frame is 1.2 MB, and through DTLS on a Zero the link carries a few KB/s.  An incremental
;;;; request is answered with the rows that changed since the last update, as one rectangle;
;;;; nothing changed, the sender looks again in 10 ms (a look with nothing drawn is one compare).
;;;;
;;;;   (kiln-zero-rfbs:rfbs-start :loop L)    ; 127.0.0.1:5900; :address "0.0.0.0" to open it up

(defpackage #:kiln-zero-rfbs
  (:use #:cl)
  (:export #:rfbs-start #:rfbs-stop #:rfbs-status #:*rfbs-port*))
(in-package #:kiln-zero-rfbs)

(defvar *rfbs-port* 5900)
(defvar *listener* nil)
(defvar *loop* nil "The event loop this server runs on.")
(defvar *clients* nil)
(defvar *lock* nil "Guards *CLIENTS* and *EVENTS*.")
(defvar *events* nil "Desk events from clients, newest first (the desk's encoding, kiln-zero).")

(defclass client ()
  ((sock :initarg :sock :reader cl-sock)              ; cl-transport TCP-SOCKET
   (in :initform (make-array 0 :element-type '(unsigned-byte 8)) :accessor cl-in) ; unparsed bytes
   (out :initform (make-array 4096 :element-type '(unsigned-byte 8) :fill-pointer 0 :adjustable t)
        :accessor cl-out)                               ; what the next %FLUSH sends
   (phase :initform :version :accessor cl-phase)      ; :version :security :init :normal
   (timer :initform nil :accessor cl-timer)           ; the sender's tick
   (seen :initform nil :accessor cl-seen)             ; *KZ-DAMAGE* at the last look
   (looked :initform 0 :accessor cl-looked)           ; when that was
   (sent :initform nil :accessor cl-sent)             ; per row, the desk's stamp last sent
   (want :initform nil :accessor cl-want)            ; NIL, :incremental or :full
   (ahead :initform 1 :accessor cl-ahead)            ; updates we may send before one is asked for
   (swap :initform nil :accessor cl-swap)            ; client wants red at shift 0
   (bpp :initform 32 :accessor cl-bpp)               ; the client's pixel format: 32, or 16 ...
   (shifts :initform '(16 8 0) :accessor cl-shifts)  ; ... red green blue shifts (16 bpp: 0 5 10)
   (mask :initform 0 :accessor cl-mask)              ; pointer buttons last seen
   (prev :initform nil :accessor cl-prev)            ; the frame last sent, rows of bytes
   (scratch :initform nil :accessor cl-scratch)      ; rows being compared against PREV
   (frames :initform 0 :accessor cl-frames)
   (encodings :initform nil :accessor cl-encodings) ; what SetEncodings offered
   (zs :initform nil :accessor cl-zs)                ; the connection's zlib stream (ZRLE)
   (bytes :initform 0 :accessor cl-bytes)            ; encoded bytes sent
   (open :initform t :accessor cl-open)))

;;; cl-transport is loaded after this file in a core, so its functions are named at call time
(defun %ct (pkg name &rest args)
  (apply (symbol-function (find-symbol name pkg)) args))
(defun %lp (name &rest args) (apply #'%ct "CL-TRANSPORT.LOOP" name args))
(defun %sk (name &rest args) (apply #'%ct "CL-TRANSPORT.SOCKETS" name args))

;;; ---- the screen ---------------------------------------------------------------------------

(defun %geometry ()
  "(values scanout-address pitch width height) of the HDMI console's framebuffer."
  (values (modus-int::hcon-get #x04) (modus-int::hcon-get #x08)
          (modus-int::hcon-get #x0C) (modus-int::hcon-get #x10)))

(defun %data-address (v)
  "Where byte vector V's elements start (V must not move before the address is used)."
  (+ (modus-int::%gc-word-of v (modus-int::%conv-addr #x100050A0)) 7))

(defun %row-diff (a b)
  "(values FIRST LAST+1), the byte range where row buffers A and B differ, or NIL -- four bytes
   per load.  CL:MISMATCH did this a byte at a time through the generic sequence path and was
   99% of the sender's time on the board."
  (let* ((n (floor (length a) 4)) (pa (%data-address a)) (pb (%data-address b)) (lo nil))
    (dotimes (k n)
      (unless (eql (cl-user::mem-ref (+ pa (* 4 k)) :u32) (cl-user::mem-ref (+ pb (* 4 k)) :u32))
        (setf lo k)
        (return)))
    (when lo
      (let ((hi lo))
        (loop for k from (1- n) above lo
              do (unless (eql (cl-user::mem-ref (+ pa (* 4 k)) :u32)
                              (cl-user::mem-ref (+ pb (* 4 k)) :u32))
                   (setf hi k)
                   (return)))
        (values (* 4 lo) (* 4 (1+ hi)))))))

(defun %copy-rows (rows y0 y1)
  "Scanout rows Y0..Y1-1 into the byte vectors of ROWS, with the console's native copy -- in ONE
   call on the screen thread when there is one (it uses the same scratch block for its presents).
   A call per row was 480 cross-core round trips a frame."
  (multiple-value-bind (fb pitch w) (%geometry)
    (let* ((rb (* 4 w))
           (fn (lambda ()
                 (loop for y from y0 below y1
                       do (modus-int::hcon-ncopy (%data-address (aref rows y)) (+ fb (* y pitch)) rb))
                 0))
           (scr (and (boundp 'cl-user::*kz-scr*) (symbol-value 'cl-user::*kz-scr*))))
      (if scr (modus-int::bt-call scr fn) (funcall fn))
      rows)))

(defun %row-buffers (prev)
  "PREV when it is a vector of row buffers the screen's shape, else a fresh one."
  (multiple-value-bind (fb pitch w h) (%geometry)
    (declare (ignore fb pitch))
    (let ((rb (* 4 w)))
      (if (and prev (= (length prev) h) (= (length (aref prev 0)) rb))
          prev
          (let ((v (make-array h)))
            (dotimes (y h v)
              (setf (aref v y) (make-array rb :element-type '(unsigned-byte 8)))))))))

(defun %grab (prev)
  "The screen now, as a fresh vector of row byte vectors (PREV is left as it was)."
  (let ((rows (%row-buffers nil)))
    (declare (ignorable prev))
    (%copy-rows rows 0 (length rows))))

;;; ---- writing ------------------------------------------------------------------------------
;;; Into the client's OUT buffer; %FLUSH sends it in one write.

(defun %room (c n)
  "C's OUT buffer, with room for N more bytes (ADJUST-ARRAY's result kept, not assumed EQ)."
  (let* ((out (cl-out c)) (need (+ (fill-pointer out) n)))
    (if (<= need (array-dimension out 0))
        out
        (setf (cl-out c) (adjust-array out (max need (* 2 (array-dimension out 0))))))))
(defun %u8 (c n)
  (let* ((out (%room c 1)) (fp (fill-pointer out)))
    (setf (fill-pointer out) (1+ fp) (aref out fp) (logand n 255))))
(defun %u16 (c n) (%u8 c (ash n -8)) (%u8 c n))
(defun %u32 (c n) (%u16 c (ash n -16)) (%u16 c (logand n #xFFFF)))
(defun %put (c v &key (end (length v)))
  (let* ((out (%room c end)) (fp (fill-pointer out)))
    (setf (fill-pointer out) (+ fp end))
    (replace out v :start1 fp :end2 end)))

(defun %flush (c)
  (let ((out (cl-out c)))
    (when (plusp (fill-pointer out))
      (let ((r (%sk "TCP-WRITE" (cl-sock c) (subseq out 0 (fill-pointer out)))))
        ;; a raw frame grows the buffer to a megabyte; don't keep it between frames
        (if (> (array-dimension out 0) 65536)
            (setf (cl-out c) (make-array 4096 :element-type '(unsigned-byte 8)
                                              :fill-pointer 0 :adjustable t))
            (setf (fill-pointer out) 0))
        (unless (eq r :ok) (error "rfbs: client went away"))))))

;;; ---- ZRLE / TRLE tiles (RFC 6143 7.7.5-6) ---------------------------------------------------
;;; Each tile goes out in whichever subencoding is smallest: solid (1), packed palette of <= 16
;;; colours (2..16), plain RLE (128), palette RLE of <= 127 colours (130..255), or raw CPIXELs (0).
;;; Flat UI is mostly runs, and a tile with a gradient or text antialiasing still RLEs to a fraction
;;; of its raw size -- which matters because deflate's time goes with the bytes it is fed.
;;; CPIXELs are 3 bytes: the low three of the client's 32-bit pixel -- B,G,R natively, R,G,B for a
;;; client that asked for red at shift 0.  The palette is searched linearly, but only when the
;;; pixel differs from the one before it, so a run costs one compare per pixel.

(defun %pack-tiles (rows y0 y1 tile fmt &optional (x0 0) x1)
  "Rows Y0..Y1-1, columns X0..X1-1 (all of them by default), as TILE-pixel tiles: (values BUF LEN).  FMT is the CPIXEL: :BGR or :RGB (3
   bytes), or the (RED GREEN BLUE) shifts of a 16-bit 5:5:5 pixel (2 bytes, little-endian)."
  (let* ((rb (length (aref rows 0))) (w (- (or x1 (floor rb 4)) x0)) (h (- y1 y0))
         (cp (if (or (eq fmt :bgr) (eq fmt :rgb)) 3 2))
         (buf (make-array (+ (* w h cp) (* (ceiling w tile) (ceiling h tile) 52) 16)
                          :element-type '(unsigned-byte 8)))
         (pal (make-array 127 :initial-element 0)) (i 0))
    ;; A pixel is one 32-bit load at the row's data address (taken per row: nothing in a row's
    ;; loop allocates, so the row cannot move under it).  Three AREFs a pixel were most of the
    ;; sender's time on the board.
    (labels ((px (ra x) (logand (cl-user::mem-ref (+ ra (* 4 x)) :u32) #xFFFFFF))
             (cpix (p)
               (let ((b (logand p 255)) (g (logand (ash p -8) 255)) (r (ash p -16)))
                 (cond ((eq fmt :bgr)
                        (setf (aref buf i) b (aref buf (+ i 1)) g (aref buf (+ i 2)) r) (incf i 3))
                       ((eq fmt :rgb)
                        (setf (aref buf i) r (aref buf (+ i 1)) g (aref buf (+ i 2)) b) (incf i 3))
                       (t (let ((v (logior (ash (ash r -3) (first fmt)) (ash (ash g -3) (second fmt))
                                           (ash (ash b -3) (third fmt)))))
                            (setf (aref buf i) (logand v 255) (aref buf (+ i 1)) (ash v -8))
                            (incf i 2))))))
             (%slot (p n) (dotimes (k n nil) (when (= (svref pal k) p) (return k))))
             (run-length (len)                      ; LEN-1 as 255s and a final byte < 255
               (let ((v (1- len)))
                 (loop while (>= v 255) do (setf (aref buf i) 255) (incf i) (decf v 255))
                 (setf (aref buf i) v) (incf i))))
      (loop for ty from 0 below h by tile for th = (min tile (- h ty)) do
        (loop for tx from 0 below w by tile for tw = (min tile (- w tx)) do
          ;; Pass 1: the palette (up to 127), the runs, and what each RLE form would cost.
          (let ((n 0) (over nil) (runs 0) (plen 0) (rlb 0) (prev -1) (len 0))
            (flet ((close-run ()
                     (let ((lb (1+ (floor (1- len) 255))))
                       (incf runs) (incf plen lb) (incf rlb (if (= len 1) 1 (1+ lb))))))
              (dotimes (ly th)
                (let ((row (%data-address (aref rows (+ y0 ty ly)))))
                  (dotimes (lx tw)
                    (let ((p (px row (+ x0 tx lx))))
                      (if (= p prev)
                          (incf len)
                          (progn
                            (when (plusp len) (close-run))
                            (setf prev p len 1)
                            (unless (or over (%slot p n))
                              (if (= n 127) (setf over t)
                                  (progn (setf (svref pal n) p) (incf n))))))))))
              (close-run))
            (let* ((raw (* tw th cp))
                   (prle (+ (* runs cp) plen))
                   (bpp (cond ((<= n 2) 1) ((<= n 4) 2) (t 4)))
                   (packed (if (and (not over) (<= n 16)) (+ (* n cp) (* th (ceiling (* tw bpp) 8))) raw))
                   (palrle (if over raw (+ (* n cp) rlb)))
                   (best (min raw prle packed palrle)))
              (cond
                ((and (not over) (= n 1)) (setf (aref buf i) 1) (incf i) (cpix (svref pal 0)))
                ((= best raw)
                 (setf (aref buf i) 0) (incf i)
                 (dotimes (ly th)
                   (let ((row (%data-address (aref rows (+ y0 ty ly)))))
                     (dotimes (lx tw) (cpix (px row (+ x0 tx lx)))))))
                ((= best packed)
                 (setf (aref buf i) n) (incf i)
                 (dotimes (k n) (cpix (svref pal k)))
                 (let ((lp -1) (li 0))
                   (dotimes (ly th)
                     (let ((row (%data-address (aref rows (+ y0 ty ly)))) (acc 0) (nbits 0))
                       (dotimes (lx tw)
                         (let ((p (px row (+ x0 tx lx))))
                           (unless (= p lp) (setf lp p li (%slot p n)))
                           (setf acc (logior (ash acc bpp) li)))
                         (incf nbits bpp)
                         (when (>= nbits 8)
                           (decf nbits 8)
                           (setf (aref buf i) (logand (ash acc (- nbits)) 255)) (incf i)
                           (setf acc (logand acc (1- (ash 1 nbits))))))
                       (when (plusp nbits)
                         (setf (aref buf i) (logand (ash acc (- 8 nbits)) 255)) (incf i))))))
                (t
                 ;; Pass 2: the runs again, as plain RLE (CPIXEL + length) or palette RLE (index,
                 ;; with bit 7 set and a length after it when the run is longer than one pixel).
                 (let ((pl (= best palrle)) (prev -1) (len 0))
                   (setf (aref buf i) (if pl (+ 128 n) 128)) (incf i)
                   (when pl (dotimes (k n) (cpix (svref pal k))))
                   (flet ((emit-run ()
                            (if pl
                                (let ((k (%slot prev n)))
                                  (if (= len 1)
                                      (progn (setf (aref buf i) k) (incf i))
                                      (progn (setf (aref buf i) (+ 128 k)) (incf i) (run-length len))))
                                (progn (cpix prev) (run-length len)))))
                     (dotimes (ly th)
                       (let ((row (%data-address (aref rows (+ y0 ty ly)))))
                         (dotimes (lx tw)
                           (let ((p (px row (+ x0 tx lx))))
                             (if (= p prev)
                                 (incf len)
                                 (progn (when (plusp len) (emit-run))
                                        (setf prev p len 1)))))))
                     (emit-run)))))))))
      (values buf i))))

(defun %cpixel-format (c)
  "The CPIXEL a tile carries for client C.  At 32 bpp glass's B,G,R -- what glass's own server
   sends and what the shell's noVNC reads, whatever shifts it asked for; at 16 bpp the client's
   5:5:5 layout."
  (if (= (cl-bpp c) 16) (cl-shifts c) :bgr))

(defun %encoding (c)
  (let ((e (cl-encodings c)))
    (cond ((member 16 e) 16) ((member 15 e) 15) (t 0))))

(defun %send-rows (c rows y0 y1 &optional (x0 0) x1)
  "Rows Y0..Y1-1, columns X0..X1-1 (all by default), as one FramebufferUpdate of one rectangle, in
   the best encoding the client offered (ZRLE, TRLE, Raw -- Raw always sends whole rows)."
  (let* ((enc (%encoding c))
         (x0 (if (member enc '(16 15)) x0 0))
         (x1 (if (member enc '(16 15)) (or x1 (floor (length (aref rows 0)) 4)) (floor (length (aref rows 0)) 4))))
    (%u8 c 0) (%u8 c 0) (%u16 c 1)                         ; FramebufferUpdate, 1 rectangle
    (%u16 c x0) (%u16 c y0) (%u16 c (- x1 x0)) (%u16 c (- y1 y0)) (%u32 c enc)
    (case enc
      (16 (multiple-value-bind (buf len) (%pack-tiles rows y0 y1 64 (%cpixel-format c) x0 x1)
            (let ((zs (or (cl-zs c) (setf (cl-zs c) (cram:make-zstream :max-chain 16)))))
              (cram:compress zs buf :end len)
              (let ((z (cram:sync-flush zs)))
                (%u32 c (length z)) (%put c z)
                (incf (cl-bytes c) (+ 4 (length z)))))))
      (15 (multiple-value-bind (buf len) (%pack-tiles rows y0 y1 16 (%cpixel-format c) x0 x1)
            (%put c buf :end len)
            (incf (cl-bytes c) len)))
      (t (%send-raw-rows c rows y0 y1)))
    (%flush c)
    (incf (cl-frames c))))

(defun %send-raw-rows (c rows y0 y1)
  (incf (cl-bytes c) (* (- y1 y0) (length (aref rows 0))))
  (loop for y from y0 below y1
        do (let ((row (aref rows y)))
             (cond
               ((= (cl-bpp c) 16)                         ; 5:5:5, little-endian
                (let* ((sh (cl-shifts c)) (n (floor (length row) 4))
                       (out (make-array (* 2 n) :element-type '(unsigned-byte 8))))
                  (dotimes (k n)
                    (let* ((o (* 4 k))
                           (v (logior (ash (ash (aref row (+ o 2)) -3) (first sh))
                                      (ash (ash (aref row (+ o 1)) -3) (second sh))
                                      (ash (ash (aref row o) -3) (third sh)))))
                      (setf (aref out (* 2 k)) (logand v 255) (aref out (1+ (* 2 k))) (ash v -8))))
                  (%put c out)))
               ((cl-swap c)
                (let ((out (copy-seq row)))
                  (loop for i from 0 below (length out) by 4
                        do (rotatef (aref out i) (aref out (+ i 2))))
                  (%put c out)))
               (t (%put c row))))))

(defun %changed (prev rows)
  "(values first last+1) of the rows of ROWS that differ from PREV, or NIL."
  (let ((y0 nil) (y1 nil))
    (dotimes (y (length rows))
      (when (or (null prev) (mismatch (aref prev y) (aref rows y)))
        (unless y0 (setf y0 y))
        (setf y1 (1+ y))))
    (and y0 (values y0 y1))))

(defun %damage ()
  "The desk's draw counter (kiln-zero *KZ-DAMAGE*), or NIL without a desk."
  (and (boundp 'cl-user::*kz-damage*) (symbol-value 'cl-user::*kz-damage*)))

(defun %row-gen ()
  "The desk's per-row draw stamps (kiln-zero *KZ-ROW-GEN*), or NIL without a desk."
  (and (boundp 'cl-user::*kz-row-gen*) (symbol-value 'cl-user::*kz-row-gen*)))

(defun %sender-tick (c)
  (if (%row-gen) (%send-stamped c) (%sender-tick-compare c)))

(defun %send-stamped (c)
  "Send the rows the desk has drawn since they were last sent: no screen copy, no compare, to
   find them -- only the band that changed is copied.  A full request sends everything."
  (let* ((asked (cl-want c)) (gens (%row-gen))
         ;; ONE UPDATE AHEAD: noVNC asks for the next update only once this one arrives, so
         ;; waiting for the ask costs a round trip per frame (0.3-0.7 s on cellular).  With a
         ;; prior frame sent, one more may go unasked; the ask it draws restores the credit.
         (want (or asked (and (cl-prev c) (> (cl-ahead c) 0) :incremental))))
    ;; NOTHING DRAWN SINCE THE LAST LOOK: one compare, so the sender can look every few ms.  SEEN
    ;; is the counter a look found every row stamp caught up with -- or, when the counter was
    ;; ahead of them all, (COUNTER), and the NEXT look settles it.  The counter runs ahead for
    ;; two reasons: draws that stamp no row (the board's fill/blit/present calls), and
    ;; %KZ-TOUCH bumping it before it stamps, from another thread.  The second must not mark the
    ;; rows about to be stamped as seen; one more look gives that thread its time.
    (let ((dmg (%damage)) (seen (cl-seen c)))
      (when (and (eq want :incremental) (cl-prev c) (eql dmg seen))
        (setf want nil)))
    (when want
      (multiple-value-bind (fb pitch w h) (%geometry)
        (declare (ignore fb pitch w))
        (let ((sent (or (cl-sent c) (setf (cl-sent c) (make-array h :initial-element -1))))
              (y0 nil) (y1 nil))
          (if (or (eq want :full) (null (cl-prev c)))
              (setf y0 0 y1 h)
              (let ((newest 0))
                (dotimes (y h)
                  (let ((g (svref gens y)))
                    (when (> g newest) (setf newest g))
                    (unless (eql g (svref sent y))
                      (unless y0 (setf y0 y))
                      (setf y1 (1+ y)))))
                (let ((dmg (%damage)) (seen (cl-seen c)))
                  (setf (cl-seen c)
                        (cond ((>= newest dmg) dmg)
                              ((and (consp seen) (eql (car seen) dmg)) dmg)
                              (t (list dmg)))))))
          (when y0
            ;; the stamps are recorded BEFORE the copy: a draw landing after this is resent
            (loop for y from y0 below y1 do (setf (svref sent y) (svref gens y)))
            (if (or (eq want :full) (null (cl-prev c)))
                (let ((rows (%copy-rows (%row-buffers (cl-prev c)) y0 y1)))
                  (if asked (setf (cl-want c) nil) (decf (cl-ahead c)))
                  (setf (cl-prev c) rows)
                  (%send-rows c rows y0 y1))
                ;; A STAMP SAYS A ROW WAS DRAWN, NOT THAT IT CHANGED: the desk repaints rows whose
                ;; pixels come out the same, and a band of them cost a near-full-frame encode per
                ;; update on the board.  So copy the band aside, keep only what differs from what
                ;; this client last got, and send that rectangle.
                (let* ((prev (cl-prev c))
                       (scr (setf (cl-scratch c) (%row-buffers (cl-scratch c))))
                       (cy0 nil) (cy1 nil) (bx0 nil) (bx1 nil))
                  (%copy-rows scr y0 y1)
                  (loop for y from y0 below y1
                        do (let ((a (aref scr y)) (b (aref prev y)))
                             (multiple-value-bind (m e) (%row-diff a b)
                               (when m
                                 (unless cy0 (setf cy0 y))
                                 (setf cy1 (1+ y)
                                       bx0 (if bx0 (min bx0 m) m)
                                       bx1 (if bx1 (max bx1 e) e))
                                 (replace b a)))))
                  (when cy0
                    (if asked (setf (cl-want c) nil) (decf (cl-ahead c)))
                    (%send-rows c prev cy0 cy1 (floor bx0 4) (ceiling bx1 4)))))))))))

(defun %sender-tick-compare (c)
  ;; WITHOUT A DESK (the text console): the screen is copied and compared
  ;; once a second.
  (let ((want (cl-want c)) (dmg (%damage)) (now (get-internal-real-time)))
    (unless (or (null want)
                (and (eq want :incremental) (cl-prev c) (eql dmg (cl-seen c))
                     (< (- now (cl-looked c)) internal-time-units-per-second)))
      (setf (cl-seen c) dmg (cl-looked c) now)
      (%send-if-changed c want))))

(defun %send-if-changed (c want)
  "Grab the screen; send what changed (all of it for a :FULL request or a first update)."
  (let ((rows (%grab (cl-prev c))))
    (multiple-value-bind (y0 y1)
        (if (or (eq want :full) (null (cl-prev c)))
            (values 0 (length rows))
            (%changed (cl-prev c) rows))
      (when y0
        (setf (cl-want c) nil)
        (%send-rows c rows y0 y1)
        (setf (cl-prev c) rows)))))

;;; ---- reading ------------------------------------------------------------------------------
;;; Whatever bytes have arrived are appended to IN, and every message that is WHOLE is taken off
;;; the front; a partial one waits for the next read.  NEED says how long the message at the
;;; front is, or NIL while that is not yet known.

(defun %event (e)
  (sb-thread:with-mutex (*lock*) (push e *events*)))

(defun %ev (type x y) (+ (* type 1099511627776) (* y 1048576) x))

(defun %be (v i n) (let ((x 0)) (dotimes (k n x) (setf x (+ (* 256 x) (aref v (+ i k)))))))

(defun %need (c in)
  "Bytes the message at the front of IN takes, or NIL when IN does not yet say."
  (let ((n (length in)))
    (case (cl-phase c)
      (:version 12)
      ((:security :init) 1)
      (t (when (plusp n)
           (case (aref in 0)
             (0 20) (3 10) (4 8) (5 6)
             (2 (and (>= n 4) (+ 4 (* 4 (%be in 2 2)))))
             (6 (and (>= n 8) (+ 8 (%be in 4 4))))
             (t (error "rfbs: unknown client message ~a" (aref in 0)))))))))

(defun %server-init (c)
  (multiple-value-bind (fb pitch w h) (%geometry)
    (declare (ignore fb pitch))
    (%u16 c w) (%u16 c h)
    (dolist (b '(32 24 0 1 0 255 0 255 0 255 16 8 0 0 0 0)) (%u8 c b))
    (let ((name "kiln zero"))
      (%u32 c (length name))
      (%put c (map '(vector (unsigned-byte 8)) #'char-code name)))))

(defun %message (c m)
  "One whole message M (a byte vector, type byte included)."
  (case (cl-phase c)
    (:version (%u8 c 1) (%u8 c 1) (setf (cl-phase c) :security))      ; one security type: None
    (:security (%u32 c 0) (setf (cl-phase c) :init))                  ; SecurityResult OK
    (:init (%server-init c) (setf (cl-phase c) :normal)               ; ClientInit -> ServerInit
     (%desk-pointer nil))
    (t
     (case (aref m 0)
       (0 (let ((pf (subseq m 1)))                                    ; SetPixelFormat
            (setf (cl-swap c) (and (= (aref pf 13) 0) (= (aref pf 15) 16))
                  (cl-bpp c) (if (= (aref pf 3) 16) 16 32)
                  (cl-shifts c) (list (aref pf 13) (aref pf 14) (aref pf 15)))))
       (2 (setf (cl-encodings c)                                      ; SetEncodings
                (loop for k from 4 below (length m) by 4
                      collect (let ((e (%be m k 4)))
                                (if (>= e #x80000000) (- e #x100000000) e)))))
       (3 (when (cl-want c) (setf (cl-ahead c) (min 1 (1+ (cl-ahead c)))))  ; asked for one sent ahead
          (setf (cl-want c) (if (zerop (aref m 1)) :full (or (cl-want c) :incremental))))
       (4 (when (= (aref m 1) 1)                                      ; KeyEvent: down, keysym
            (%event (+ (* 4 1099511627776) (%be m 4 4)))))
       (5 (let* ((nb (aref m 1)) (x (%be m 2 2)) (y (%be m 4 2))     ; PointerEvent
                 (down (logbitp 0 nb)) (was (logbitp 0 (cl-mask c))))
            (%event (%ev (cond ((and down (not was)) 1) ((and was (not down)) 3) (down 2) (t 5)) x y))
            (setf (cl-mask c) nb)))
       (6 nil)))))                                                    ; ClientCutText: ignored

(defun %readable (c)
  "The client's socket has input: take it, act on every whole message."
  (multiple-value-bind (bytes eof) (%sk "TCP-READ-AVAILABLE" (cl-sock c))
    (let ((in (if (plusp (length (cl-in c))) (concatenate '(vector (unsigned-byte 8)) (cl-in c) bytes) bytes)))
      (loop
        (let ((n (%need c in)))
          (unless (and n (>= (length in) n)) (return))
          (%message c (subseq in 0 n))
          (setf in (subseq in n))))
      (setf (cl-in c) in)
      (%flush c)
      (when eof (%drop c)))))

;;; ---- the desk's pointer ----------------------------------------------------------------
;;; An RFB client draws its own pointer, so while one is connected the desk draws none into the
;;; scanout (kiln-zero *KZ-POINTER-OFF*): a second, lagging arrow in the picture, and every move
;;; of it rows to send.  Back on the HDMI screen when the last client leaves.

(defun %on-screen (fn)
  (if (fboundp 'cl-user::%kz-on-screen) (cl-user::%kz-on-screen fn) (funcall fn)))

(defun %desk-pointer (on)
  (when (boundp 'cl-user::*kz-pointer-off*)
    (setf (symbol-value 'cl-user::*kz-pointer-off*) (not on))
    (when (and (fboundp 'cl-user::%zero-pointer-hide) (fboundp 'cl-user::%zero-pointer-show))
      (%on-screen (if on
                      (lambda () (cl-user::%zero-pointer-show) 0)
                      (lambda () (cl-user::%zero-pointer-hide) 0))))))

;;; ---- a client -----------------------------------------------------------------------------

(defun %drop (c)
  "End client C: no more reads, no more ticks."
  (when (cl-open c)
    (setf (cl-open c) nil)
    (ignore-errors (%lp "CANCEL" *loop* (cl-timer c)))
    (ignore-errors (%lp "UNWATCH" *loop* (cl-sock c)))
    (ignore-errors (%sk "TCP-CLOSE" (cl-sock c)))
    (sb-thread:with-mutex (*lock*) (setf *clients* (remove c *clients*)))
    (unless (find :normal *clients* :key #'cl-phase)
      (ignore-errors (%desk-pointer t)))))

(defun %guarded (c fn)
  "FN of C, and an error ends C rather than reaching the loop."
  (handler-case (funcall fn c)
    (error () (%drop c))))

(defun %accept (listener)
  (let ((ts (%sk "TCP-ACCEPT" listener :timeout-ms 0)))
    (when ts
      (let ((c (make-instance 'client :sock ts)))
        (sb-thread:with-mutex (*lock*) (push c *clients*))
        (%put c (map '(vector (unsigned-byte 8)) #'char-code (format nil "RFB 003.008~c" #\Newline)))
        (%guarded c #'%flush)
        (when (cl-open c)
          (%lp "WATCH" *loop* ts (lambda (s) (declare (ignore s)) (%guarded c #'%readable))
               :what "rfbs client")
          (setf (cl-timer c)
                (%lp "EVERY-SECONDS" *loop* 0.01
                     (lambda ()
                       (when (eq (cl-phase c) :normal) (%guarded c #'%sender-tick)))
                     :what "rfbs sender")))))))

;;; ---- the server ---------------------------------------------------------------------------

(defun %take-events ()
  "The desk's event source: what clients sent since the last call, oldest first."
  (when *events*
    (sb-thread:with-mutex (*lock*) (prog1 (nreverse *events*) (setf *events* nil)))))

(defun rfbs-start (&key (port *rfbs-port*) (address "127.0.0.1") loop)
  "Serve the desk on ADDRESS:PORT, on LOOP (a cl-transport event loop -- the gateway's).  Without
   one it makes one and gives it the one thread it needs."
  (unless *lock* (setf *lock* (sb-thread:make-mutex :name "rfbs")))
  (let ((l (%sk "TCP-LISTEN" :host address :port port :backlog 4))
        (lp (or loop (%lp "MAKE-EVENT-LOOP"))))
    (setf *listener* l *loop* lp)
    (setf (symbol-value 'cl-user::*kz-event-source*) #'%take-events)
    (flet ((arm () (%lp "WATCH" lp l (lambda (s) (ignore-errors (%accept s))) :what "rfbs listen")))
      (if loop
          (%lp "POST" lp #'arm)       ; the loop may be turning on another thread already
          (progn (arm)
                 (sb-thread:make-thread (lambda () (%lp "RUN" lp)) :name "rfbs-loop"))))
    l))

(defun rfbs-stop ()
  (let ((l *listener*) (lp *loop*))
    (setf *listener* nil)
    (when lp
      (%lp "POST" lp (lambda ()
                       (when l (%lp "UNWATCH" lp l) (%sk "TCP-LISTENER-CLOSE" l))
                       (dolist (c *clients*) (%drop c)))))
    t))

(defun rfbs-status ()
  (mapcar (lambda (c) (list :frames (cl-frames c) :bytes (cl-bytes c) :encoding (%encoding c)
                            :swap (cl-swap c) :open (cl-open c) :phase (cl-phase c)))
          *clients*))
