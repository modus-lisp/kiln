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
;;;; sender is a 30 ms timer.  Writes do not wait: a loopback write appends to the peer's buffer.
;;;;
;;;; RFB 3.8, security None, out of the HDMI scanout buffer (32-bit XRGB, BGRX in memory; swapped
;;;; to RGBX when the client asks for red at shift 0, noVNC's default).  ZRLE when the client
;;;; offers it (one persistent zlib stream per client, cram), else TRLE, else Raw: a raw 640x480
;;;; frame is 1.2 MB, and through DTLS on a Zero the link carries a few KB/s.  An incremental
;;;; request is answered with the rows that changed since the last update, as one rectangle;
;;;; nothing changed, the sender looks again in 30 ms.
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
   (swap :initform nil :accessor cl-swap)            ; client wants red at shift 0
   (bpp :initform 32 :accessor cl-bpp)               ; the client's pixel format: 32, or 16 ...
   (shifts :initform '(16 8 0) :accessor cl-shifts)  ; ... red green blue shifts (16 bpp: 0 5 10)
   (mask :initform 0 :accessor cl-mask)              ; pointer buttons last seen
   (prev :initform nil :accessor cl-prev)            ; the frame last sent, rows of bytes
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
;;; A tile is solid (subencoding 1), a packed palette of <= 16 colours (2..16), or raw CPIXELs (0).
;;; CPIXELs are 3 bytes: the low three of the client's 32-bit pixel -- B,G,R natively, R,G,B for a
;;; client that asked for red at shift 0.  The palette is a 16-slot vector searched linearly: no
;;; hashing per pixel.

(defun %pack-tiles (rows y0 y1 tile fmt)
  "Rows Y0..Y1-1 as TILE-pixel tiles: (values BUF LEN).  FMT is the CPIXEL: :BGR or :RGB (3
   bytes), or the (RED GREEN BLUE) shifts of a 16-bit 5:5:5 pixel (2 bytes, little-endian)."
  (let* ((rb (length (aref rows 0))) (w (floor rb 4)) (h (- y1 y0))
         (buf (make-array (+ (* w h 3) (* (ceiling w tile) (ceiling h tile) 52) 16)
                          :element-type '(unsigned-byte 8)))
         (pal (make-array 16 :initial-element 0)) (i 0))
    (labels ((px (row x) (let ((o (* 4 x)))
                           (logior (aref row o) (ash (aref row (+ o 1)) 8) (ash (aref row (+ o 2)) 16))))
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
             (%slot (p n) (dotimes (k n nil) (when (= (svref pal k) p) (return k)))))
      (loop for ty from 0 below h by tile for th = (min tile (- h ty)) do
        (loop for tx from 0 below w by tile for tw = (min tile (- w tx)) do
          (let ((n 0) (over nil))
            (block scan
              (dotimes (ly th)
                (let ((row (aref rows (+ y0 ty ly))))
                  (dotimes (lx tw)
                    (let ((p (px row (+ tx lx))))
                      (unless (%slot p n)
                        (when (= n 16) (setf over t) (return-from scan))
                        (setf (svref pal n) p) (incf n)))))))
            (cond
              (over
               (setf (aref buf i) 0) (incf i)
               (dotimes (ly th)
                 (let ((row (aref rows (+ y0 ty ly))))
                   (dotimes (lx tw) (cpix (px row (+ tx lx)))))))
              ((= n 1) (setf (aref buf i) 1) (incf i) (cpix (svref pal 0)))
              (t
               (let ((bpp (cond ((<= n 2) 1) ((<= n 4) 2) (t 4))))
                 (setf (aref buf i) n) (incf i)
                 (dotimes (k n) (cpix (svref pal k)))
                 (dotimes (ly th)
                   (let ((row (aref rows (+ y0 ty ly))) (acc 0) (nbits 0))
                     (dotimes (lx tw)
                       (setf acc (logior (ash acc bpp) (%slot (px row (+ tx lx)) n)))
                       (incf nbits bpp)
                       (when (>= nbits 8)
                         (decf nbits 8)
                         (setf (aref buf i) (logand (ash acc (- nbits)) 255)) (incf i)
                         (setf acc (logand acc (1- (ash 1 nbits))))))
                     (when (plusp nbits)
                       (setf (aref buf i) (logand (ash acc (- 8 nbits)) 255)) (incf i))))))))))
      (values buf i))))

(defun %cpixel-format (c)
  "The CPIXEL a tile carries for client C.  At 32 bpp glass's B,G,R -- what glass's own server
   sends and what the shell's noVNC reads, whatever shifts it asked for; at 16 bpp the client's
   5:5:5 layout."
  (if (= (cl-bpp c) 16) (cl-shifts c) :bgr))

(defun %encoding (c)
  (let ((e (cl-encodings c)))
    (cond ((member 16 e) 16) ((member 15 e) 15) (t 0))))

(defun %send-rows (c rows y0 y1)
  "Rows Y0..Y1-1 as one FramebufferUpdate of one rectangle, in the best encoding the client
   offered (ZRLE, TRLE, Raw)."
  (let ((w (floor (length (aref rows 0)) 4)) (enc (%encoding c)))
    (%u8 c 0) (%u8 c 0) (%u16 c 1)                         ; FramebufferUpdate, 1 rectangle
    (%u16 c 0) (%u16 c y0) (%u16 c w) (%u16 c (- y1 y0)) (%u32 c enc)
    (case enc
      (16 (multiple-value-bind (buf len) (%pack-tiles rows y0 y1 64 (%cpixel-format c))
            (let ((zs (or (cl-zs c) (setf (cl-zs c) (cram:make-zstream :max-chain 16)))))
              (cram:compress zs buf :end len)
              (let ((z (cram:sync-flush zs)))
                (%u32 c (length z)) (%put c z)
                (incf (cl-bytes c) (+ 4 (length z)))))))
      (15 (multiple-value-bind (buf len) (%pack-tiles rows y0 y1 16 (%cpixel-format c))
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
  (let ((want (cl-want c)) (gens (%row-gen)))
    (when want
      (multiple-value-bind (fb pitch w h) (%geometry)
        (declare (ignore fb pitch w))
        (let ((sent (or (cl-sent c) (setf (cl-sent c) (make-array h :initial-element -1))))
              (y0 nil) (y1 nil))
          (if (or (eq want :full) (null (cl-prev c)))
              (setf y0 0 y1 h)
              (dotimes (y h)
                (unless (eql (svref gens y) (svref sent y))
                  (unless y0 (setf y0 y))
                  (setf y1 (1+ y)))))
          (when y0
            ;; the stamps are recorded BEFORE the copy: a draw landing after this is resent
            (loop for y from y0 below y1 do (setf (svref sent y) (svref gens y)))
            (let ((rows (%copy-rows (%row-buffers (cl-prev c)) y0 y1)))
              (setf (cl-prev c) rows (cl-want c) nil)
              (%send-rows c rows y0 y1))))))))

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
       (3 (setf (cl-want c) (if (zerop (aref m 1)) :full (or (cl-want c) :incremental))))
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
                (%lp "EVERY-SECONDS" *loop* 0.03
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
