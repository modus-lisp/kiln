;;;; zero-rfb.lisp — the Zero's desk as an RFB server, for kiln's gateway.
;;;;
;;;; kiln reaches a phone through its Nostr/WebRTC gateway, and the gateway reaches the desktop
;;;; through RFB.  The bare-metal Zero cannot run the gateway yet, so it runs elsewhere (the Pi 5
;;;; at the other end of the Zero's Ethernet) and connects here: GLASS_HOST=10.0.0.2
;;;; GLASS_PORT=5900.  RFB 3.8, security type None, Raw rectangles straight out of the HDMI
;;;; scanout buffer (32-bit XRGB, i.e. BGRX in memory: the pixel format the gateway asks for).
;;;;
;;;; ONE connection, on the board's single-connection TCP (net/ip.lisp: its state block, its
;;;; TCP-SEND-SEGMENT), served from the USB THREAD's idle loop -- every USB transfer is that
;;;; thread's -- a step at a time, so the keyboard and mouse keep being polled while a frame
;;;; goes out.
;;;;
;;;; SENDING IS ITS OWN.  The kernel's TCP-SEND sends a segment and forgets it: no window, no
;;;; retransmission, which is fine for a request line and fatal for a megabyte.  Here the sender
;;;; keeps the peer's ACK and window (read from every segment that arrives), keeps at most a
;;;; window of bytes in flight, and on a stall rewinds to the last byte acknowledged and sends
;;;; again.  The bytes of an update are a FUNCTION of their offset (header, then the scanout
;;;; rows), so a resend needs no copy of what was sent.
;;;;
;;;; THREADS SHARE NO MEMORY.  The USB thread may store numbers and bytes into the main thread's
;;;; objects, never objects of its own, so every piece of state is a fixnum in a vector the main
;;;; thread made (RFB-START), and input goes back to the main thread through a ring of fixnum
;;;; events in the desk's own encoding (kiln-zero %ZERO-EVENT).
;;;;
;;;;   (kiln-zero-ssh:net-up) (kiln-zero-rfb:rfb-start)   ; then point a gateway at 10.0.0.2:5900

