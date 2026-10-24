;;;; zero-rfbs.lisp — the Zero's desk as an RFB server over the board's SOCKETS.
;;;;
;;;; zero-rfb.lisp serves the desk on net/ip.lisp's single TCP connection, from the USB thread,
;;;; for a gateway at the other end of the cable.  The gateway now runs ON the board
;;;; (zero-gateway.lisp) and reaches the desk over LOOPBACK -- which is modus's many-connection
;;;; TCP (net/tcp-conns.lisp), not the kernel's one connection -- so this is the same server on
;;;; SB-BSD-SOCKETS: a listener, and per client a reader and a sender, all core-0 threads (they
;;;; share the main thread's heap: net/bare-threads.lisp, CORE 0).
;;;;
;;;; RFB 3.8, security None, Raw rectangles out of the HDMI scanout buffer (32-bit XRGB, BGRX in
;;;; memory; swapped to RGBX when the client asks for red at shift 0, noVNC's default).  An
;;;; incremental request is answered with the rows that changed since the last update, as one
;;;; rectangle; nothing changed, the sender looks again in 30 ms.
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
   (mask :initform 0 :accessor cl-mask)              ; pointer buttons last seen
   (prev :initform nil :accessor cl-prev)            ; the frame last sent, rows of bytes
   (frames :initform 0 :accessor cl-frames)
   (open :initform t :accessor cl-open)))

;;; ---- the screen ---------------------------------------------------------------------------

(defun %geometry ()
  "(values scanout-address pitch width height) of the HDMI console's framebuffer."
  (values (cl-user::hcon-get #x04) (cl-user::hcon-get #x08)
          (cl-user::hcon-get #x0C) (cl-user::hcon-get #x10)))

(defun %data-address (v)
  "Where byte vector V's elements start (V must not move before the address is used)."
  (+ (cl-user::%gc-word-of v (cl-user::%conv-addr #x100050A0)) 7))

(defun %copy-row (dst src bytes)
  "BYTES (a multiple of 64) from SRC into byte vector DST, with the console's native copy -- on
   the screen thread when there is one, which uses the same scratch block for its presents."
  (let ((scr (and (boundp 'cl-user::*kz-scr*) (symbol-value 'cl-user::*kz-scr*))))
    (if scr
        (cl-user::bt-call scr (lambda () (cl-user::hcon-ncopy (%data-address dst) src bytes) 0))
        (cl-user::hcon-ncopy (%data-address dst) src bytes))))

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

(defun %send-rows (c rows y0 y1)
  "Rows Y0..Y1-1 as one FramebufferUpdate of one Raw rectangle."
  (let ((s (cl-stream c)) (w (floor (length (aref rows 0)) 4)))
    (%u8 s 0) (%u8 s 0) (%u16 s 1)                         ; FramebufferUpdate, 1 rectangle
    (%u16 s 0) (%u16 s y0) (%u16 s w) (%u16 s (- y1 y0)) (%u32 s 0)   ; Raw
    (loop for y from y0 below y1
          do (let ((row (aref rows y)))
               (if (cl-swap c)
                   (let ((out (copy-seq row)))
                     (loop for i from 0 below (length out) by 4
                           do (rotatef (aref out i) (aref out (+ i 2))))
                     (write-sequence out s))
                   (write-sequence row s))))
    (force-output s)
    (incf (cl-frames c))))

(defun %changed (prev rows)
  "(values first last+1) of the rows of ROWS that differ from PREV, or NIL."
  (let ((y0 nil) (y1 nil))
    (dotimes (y (length rows))
      (when (or (null prev) (mismatch (aref prev y) (aref rows y)))
        (unless y0 (setf y0 y))
        (setf y1 (1+ y))))
    (and y0 (values y0 y1))))

(defun %sender (c)
  (loop while (cl-open c)
        do (let ((want (cl-want c)))
             (if (null want)
                 (sleep 0.03)
                 (let ((rows (%grab (cl-prev c))))
                   (multiple-value-bind (y0 y1)
                       (if (or (eq want :full) (null (cl-prev c)))
                           (values 0 (length rows))
                           (%changed (cl-prev c) rows))
                     (if y0
                         (progn (setf (cl-want c) nil)
                                (%send-rows c rows y0 y1)
                                (setf (cl-prev c) rows))
                         (sleep 0.03))))))))

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
             (setf (cl-swap c) (and (= (aref pf 13) 0) (= (aref pf 15) 16)))))
        (2 (let* ((h (%read-n s 3)) (n (+ (* 256 (aref h 1)) (aref h 2))))   ; SetEncodings
             (%read-n s (* 4 n))))
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
  (mapcar (lambda (c) (list :frames (cl-frames c) :swap (cl-swap c) :open (cl-open c))) *clients*))
