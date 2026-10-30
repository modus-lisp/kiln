;;;; zero-rfbs.lisp — the Zero's desk as an RFB server over the board's SOCKETS.
;;;;
;;;; zero-rfb.lisp serves the desk on net/ip.lisp's single TCP connection, from the USB thread,
;;;; for a gateway at the other end of the cable.  The gateway now runs ON the board
;;;; (zero-gateway.lisp) and reaches the desk over LOOPBACK -- which is modus's many-connection
;;;; TCP (net/tcp-conns.lisp), not the kernel's one connection -- so this is the same server on
;;;; SB-BSD-SOCKETS: a listener, and per client a reader and a sender, all core-0 threads (they
;;;; share the main thread's heap: net/bare-threads.lisp, CORE 0).
;;;;
;;;; RFB 3.8, security None, out of the HDMI scanout buffer (32-bit XRGB, BGRX in memory; swapped
;;;; to RGBX when the client asks for red at shift 0, noVNC's default).  ZRLE when the client
;;;; offers it (one persistent zlib stream per client, cram), else TRLE, else Raw: a raw 640x480
;;;; frame is 1.2 MB, and through DTLS on a Zero the link carries a few KB/s.  An incremental
;;;; request is answered with the rows that changed since the last update, as one rectangle;
;;;; nothing changed, the sender looks again in 30 ms.
;;;;
;;;;   (kiln-zero-rfbs:rfbs-start)            ; 127.0.0.1:5900; :address "0.0.0.0" to open it up

(defpackage #:kiln-zero-rfbs
  (:use #:cl)
  (:export #:rfbs-start #:rfbs-stop #:rfbs-status #:*rfbs-port*))
(in-package #:kiln-zero-rfbs)

(defvar *rfbs-port* 5900)
(defvar *listener* nil)
(defvar *clients* nil)
(defvar *lock* nil "Guards *CLIENTS* and *EVENTS*.")
(defvar *events* nil "Desk events from clients, newest first (the desk's encoding, kiln-zero).")

(defclass client ()
  ((stream :initarg :stream :reader cl-stream)
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

;;; ---- the screen ---------------------------------------------------------------------------

(defun %geometry ()
  "(values scanout-address pitch width height) of the HDMI console's framebuffer."
  (values (modus-int::hcon-get #x04) (modus-int::hcon-get #x08)
          (modus-int::hcon-get #x0C) (modus-int::hcon-get #x10)))

(defun %data-address (v)
  "Where byte vector V's elements start (V must not move before the address is used)."
  (+ (modus-int::%gc-word-of v (modus-int::%conv-addr #x100050A0)) 7))

(defun %copy-row (dst src bytes)
  "BYTES (a multiple of 64) from SRC into byte vector DST, with the console's native copy -- on
   the screen thread when there is one, which uses the same scratch block for its presents."
  (let ((scr (and (boundp 'cl-user::*kz-scr*) (symbol-value 'cl-user::*kz-scr*))))
    (if scr
        (modus-int::bt-call scr (lambda () (modus-int::hcon-ncopy (%data-address dst) src bytes) 0))
        (modus-int::hcon-ncopy (%data-address dst) src bytes))))

(defun %grab (prev)
  "The screen now, as a vector of row byte vectors (PREV's reused when it is the right shape)."
  (multiple-value-bind (fb pitch w h) (%geometry)
    (let* ((rb (* 4 w))
           (rows (if (and prev (= (length prev) h) (= (length (aref prev 0)) rb))
                     (map 'vector #'copy-seq prev)
                     (let ((v (make-array h)))
                       (dotimes (y h v)
                         (setf (aref v y) (make-array rb :element-type '(unsigned-byte 8))))))))
      (dotimes (y h rows)
        (%copy-row (aref rows y) (+ fb (* y pitch)) rb)))))

;;; ---- writing ------------------------------------------------------------------------------

(defun %u8 (s n) (write-byte (logand n 255) s))
(defun %u16 (s n) (%u8 s (ash n -8)) (%u8 s n))
(defun %u32 (s n) (%u16 s (ash n -16)) (%u16 s (logand n #xFFFF)))

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
  (let ((s (cl-stream c)) (w (floor (length (aref rows 0)) 4)) (enc (%encoding c)))
    (%u8 s 0) (%u8 s 0) (%u16 s 1)                         ; FramebufferUpdate, 1 rectangle
    (%u16 s 0) (%u16 s y0) (%u16 s w) (%u16 s (- y1 y0)) (%u32 s enc)
    (case enc
      (16 (multiple-value-bind (buf len) (%pack-tiles rows y0 y1 64 (%cpixel-format c))
            (let ((zs (or (cl-zs c) (setf (cl-zs c) (cram:make-zstream :max-chain 16)))))
              (cram:compress zs buf :end len)
              (let ((z (cram:sync-flush zs)))
                (%u32 s (length z)) (write-sequence z s)
                (incf (cl-bytes c) (+ 4 (length z)))))))
      (15 (multiple-value-bind (buf len) (%pack-tiles rows y0 y1 16 (%cpixel-format c))
            (write-sequence buf s :end len)
            (incf (cl-bytes c) len)))
      (t (%send-raw-rows c rows y0 y1)))
    (force-output s)
    (incf (cl-frames c))))

(defun %send-raw-rows (c rows y0 y1)
  (let ((s (cl-stream c)))
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
                    (write-sequence out s)))
                 ((cl-swap c)
                   (let ((out (copy-seq row)))
                     (loop for i from 0 below (length out) by 4
                           do (rotatef (aref out i) (aref out (+ i 2))))
                     (write-sequence out s)))
                 (t (write-sequence row s)))))))

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

(defun %sender (c)
  ;; AN INCREMENTAL REQUEST ON A STILL SCREEN COSTS NOTHING: the screen is copied and compared
  ;; only when the desk has drawn since the last look (*KZ-DAMAGE*), or once a second (the text
  ;; console draws without the desk).  Copying 1.2 MB and comparing 480 rows every 30 ms was a
  ;; steady load on core 0, which the gateway's threads share.
  (let ((seen nil) (looked 0))
    (loop while (cl-open c)
          do (let ((want (cl-want c)) (dmg (%damage)) (now (get-internal-real-time)))
               (if (or (null want)
                       (and (eq want :incremental) (cl-prev c) (eql dmg seen)
                            (< (- now looked) internal-time-units-per-second)))
                   (sleep 0.03)
                   (progn
                     (setf seen dmg looked now)
                     (%send-if-changed c want)))))))

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

(defun %read-n (s n)
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (unless (= (read-sequence v s) n) (error 'end-of-file :stream s))
    v))

(defun %event (e)
  (sb-thread:with-mutex (*lock*) (push e *events*)))

(defun %ev (type x y) (+ (* type 1099511627776) (* y 1048576) x))

(defun %reader (c)
  (let ((s (cl-stream c)))
    (loop
      (case (read-byte s)
        (0 (let ((pf (%read-n s 19)))                       ; SetPixelFormat
             (setf (cl-swap c) (and (= (aref pf 13) 0) (= (aref pf 15) 16))
                   (cl-bpp c) (if (= (aref pf 3) 16) 16 32)
                   (cl-shifts c) (list (aref pf 13) (aref pf 14) (aref pf 15)))))
        (2 (let* ((h (%read-n s 3)) (n (+ (* 256 (aref h 1)) (aref h 2)))   ; SetEncodings
                  (v (%read-n s (* 4 n))) (encs '()))
             (dotimes (k n)
               (let ((e (logior (ash (aref v (* 4 k)) 24) (ash (aref v (+ (* 4 k) 1)) 16)
                                (ash (aref v (+ (* 4 k) 2)) 8) (aref v (+ (* 4 k) 3)))))
                 (push (if (>= e #x80000000) (- e #x100000000) e) encs)))
             (setf (cl-encodings c) (nreverse encs))))
        (3 (let ((r (%read-n s 9)))                         ; FramebufferUpdateRequest
             (setf (cl-want c) (if (zerop (aref r 0)) :full (or (cl-want c) :incremental)))))
        (4 (let ((k (%read-n s 7)))                         ; KeyEvent: down, keysym
             (when (= (aref k 0) 1)
               (%event (+ (* 4 1099511627776)
                          (* 16777216 (aref k 3)) (* 65536 (aref k 4)) (* 256 (aref k 5)) (aref k 6))))))
        (5 (let* ((p (%read-n s 5)) (nb (aref p 0))         ; PointerEvent
                  (x (+ (* 256 (aref p 1)) (aref p 2))) (y (+ (* 256 (aref p 3)) (aref p 4)))
                  (down (logbitp 0 nb)) (was (logbitp 0 (cl-mask c))))
             (%event (%ev (cond ((and down (not was)) 1) ((and was (not down)) 3) (down 2) (t 5)) x y))
             (setf (cl-mask c) nb)))
        (6 (let* ((h (%read-n s 7))                         ; ClientCutText
                  (n (+ (* 16777216 (aref h 3)) (* 65536 (aref h 4)) (* 256 (aref h 5)) (aref h 6))))
             (%read-n s n)))
        (t (error "rfbs: unknown client message"))))))

;;; ---- a client -----------------------------------------------------------------------------

(defun %handshake (s)
  (write-sequence (map '(vector (unsigned-byte 8)) #'char-code (format nil "RFB 003.008~c" #\Newline)) s)
  (force-output s)
  (%read-n s 12)                                            ; the client's version
  (%u8 s 1) (%u8 s 1) (force-output s)                      ; one security type: None
  (%read-n s 1)
  (%u32 s 0) (force-output s)                               ; SecurityResult OK
  (%read-n s 1)                                             ; ClientInit (shared flag)
  (multiple-value-bind (fb pitch w h) (%geometry)
    (declare (ignore fb pitch))
    (%u16 s w) (%u16 s h)
    (dolist (b '(32 24 0 1 0 255 0 255 0 255 16 8 0 0 0 0)) (%u8 s b))
    (let ((name "kiln zero"))
      (%u32 s (length name))
      (write-sequence (map '(vector (unsigned-byte 8)) #'char-code name) s))
    (force-output s)))

(defun %serve (sock)
  (let* ((s (sb-bsd-sockets:socket-make-stream sock :input t :output t
                                               :element-type '(unsigned-byte 8) :buffering :full))
         (c (make-instance 'client :stream s)))
    (handler-case
        (progn
          (%handshake s)
          (sb-thread:with-mutex (*lock*) (push c *clients*))
          (sb-thread:make-thread (lambda () (handler-case (%sender c) (error () nil))
                                   (setf (cl-open c) nil))
                                 :name "rfbs-sender")
          (%reader c))
      (error () nil))
    (setf (cl-open c) nil)
    (sb-thread:with-mutex (*lock*) (setf *clients* (remove c *clients*)))
    (ignore-errors (close s))
    (ignore-errors (sb-bsd-sockets:socket-close sock))))

;;; ---- the server ---------------------------------------------------------------------------

(defun %take-events ()
  "The desk's event source: what clients sent since the last call, oldest first."
  (when *events*
    (sb-thread:with-mutex (*lock*) (prog1 (nreverse *events*) (setf *events* nil)))))

(defun rfbs-start (&key (port *rfbs-port*) (address "127.0.0.1"))
  "Serve the desk on ADDRESS:PORT.  The listener's thread."
  (unless *lock* (setf *lock* (sb-thread:make-mutex :name "rfbs")))
  (let ((l (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (ip (map 'vector #'parse-integer (%split-dots address))))
    (sb-bsd-sockets:socket-bind l ip port)
    (sb-bsd-sockets:socket-listen l 4)
    (setf *listener* l)
    (setf (symbol-value 'cl-user::*kz-event-source*) #'%take-events)
    (sb-thread:make-thread
     (lambda ()
       (loop while *listener*
             do (let ((sock (ignore-errors (sb-bsd-sockets:socket-accept l))))
                  (when sock
                    (sb-thread:make-thread (lambda () (%serve sock)) :name "rfbs-client")))))
     :name "rfbs-listen")))

(defun %split-dots (address)
  (let ((parts '()) (start 0))
    (loop for i = (position #\. address :start start)
          do (push (subseq address start i) parts)
             (if i (setf start (1+ i)) (return)))
    (nreverse parts)))

(defun rfbs-stop ()
  (let ((l *listener*))
    (setf *listener* nil)
    (when l (ignore-errors (sb-bsd-sockets:socket-close l)))
    (dolist (c *clients*) (setf (cl-open c) nil))
    t))

(defun rfbs-status ()
  (mapcar (lambda (c) (list :frames (cl-frames c) :bytes (cl-bytes c) :encoding (%encoding c)
                            :swap (cl-swap c) :open (cl-open c)))
          *clients*))