(defpackage #:kiln-zero-rfb
  (:use #:cl)
  (:export #:rfb-start #:rfb-stop #:rfb-status #:rfb-take-events #:*rfb-port*))
(in-package #:kiln-zero-rfb)

(defvar *rfb-port* 5900)
(defvar *rfb* nil "The state vector (made by the main thread), or NIL when not serving.")

;;; The state vector's slots, by name: (SV S :PHASE) is (SVREF S 0) at compile time.  A macro,
;;; not DEFCONSTANTs: modus compiles a use of a DEFCONSTANT in a loaded file as a global read,
;;; and every global read on a thread goes through the runtime lock.
;;;   :phase 0 off, 1 listen, 2 syn-received, 3 version, 4 security, 5 init, 6 run
;;;   :swap 1 = the client wants red at shift 0; :snd-base our sequence at an update's first byte;
;;;   :sent / :acked bytes of the update sent (may rewind) / acknowledged; :progress-at when
;;;   :acked last moved; :ev-head written by the main thread, :ev-tail by the USB thread;
;;;   :rxbuf the client's unparsed bytes; :ring the events; :seg the payload being sent.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *slots* '((:phase 0) (:rx-len 1) (:swap 2) (:want 3) (:sending 4) (:snd-base 5) (:msg-len 6) (:sent 7) (:acked 8) (:window 9) (:progress-at 10) (:ev-head 11) (:ev-tail 12) (:fb 13) (:pitch 14) (:w 15) (:h 16) (:frames 17) (:resends 18) (:mask 19) (:conns 20) (:rx-frames 21) (:rx-tcp 22) (:rx-syn 23) (:rxbuf 24) (:ring 25) (:seg 26) (:steps 27))))
(defmacro sv (s name)
  (let ((e (assoc name *slots*)))
    (unless e (error "zero-rfb: no slot ~s" name))
    `(svref ,s ,(second e))))
(defmacro nslots () 32)

(defmacro seg-max () 1400)
(defmacro in-flight-max () 32768)
(defmacro stall-us () 300000)


(defun %now () (get-internal-real-time))
(defun %u32 (n) (logand n #xFFFFFFFF))
(defun %st () (cl-user::e1000-state-base))

;;; ---- the main thread's side ---------------------------------------------------------------

(defun rfb-start (&key (port *rfb-port*))
  "Serve the desk on PORT (after KILN-ZERO-SSH:NET-UP).  From the main thread."
  (let ((s (make-array (nslots) :initial-element 0)))
    (setf (sv s :rxbuf) (make-array 4096 :element-type '(unsigned-byte 8) :initial-element 0)
          (sv s :ring) (make-array 256 :initial-element 0)
          (sv s :seg) (make-array (seg-max) :element-type '(unsigned-byte 8) :initial-element 0)
          (sv s :fb) (cl-user::hcon-get #x04) (sv s :pitch) (cl-user::hcon-get #x08)
          (sv s :w) (cl-user::hcon-get #x0C) (sv s :h) (cl-user::hcon-get #x10)
          (sv s :window) 8192)
    (setf (cl-user::mem-ref (+ (%st) #x34) :u16) port)
    (setf (sv s :phase) 1)
    (setf *rfb* s)
    ;; the desk's hooks (boot/zero.lisp): serve from the USB thread, take input on this one
    (setf (symbol-value (find-symbol "*KZ-USB-IDLE-HOOK*" "COMMON-LISP-USER")) #'rfb-step
          (symbol-value (find-symbol "*KZ-EVENT-SOURCE*" "COMMON-LISP-USER")) #'rfb-take-events)
    (list :port port :size (list (sv s :w) (sv s :h)))))

(defun rfb-stop ()
  (setf (symbol-value (find-symbol "*KZ-USB-IDLE-HOOK*" "COMMON-LISP-USER")) nil
        (symbol-value (find-symbol "*KZ-EVENT-SOURCE*" "COMMON-LISP-USER")) nil)
  (when *rfb* (setf (sv *rfb* :phase) 0))
  (setf *rfb* nil)
  t)

(defun rfb-status ()
  (let ((s *rfb*))
    (and s (list :phase (sv s :phase) :frames (sv s :frames) :resends (sv s :resends)
                 :conns (sv s :conns) :sending (sv s :sending) :sent (sv s :sent)
                 :acked (sv s :acked) :window (sv s :window)
                 :steps (sv s :steps) :rx-frames (sv s :rx-frames) :rx-tcp (sv s :rx-tcp)
                 :rx-syn (sv s :rx-syn)))))

(defun rfb-take-events ()
  "The input the client sent since the last call, oldest first.  Main thread."
  (let ((s *rfb*) (out '()))
    (when s
      (cl-user::mfence)
      (let ((tail (sv s :ev-tail)) (head (sv s :ev-head)) (ring (sv s :ring)))
        (loop until (= head tail)
              do (push (svref ring head) out)
                 (setf head (logand (1+ head) 255)))
        (setf (sv s :ev-head) head)))
    (nreverse out)))

;;; ---- the USB thread's side ----------------------------------------------------------------

(defun %event (s e)
  (let* ((tail (sv s :ev-tail)) (next (logand (1+ tail) 255)))
    (unless (= next (sv s :ev-head))         ; full: drop it
      (setf (svref (sv s :ring) tail) e)
      (cl-user::mfence)
      (setf (sv s :ev-tail) next))))

(defun %send-bytes (bytes)
  "A short message (handshake): one segment, from a list of octets."
  (let ((v (make-array (length bytes))) (i 0))
    (dolist (b bytes) (setf (svref v i) b) (incf i))
    (cl-user::tcp-send-segment 24 v (length bytes))))

(defun %u16 (n) (list (ash n -8) (logand n 255)))
(defun %u32b (n) (list (ldb (byte 8 24) n) (ldb (byte 8 16) n) (ldb (byte 8 8) n) (logand n 255)))

(defun %listen (s)
  (setf (sv s :phase) 1 (sv s :rx-len) 0 (sv s :sending) 0 (sv s :want) 0
        (sv s :swap) 0 (sv s :mask) 0))

(defun %rx (s)
  "Take one frame off the NIC and deal with it.  T when there was one."
  (let ((len (cl-user::e1000-receive)))
    (when (and len (> len 0))
      (incf (sv s :rx-frames))
      (let ((b (cl-user::e1000-rx-buf)) (st (%st)))
        (kiln-zero-ssh::%arp-answer b)                    ; so the gateway can find us
        (flet ((u8 (o) (cl-user::mem-ref (+ b o) :u8))
               (u16 (o) (cl-user::buf-read-u16-mem b o))
               (u32 (o) (cl-user::buf-read-u32-mem b o)))
          (when (and (= (u8 12) 8) (= (u8 13) 0) (= (u8 23) 6)
                     (= (u16 36) (cl-user::mem-ref (+ st #x34) :u16)))
            (incf (sv s :rx-tcp))
            (when (logtest (u8 47) 2) (incf (sv s :rx-syn)))
            (let* ((flags (u8 47)) (seq (u32 38)) (ack (u32 42)) (win (u16 48))
                   (doff (ash (logand (u8 46) #xF0) -2))
                   (dlen (- (u16 16) 20 doff))
                   (phase (sv s :phase)))
              (cond
                ;; a connection: answer the SYN
                ((and (= phase 1) (logtest flags 2) (not (logtest flags #x10)))
                 (setf (cl-user::mem-ref (+ st #x38) :u32) (u32 26)
                       (cl-user::mem-ref (+ st #x36) :u16) (u16 34)
                       (cl-user::mem-ref (+ st #x3C) :u32) (%u32 (+ 1000 (* 65536 (sv s :conns))))
                       (cl-user::mem-ref (+ st #x40) :u32) (%u32 (1+ seq))
                       (sv s :window) win)
                  (cl-user::tcp-send-segment 18 (make-array 0) 0)   ; SYN-ACK
                  (setf (sv s :phase) 2))
                ((< phase 2) nil)
                ;; not our peer
                ((or (/= (u32 26) (cl-user::mem-ref (+ st #x38) :u32))
                     (/= (u16 34) (cl-user::mem-ref (+ st #x36) :u16)))
                 nil)
                ((logtest flags 4) (%listen s))                     ; RST
                (t
                 (when (logtest flags #x10)
                   (setf (sv s :window) win)
                   (when (= phase 2)                                ; our SYN-ACK acknowledged
                     (incf (sv s :conns))
                     (setf (sv s :phase) 3)
                     (%send-bytes (map 'list #'char-code (format nil "RFB 003.008~c" #\Newline))))
                   (when (= (sv s :sending) 1)
                     (let ((a (%u32 (- ack (sv s :snd-base)))))
                       (when (and (<= a (sv s :sent)) (> a (sv s :acked)))
                         (setf (sv s :acked) a (sv s :progress-at) (%now))))))
                 (when (> dlen 0)
                   (if (= seq (cl-user::mem-ref (+ st #x40) :u32))
                       (let ((rx (sv s :rxbuf)) (n (sv s :rx-len)) (at (+ 14 20 doff)))
                         (when (> (+ n dlen) (length rx)) (setf n 0))  ; overrun: drop what we had
                         (dotimes (i dlen) (setf (aref rx (+ n i)) (u8 (+ at i))))
                         (setf (sv s :rx-len) (+ n dlen)
                               (cl-user::mem-ref (+ st #x40) :u32) (%u32 (+ seq dlen)))))
                   (cl-user::tcp-send-segment 16 (make-array 0) 0))  ; ACK (or re-ACK)
                 (when (logtest flags 1)                            ; FIN
                   (setf (cl-user::mem-ref (+ st #x40) :u32) (%u32 (+ seq dlen 1)))
                   (cl-user::tcp-send-segment 17 (make-array 0) 0)
                   (%listen s)))))))
        t))))

(defun %consume (s n)
  (let ((rx (sv s :rxbuf)) (len (sv s :rx-len)))
    (replace rx rx :start2 n :end2 len)
    (setf (sv s :rx-len) (- len n))))

(defun %parse (s)
  "Act on every complete message in the receive buffer."
  (let ((rx (sv s :rxbuf)))
    (loop
      (let ((len (sv s :rx-len)) (phase (sv s :phase)))
        (flet ((need (n) (>= len n)) (u16 (o) (+ (* 256 (aref rx o)) (aref rx (1+ o)))))
          (case phase
            (3 (unless (need 12) (return))                          ; "RFB 003.00x\n"
             (%consume s 12) (%send-bytes '(1 1)) (setf (sv s :phase) 4))
            (4 (unless (need 1) (return))                           ; the security type chosen
             (%consume s 1) (%send-bytes '(0 0 0 0)) (setf (sv s :phase) 5))
            (5 (unless (need 1) (return))                           ; ClientInit
             (%consume s 1)
             (let ((name (map 'list #'char-code "kiln zero")))
               (%send-bytes (append (%u16 (sv s :w)) (%u16 (sv s :h))
                                    '(32 24 0 1 0 255 0 255 0 255 16 8 0 0 0 0)
                                    (%u32b (length name)) name)))
             (setf (sv s :phase) 6))
            (6 (unless (need 1) (return))
             (case (aref rx 0)
               (0 (unless (need 20) (return))                       ; SetPixelFormat
                (setf (sv s :swap) (if (and (= (aref rx 14) 0) (= (aref rx 16) 16)) 1 0))
                (%consume s 20))
               (2 (unless (need 4) (return))                        ; SetEncodings
                (let ((n (+ 4 (* 4 (u16 2)))))
                  (unless (need n) (return))
                  (%consume s n)))
               (3 (unless (need 10) (return))                       ; FramebufferUpdateRequest
                (setf (sv s :want) 1) (%consume s 10))
               (4 (unless (need 8) (return))                        ; KeyEvent
                (when (= (aref rx 1) 1)
                  (%event s (+ (* 4 1099511627776)
                               (* 16777216 (aref rx 4)) (* 65536 (aref rx 5))
                               (* 256 (aref rx 6)) (aref rx 7))))
                (%consume s 8))
               (5 (unless (need 6) (return))                        ; PointerEvent
                (let* ((nb (aref rx 1)) (lb (sv s :mask)) (x (u16 2)) (y (u16 4))
                       (down (logbitp 0 nb)) (was (logbitp 0 lb)))
                  (%event s (+ (* (cond ((and down (not was)) 1) ((and was (not down)) 3)
                                        (down 2) (t 5))
                                  1099511627776)
                               (* y 1048576) x))
                  (setf (sv s :mask) nb))
                (%consume s 6))
               (6 (unless (need 8) (return))                        ; ClientCutText
                (let ((n (+ 8 (+ (* 16777216 (aref rx 4)) (* 65536 (aref rx 5)) (u16 6)))))
                  (if (need n) (%consume s n) (if (> n 4096) (setf (sv s :rx-len) 0) (return)))))
               (t (setf (sv s :rx-len) 0) (return))))              ; lost sync: drop it
            (t (return))))))))

(defun %fill (s off n)
  "Bytes OFF .. OFF+N of the current update into the segment buffer."
  (let* ((seg (sv s :seg)) (w (sv s :w)) (h (sv s :h)) (row-bytes (* 4 w))
         (fb (sv s :fb)) (pitch (sv s :pitch)) (swap (= (sv s :swap) 1)))
    (dotimes (i n)
      (let ((o (+ off i)))
        (setf (aref seg i)
              (if (< o 16)
                  (case o (3 1) (8 (ash w -8)) (9 (logand w 255)) (10 (ash h -8)) (11 (logand h 255))
                    (t 0))
                  (multiple-value-bind (row col) (floor (- o 16) row-bytes)
                    (let ((k (logand col 3)))
                      (cl-user::mem-ref (+ fb (* row pitch)
                                           (if (and swap (/= k 1) (/= k 3)) (logxor col 2) col))
                                        :u8)))))))))

(defun %send-step (s)
  (when (and (= (sv s :sending) 0) (= (sv s :want) 1) (= (sv s :phase) 6))
    (setf (sv s :want) 0 (sv s :sending) 1
          (sv s :snd-base) (cl-user::mem-ref (+ (%st) #x3C) :u32)
          (sv s :msg-len) (+ 16 (* 4 (sv s :w) (sv s :h)))
          (sv s :sent) 0 (sv s :acked) 0 (sv s :progress-at) (%now)))
  (when (= (sv s :sending) 1)
    (let ((len (sv s :msg-len)) (budget 8))
      (loop
        (let* ((sent (sv s :sent))
               (room (- (min (sv s :window) (in-flight-max)) (- sent (sv s :acked))))
               (n (min (seg-max) (- len sent) room)))
          (when (or (<= n 0) (<= budget 0)) (return))
          (%fill s sent n)
          (setf (cl-user::mem-ref (+ (%st) #x3C) :u32) (%u32 (+ (sv s :snd-base) sent)))
          (cl-user::tcp-send-segment 24 (sv s :seg) n)
          (setf (sv s :sent) (+ sent n))
          (decf budget)))
      (cond ((>= (sv s :acked) len)
             (setf (sv s :sending) 0)
             (incf (sv s :frames)))
            ((and (< (sv s :acked) (sv s :sent))
                  (> (- (%now) (sv s :progress-at)) (stall-us)))
             ;; nothing acknowledged for a while: send again from the last byte that was
             (setf (sv s :sent) (sv s :acked) (sv s :progress-at) (%now))
             (incf (sv s :resends)))))
    ;; keep our sequence at the end of what is out, for ACKs we send in between
    (setf (cl-user::mem-ref (+ (%st) #x3C) :u32) (%u32 (+ (sv s :snd-base) (sv s :sent))))))

(defun rfb-step ()
  "One round of serving, on the USB thread (kiln-zero calls it from the USB thread's idle)."
  (let ((s *rfb*))
    (when (and s (> (sv s :phase) 0))
      (incf (sv s :steps))
      (dotimes (i 16) (unless (%rx s) (return)))
      (%parse s)
      (%send-step s))))
