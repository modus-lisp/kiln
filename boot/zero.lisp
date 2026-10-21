;;;; zero.lisp — kiln's phone app on a Raspberry Pi Zero 2 W running bare-metal modus:
;;;; the desk on the Zero's HDMI screen, its USB keyboard and mouse as input.
;;;;
;;;; The platform layer for app.lisp, as boot/ios.lisp and boot/android.lisp are, over modus's
;;;; board drivers instead of a host shim: net/hdmi-console.lisp (a 640-wide framebuffer the
;;;; firmware scales to the display, mapped non-cacheable, read with HCON-GET) and
;;;; net/usb-hid-split.lisp (HID-SPLIT-POLL, HID-RING-POP, MOUSE-X/-Y/-BUTTONS).  Those are
;;;; compiled into the modus board image; this file and app.lisp are installed over the
;;;; network by `kiln zero', together with glass and scribe.
;;;;
;;;; The calls, by number, as app.lisp makes them:
;;;;   1001 size (0 width, 1 height, 2 scale = 1)   1002 fill   1003 present (nothing to do)
;;;;   1004 next event                               1005 blit   1006 keyboard (it is always there)
;;;;   1010 speaker open (none: answers non-zero)    1011/1012 speaker write/queued (0)
;;;; Events are app.lisp's encoding: type << 40 | y << 20 | x, type 1 press, 2 drag, 3 release,
;;;; 5 hover (a mouse moves with no button down), 4 a key with its X11 keysym in the low bits.
;;;;
;;;; A phone has no pointer to draw; a mouse does.  The pointer is drawn here, over whatever
;;;; was blitted, with the pixels under it saved and put back when it moves.
;;;;
;;;; Ctrl-C or q on the serial port ends the app and gives the screen back to the text console.

(in-package :cl-user)

;;; app.lisp names the media player's symbols; without the player (kiln zero without --media)
;;; the packages still have to exist for the file to read.  With it they already do.
(unless (find-package "WARP-MEDIA")
  (make-package "WARP-MEDIA" :use nil)
  (dolist (n '("FOLDER-TRACKS" "LIBRARY-PLAYER" "MAKE-LIBRARY" "PLAY-PATH"))
    (export (intern n "WARP-MEDIA") "WARP-MEDIA")))
(unless (find-package "WARP-MEDIA-GLASS")
  (make-package "WARP-MEDIA-GLASS" :use nil)
  (export (intern "MAKE-MEDIA-WINDOW" "WARP-MEDIA-GLASS") "WARP-MEDIA-GLASS"))

;;; --- pointer -------------------------------------------------------------------------------

(defparameter *zero-arrow*
  '("2          " "22         " "212        " "2112       " "21112      "
    "211112     " "2111112    " "21111112   " "211111112  " "2111111112 "
    "21111122222" "2112112    " "212 2112   " "22  2112   " "2    2112  " "     222   "))
(defvar *zero-under* nil)                 ; T while the pointer is drawn, its pixels saved below
(defvar *zero-under-x* 0)
(defvar *zero-under-y* 0)
;; the 16 x 11 pixels under the pointer, row-major: reused, not a fresh list per draw (that was
;; 5.7 KB of garbage twice a frame -- the collector's pause is what a drag would feel)
(defvar *zero-under-pixels* (make-array 176 :initial-element 0))
(defvar *zy* nil)          ; Y'CbCr screen: (bufs back-index old-displist fb dw dh) once set up
(defvar *zero-px* 0)
(defvar *zero-py* 0)

(defun %zero-pixel-addr (x y) (+ (hcon-get #x04) (* y (hcon-get #x08)) (* x 4)))
(defun %zero-on-screen-p (x y) (and (< -1 x (hcon-get #x0C)) (< -1 y (hcon-get #x10))))

(defvar *kz-hw-cursor* nil)               ; T: the pointer is an HVS plane (the screen thread's)

(defun %zero-pointer-hide ()
  (when *kz-hw-cursor* (return-from %zero-pointer-hide nil))
  (when *zero-under*
    (let ((x *zero-under-x*) (y *zero-under-y*) (saved *zero-under-pixels*))
      (dotimes (r 16)
        (dotimes (c 11)
          (when (%zero-on-screen-p (+ x c) (+ y r))
            (setf (mem-ref (%zero-pixel-addr (+ x c) (+ y r)) :u32) (svref saved (+ (* r 11) c)))))))
    (setf *zero-under* nil)))

(defun %zero-pointer-show ()
  (when *kz-hw-cursor* (return-from %zero-pointer-show nil))
  (let ((x *zero-px*) (y *zero-py*) (saved *zero-under-pixels*))
    (dotimes (r 16)
      (let ((line (nth r *zero-arrow*)))
        (dotimes (c 11)
          (when (%zero-on-screen-p (+ x c) (+ y r))
            (let ((a (%zero-pixel-addr (+ x c) (+ y r))))
              (setf (svref saved (+ (* r 11) c)) (mem-ref a :u32))
              (case (char line c)
                (#\2 (setf (mem-ref a :u32) #x000000))
                (#\1 (setf (mem-ref a :u32) #xffffff))))))))
    (setf *zero-under-x* x *zero-under-y* y *zero-under* t)))

;;; --- the USB thread (a board image built with kiln zero --threads) ---------------------------
;;;
;;; The DWC2 host controller is one device, and its channels are shared (channel 2 carries both
;;; the HID split engine and the NIC's bulk OUT), so with threads exactly one thread drives it: an
;;; EXECUTOR pinned to core 1 (modus net/bare-threads.lisp) that polls the keyboard and mouse
;;; continuously -- into the raw key ring and pointer counters the desk already reads -- and runs
;;; whatever USB work another thread hands it (kiln-zero-ssh's net-up and TCP).  Once it has
;;; claimed the controller, HID-SPLIT-POLL anywhere else is a no-op and the desk only drains.

(defvar *kz-usb* nil)

;;; Hooks for what else runs on the USB thread and feeds the desk: the RFB server
;;; (boot/zero-rfb.lisp, loaded after this file) sets them when it starts serving.
(defvar *kz-usb-idle-hook* nil)    ; a function of no arguments, run on the USB thread each round
(defvar *kz-event-source* nil)     ; a function returning events (the desk's encoding), main thread
(defvar *kz-main-net* nil)         ; with sockets on the main thread: pump them while the desk idles
(defvar *kz-net-service* nil)      ; with the network up: drain the NIC into its ring (zero-ssh)

(defun %kz-usb-idle ()
  (hid-split-poll)
  (let ((n *kz-net-service*) (h *kz-usb-idle-hook*))
    (when n (funcall n))                ; first: nothing may leave the NIC unread
    (when h (funcall h))))

(defun kz-usb-start ()
  "Start the USB thread on core 1 and give it the controller.  Its handle, or NIL on an image
   without threads."
  (when (and (null *kz-usb*) (fboundp 'bt-start-executor) (fboundp 'hid-claim-usb))
    (let ((ex (bt-start-executor 1 #'%kz-usb-idle)))
      (bt-call ex #'hid-claim-usb)
      (setf *kz-usb* ex)
      (let ((s (find-symbol "*USB-EXECUTOR*" "KILN-ZERO-SSH")))
        (when s (setf (symbol-value s) ex)))))
  *kz-usb*)

;;; --- events --------------------------------------------------------------------------------

(defvar *zero-events* nil)                ; queued app events, oldest first
(defvar *zero-mouse* nil)                 ; T once the mouse counters below have been read
(defvar *zero-mx* 0)                      ; ... the counters last seen (x y buttons): variables,
(defvar *zero-my* 0)                      ; not a fresh list per poll
(defvar *zero-mb* 0)

(defun %zero-keysym (c)
  (cond ((= c 13) #xff0d) ((= c 127) #xff08) ((= c 9) #xff09) ((= c 27) #xff1b) (t c)))

(defun %zero-event (type x y) (+ (* type 1099511627776) (* y 1048576) x))

(defun %zero-poll ()
  "Turn what the keyboard and mouse did since the last call into queued events."
  (hid-split-poll)
  (let ((src *kz-event-source*))
    (when src (setf *zero-events* (append *zero-events* (funcall src)))))
  (loop (let ((c (hid-ring-pop)))
          (when (< c 0) (return))
          (setf *zero-events* (append *zero-events*
                                      (list (+ (* 4 1099511627776) (%zero-keysym c)))))))
  (when *kz-scr*
    ;; THE SCREEN THREAD MOVES THE POINTER (*ZERO-PX*/*ZERO-PY*); here only its events
    (unless *zero-mouse*
      (setf *zero-mx* *zero-px* *zero-my* *zero-py* *zero-mb* (mouse-buttons) *zero-mouse* t))
    (let ((px *zero-px*) (py *zero-py*) (nb (mouse-buttons)) (lb *zero-mb*))
      (when (or (/= px *zero-mx*) (/= py *zero-my*) (/= nb lb))
        (let ((down (logbitp 0 nb)) (was (logbitp 0 lb)))
          (setf *zero-events*
                (append *zero-events*
                        (list (%zero-event (cond ((and down (not was)) 1)
                                                 ((and was (not down)) 3)
                                                 (down 2)
                                                 (t 5))
                                           px py)))))
        (setf *zero-mx* px *zero-my* py *zero-mb* nb)))
    (return-from %zero-poll nil))
  (unless *zero-mouse*
    (setf *zero-mx* (mouse-x) *zero-my* (mouse-y) *zero-mb* (mouse-buttons) *zero-mouse* t))
  (let ((lx *zero-mx*) (ly *zero-my*) (lb *zero-mb*))
    (let ((nx (mouse-x)) (ny (mouse-y)) (nb (mouse-buttons)))
      (when (or (/= nx lx) (/= ny ly) (/= nb lb))
        (setf *zero-px* (max 0 (min (1- (hcon-get #x0C)) (+ *zero-px* (- nx lx))))
              *zero-py* (max 0 (min (1- (hcon-get #x10)) (+ *zero-py* (- ny ly)))))
        (let ((down (logbitp 0 nb)) (was (logbitp 0 lb)))
          (setf *zero-events*
                (append *zero-events*
                        (list (%zero-event (cond ((and down (not was)) 1)
                                                 ((and was (not down)) 3)
                                                 (down 2)
                                                 (t 5))
                                           *zero-px* *zero-py*)))))
        (if (and *zy* (fourth *zy*))
            (%zero-present-yuv (fourth *zy*))
            (progn (%zero-pointer-hide) (%zero-pointer-show))))
      (setf *zero-mx* nx *zero-my* ny *zero-mb* nb))))

;;; COLLECT WHILE IDLE.  A collection stops everything for as long as copying the live heap
;;; takes -- ~115 ms on the Zero, its ~20 MB mostly the restored core -- so the desk picks the
;;; moment: after half a second with no input, if 4 MB or more has been allocated since the last
;;; collection.  Then the pause lands where nobody is moving anything, and a gesture that
;;; follows starts with the whole semispace free.

(defparameter *kz-idle-gc-us* 500000)     ; quiet this long first (internal time units: µs)
(defparameter *kz-idle-gc-bytes* 4000000) ; and at least this much allocated since the last GC
(defvar *kz-active-at* 0)
(defvar *kz-frame-at* 0)
(defvar *kz-just-drew* nil)      ; the last answer was a frame: input goes next
(defvar *kz-frame-limit* nil)             ; frames left before the desk ends itself (tests), or NIL                  ; GET-INTERNAL-REAL-TIME of the last frame %ZERO-NEXT-EVENT let through                 ; GET-INTERNAL-REAL-TIME of the last input event
(defvar *kz-gc-mark-count* -1)            ; (%GC-COUNT) and (GET-ALLOC-PTR) right after the
(defvar *kz-gc-mark-ptr* 0)               ; last collection this desk saw

(defun %zero-idle-gc ()
  (let ((now (get-internal-real-time)))
    (when (> (- now *kz-active-at*) *kz-idle-gc-us*)
      (when (or (/= (%gc-count) *kz-gc-mark-count*)       ; one happened anyway: re-mark only
                (> (- (get-alloc-ptr) *kz-gc-mark-ptr*) *kz-idle-gc-bytes*))
        (when (= (%gc-count) *kz-gc-mark-count*) (sb-ext:gc))
        (setf *kz-gc-mark-count* (%gc-count) *kz-gc-mark-ptr* (get-alloc-ptr))))))

;;; THE SERIAL LINE STAYS A REPL WHILE THE DESK RUNS.  The desk owns the main thread, and the
;;; REPL is that thread's reader loop, so running the desk used to mean losing the console: bytes
;;; were dropped except Ctrl-C/q, and finding out why something on the board had stopped meant
;;; resetting it.  Now the bytes are collected into a line; a line that completes a form is
;;; READ and EVALuated here, between frames, its values printed back, then a DESK> prompt.
;;; Ctrl-C still ends the desk.  A form runs ON the desk's thread, so a long one holds the
;;; screen still while it runs -- and an error is printed, never thrown into the app.

(defvar *zero-repl-buf* (make-array 256 :element-type 'character :fill-pointer 0 :adjustable t))

(defun %zero-repl-complete-p (s)
  "S holds at least one whole form: parentheses balanced outside strings, characters and
   comments, and something other than whitespace."
  (let ((depth 0) (in-string nil) (any nil) (i 0) (n (length s)))
    (loop while (< i n)
          do (let ((c (char s i)))
               (cond (in-string (cond ((char= c #\\) (incf i))
                                      ((char= c #\") (setf in-string nil))))
                     ((char= c #\") (setf in-string t any t))
                     ((char= c #\;) (loop while (and (< i n) (char/= (char s i) #\Newline)) do (incf i)))
                     ((and (char= c #\#) (< (1+ i) n) (char= (char s (1+ i)) #\\)) (incf i 2) (setf any t))
                     ((char= c #\() (incf depth) (setf any t))
                     ((char= c #\)) (decf depth))
                     ((not (member c '(#\Space #\Tab #\Newline #\Return))) (setf any t))))
             (incf i))
    (and any (<= depth 0) (not in-string))))

(defun %zero-repl-eval (s)
  (let ((out (handler-case
                 (let ((vals (multiple-value-list (eval (read-from-string s)))))
                   (format nil "~{~s~^~%~}" vals))
               (error (e) (handler-case (format nil ";; error: ~a" e)
                            (error () ";; error (unprintable)"))))))
    (format t "~&~a~%DESK> " out)
    (finish-output)))

(defun %zero-repl-char (c)
  (let ((code (if (characterp c) (char-code c) c)) (buf *zero-repl-buf*))
    (cond ((= code 3) (throw 'kiln-zero-exit nil))          ; Ctrl-C: leave the desk
          ((member code '(8 127))                            ; backspace
           (when (> (fill-pointer buf) 0) (decf (fill-pointer buf))))
          ((member code '(10 13))
           (vector-push-extend #\Newline buf)
           (cond ((%zero-repl-complete-p buf)
                  (let ((form (copy-seq buf)))
                    (setf (fill-pointer buf) 0)
                    (%zero-repl-eval form)))
                 ((not (find-if-not (lambda (ch) (member ch '(#\Space #\Tab #\Newline))) buf))
                  (setf (fill-pointer buf) 0))))             ; blank line: a stray, dropped
          ((< code 256) (vector-push-extend (code-char code) buf)))))

(defun %zero-next-event ()
  ;; The serial line: a REPL (above).  At most 64 bytes a call, so a paste cannot hold a frame.
  (dotimes (i 64)
    (unless (hid-serial-ready-p) (return))
    (%zero-repl-char (read-char-serial)))
  ;; A FRAME IS DUE every 16 ms whatever the input is doing.  The app loop handles one event per
  ;; call and draws only when this answers 0, and a mouse polled faster than its report interval
  ;; has fresh movement for nearly every poll: a drag delivered ~440 events a second, the desk
  ;; drew in the gaps, and the window being dragged moved in jumps 150+ ms apart while the
  ;; pointer (drawn here, from the poll) stayed smooth.
  (let ((now (get-internal-real-time)))
    (when *kz-frame-limit*                ; a test's bounded run: end after that many frames
      (when (<= *kz-frame-limit* 0) (throw 'kiln-zero-exit nil)))
    ;; THE FIRST CALL AFTER A FRAME IS INPUT'S TURN.  The app draws and then sleeps out the rest
    ;; of its 16 ms, so by the next call a frame is always due again: without this window the
    ;; branch that hands out events never ran, and every click queued up unread.
    (when *kz-just-drew*
      (setf *kz-just-drew* nil *kz-frame-at* now)
      (unless *zero-events* (%zero-poll)))
    (if (> (- now *kz-frame-at*) 16000)
        (progn (setf *kz-frame-at* now *kz-just-drew* t)
               (when *kz-frame-limit* (setq *kz-frame-limit* (- *kz-frame-limit* 1)))
               0)
        (progn
          (unless *zero-events* (%zero-poll))
          (if *zero-events*
              (progn (setf *kz-active-at* now)
                     (pop *zero-events*))
              (progn (setf *kz-frame-at* now)
                     (when *kz-main-net* (funcall *kz-main-net*))
                     (%zero-idle-gc) 0))))))

;;; --- the screen in Y'CbCr: glass :I420 scanned out by the HVS -----------------------------
;;;
;;; With media, the desk and every window are glass :I420 framebuffers (planar Y'CbCr 4:2:0),
;;; and the screen is the HVS scanning those planes out: a decoded picture is copied plane by
;;; plane into its window, the window into the desk, the desk into a scanout buffer -- never
;;; RGB, and the HVS scales it to the display.  (The text console's own framebuffer stays where
;;; it is; leaving the app points the HVS back at it.)
;;;
;;; Two scanout buffers in one 2 MB block at 0x11600000 (free DRAM; the r8152 aggregate is at
;;; 0x11400000), remapped non-cacheable so the HVS sees every store: a present copies the
;;; desk's planes into the back one (the console's native 64-byte copy), draws the pointer into
;;; its luma, and flips the three plane pointers in the display list.  Display-list entry and
;;; scaling kernel: the reel-on-zero player's (docs/reel-on-zero, rh-plane-words), format 8.

(defun %zy-buf-base () #x11600000)
(defun %zy-buf-bytes () #x80000)         ; 512 KB each: 640x400 is 384 000
(defun %zy-hvs () #x3F400000)
(defun %zy-slot () 2000)
(defun %zy-kernel-slot () 2100)
(defun %zy-slot-wr (slot w) (setf (mem-ref (+ (%zy-hvs) #x2000 (* slot 4)) :u32) w))

(defun %zy-upload-kernel ()
  (flet ((ppf (c0 c1 c2) (logior (logand c0 511) (ash (logand c1 511) 9) (ash (logand c2 511) 18))))
    (let* ((c '(0 -2 -6 -8 -10 -8 -3 2 18 50 82 119 155 187 213 227))
           (k6 (list (ppf (nth 0 c) (nth 1 c) (nth 2 c)) (ppf (nth 3 c) (nth 4 c) (nth 5 c))
                     (ppf (nth 6 c) (nth 7 c) (nth 8 c)) (ppf (nth 9 c) (nth 10 c) (nth 11 c))
                     (ppf (nth 12 c) (nth 13 c) (nth 14 c)) (ppf (nth 15 c) (nth 15 c) 0))))
      (dotimes (i 11) (%zy-slot-wr (+ (%zy-kernel-slot) i) (nth (if (< i 6) i (- 10 i)) k6))))))

(defun %zy-words (sw sh ptrs dw dh)
  "The display-list entry for a 4:2:0 SW x SH picture at PTRS, scaled to DW x DH at (0,0)."
  (let ((ks (%zy-kernel-slot))
        (ppf (lambda (s d) (logior (ash 1 30) (ash (floor (* 65536 s) d) 8)))))
    (list (logior (ash 1 30) (ash 28 24) 8) #xFF000000 (logior (ash dh 16) dw)
          (logior (ash 1 30) (ash sh 16) sw) #xC0C0C0C0
          (logior #xC0000000 (first ptrs)) (logior #xC0000000 (second ptrs)) (logior #xC0000000 (third ptrs))
          #xC0C0C0C0 #xC0C0C0C0 #xC0C0C0C0 sw (ceiling sw 2) (ceiling sw 2)
          #x00f00000 #xe73304a8 #x00066604 0
          (funcall ppf (ceiling sw 2) dw) (funcall ppf (ceiling sh 2) dh) #xC0C0C0C0
          (funcall ppf sw dw) (funcall ppf sh dh) #xC0C0C0C0 ks ks ks ks #x80000000)))

(defun %zy-ptrs (buf fb)
  (let ((ysz (* (glass:fb-width fb) (glass:fb-height fb)))
        (csz (* (glass:fb-chroma-width fb) (glass:fb-chroma-height fb))))
    (list buf (+ buf ysz) (+ buf ysz csz))))

(defun %zy-pointer (buf fb)
  "The arrow into BUF's luma at the pointer's place (black outline, white body) -- unless the
   pointer is the hardware cursor."
  (when *kz-hw-cursor* (return-from %zy-pointer nil))
  (let ((fw (glass:fb-width fb)) (fh (glass:fb-height fb)))
    (dotimes (r 16)
      (let ((line (nth r *zero-arrow*)) (y (+ *zero-py* r)))
        (when (< y fh)
          (dotimes (c 11)
            (let ((x (+ *zero-px* c)) (ch (char line c)))
              (when (and (< x fw) (char/= ch #\Space))
                (setf (mem-ref (+ buf (* y fw) x) :u8) (if (char= ch #\2) 16 235))))))))))

(defun %zy-copy (dst src bytes)
  (hcon-ncopy dst src (logand (+ bytes 63) (lognot 63))))

(defvar *zy-presents* 0)
(defvar *zy-first* nil)   ; GET-INTERNAL-REAL-TIME of this run's first and latest present: the
(defvar *zy-last* nil)    ; frame rate, measured on the screen, is printed on leaving
(defun %zero-present-yuv (fb)
  "Show :I420 framebuffer FB: copy its planes into the back scanout buffer, draw the pointer,
   point the HVS at it."
  (unless *zy*
    (hcon-map-nc (%zy-buf-base) #x200000)
    ;; The OUTPUT size is the HVS channel's (DISPCTRL1: width bits 23:12, height 11:0) --
    ;; the firmware's "physical display" is the console's 640-wide buffer, not the monitor
    (let* ((ctl (mem-ref (+ (%zy-hvs) #x50) :u32))
           (dw (logand (ash ctl -12) 4095)) (dh (logand ctl 4095)))
      (setf *zy* (list (list (%zy-buf-base) (+ (%zy-buf-base) (%zy-buf-bytes)))
                       0 (mem-ref (+ (%zy-hvs) #x24) :u32) nil
                       (if (plusp dw) dw 1920) (if (plusp dh) dh 1080))))
    (%zy-upload-kernel))
  (destructuring-bind (bufs back old last dw dh) *zy*
    (declare (ignore old))
    (let* ((buf (nth back bufs))
           (ysz (* (glass:fb-width fb) (glass:fb-height fb)))
           (csz (* (glass:fb-chroma-width fb) (glass:fb-chroma-height fb)))
           (ptrs (%zy-ptrs buf fb)))
      (%zy-copy (first ptrs) (+ (%val->word (glass:fb-y fb)) 7) ysz)
      (%zy-copy (second ptrs) (+ (%val->word (glass:fb-u fb)) 7) csz)
      (%zy-copy (third ptrs) (+ (%val->word (glass:fb-v fb)) 7) csz)
      (%zy-pointer buf fb)
      (if last
          ;; the entry is there: swap its three plane pointers
          (progn (%zy-slot-wr (+ (%zy-slot) 5) (logior #xC0000000 (first ptrs)))
                 (%zy-slot-wr (+ (%zy-slot) 6) (logior #xC0000000 (second ptrs)))
                 (%zy-slot-wr (+ (%zy-slot) 7) (logior #xC0000000 (third ptrs))))
          ;; the display's width, and the height that keeps the desk's aspect
          (let* ((i 0) (sh (min dh (floor (* dw (glass:fb-height fb)) (glass:fb-width fb))))
                 (words (%zy-words (glass:fb-width fb) (glass:fb-height fb) ptrs dw sh)))
            ;; THE HARDWARE CURSOR rides after the picture, before END (threaded desks)
            (when *kz-hw-cursor*
              (setq words (append (butlast words)
                                  (%kz-cur-yuv-words (glass:fb-width fb) (glass:fb-height fb) dw sh)
                                  (last words))))
            (dolist (w words)
              (%zy-slot-wr (+ (%zy-slot) i) w) (setq i (+ i 1)))
            (setf (mem-ref (+ (%zy-hvs) #x24) :u32) (%zy-slot))))
      (setf (second *zy*) (- 1 back) (fourth *zy*) fb)
      (setq *zy-presents* (+ *zy-presents* 1))
      (setq *zy-last* (get-internal-real-time))
      (unless *zy-first* (setq *zy-first* *zy-last* *zy-presents* 1)))))

(defun %zero-yuv-restore ()
  "Point the HVS back at the text console."
  (when *zy*
    (setf (mem-ref (+ (%zy-hvs) #x24) :u32) (third *zy*))
    (setf *zy* nil))
  (when (and *zy-first* (> *zy-presents* 1) (> *zy-last* *zy-first*))
    (let ((ms (round (- *zy-last* *zy-first*) (floor internal-time-units-per-second 1000))))
      (format t "~&KZ: ~d presents in ~d ms = ~,2f fps~%" *zy-presents* ms
              (/ (* 1000.0 (- *zy-presents* 1)) ms))))
  (setq *zy-first* nil *zy-last* nil *zy-presents* 0))

;;; --- the hardware cursor and vsync (HVS) ---------------------------------------------------
;;;
;;; The pointer is a plane of its own in the HVS display list: a small unscaled RGBA image above
;;; the desk's plane (Linux vc4_plane.c GEN_4, 7 words: CTL0 POS0 POS2 POS3 PTR0 PTR0-context
;;; PITCH0; the first entry in a list is the bottom).  Moving it is one word, POS0, rewritten
;;; when the HVS has finished compositing a frame (DISPSTAT1 MODE = EOF) -- no pixels copied,
;;; never torn, at most once a frame.  The desk's own plane: on the Y'CbCr path the entry this
;;; file builds (%ZY-WORDS); on the RGB path the FIRMWARE's console entry, copied into slots of
;;; ours with the cursor appended, DISPLIST1 pointed at the copy (and back on leaving).
;;;
;;; VSYNC: DISPSTAT1 (HVS + 0x58) -- MODE 31:30 (3 = end of frame), FRCNT 17:12 (a frame counter)
;;; -- polled, read only, so nothing races the firmware for it.  A Y'CbCr present swaps its
;;; plane pointers at end of frame too.
;;;
;;; The image (11 x 16 arrow, scaled by the desk's own scale to the display) is ARGB8888 --
;;; a :u32 #xAARRGGBB, transparent 0 -- in the non-cacheable scanout block at 0x117F0000.

(defvar *kz-cur* nil)   ; (pos0-slot pos2-slot w h x0 y0 dstw dsth fbw fbh dw dh old-list) once on
(defun %kz-cur-image () #x117F0000)
(defun %kz-dispstat () (mem-ref (+ (%zy-hvs) #x58) :u32))
(defun %kz-frcnt () (logand (ash (%kz-dispstat) -12) 63))

(defun %kz-wait-eof ()
  "Until the HVS has finished this frame (MODE = EOF); at most 50 ms (a disabled channel)."
  (let ((dl (+ (rdtsc) (floor (cntfrq) 20))))
    (loop (when (or (= (ash (%kz-dispstat) -30) 3) (>= (rdtsc) dl)) (return nil)))))

(defun %kz-wait-vsync ()
  "Until the next frame has been composited: the frame counter moves, then end of frame."
  (let ((f (%kz-frcnt)) (dl (+ (rdtsc) (floor (cntfrq) 20))))
    (loop (when (or (/= (%kz-frcnt) f) (>= (rdtsc) dl)) (return nil)))
    (%kz-wait-eof)))

(defun %kz-cur-make-image (k)
  "The arrow at K x into the image page; (values w h)."
  (let ((w (* 11 k)) (h (* 16 k)) (img (%kz-cur-image)))
    (dotimes (y h)
      (let ((line (nth (floor y k) *zero-arrow*)))
        (dotimes (x w)
          (setf (mem-ref (+ img (* 4 (+ (* y w) x))) :u32)
                (case (char line (floor x k)) (#\2 #xFF000000) (#\1 #xFFFFFFFF) (t 0))))))
    (mfence)
    (values w h)))

(defun %kz-cur-words (x y w h)
  (list #x47007817 (logior #xFF000000 (ash y 12) x) (logior (ash h 16) w) #xC0C0C0C0
        (logior #xC0000000 (%kz-cur-image)) #xC0C0C0C0 (* 4 w)))

(defun %kz-cur-pos (px py)
  "Display position of desk pixel (PX, PY) and the plane's clipped size: (values x y w h)."
  (destructuring-bind (s0 s2 w h x0 y0 dstw dsth fbw fbh dw dh old) *kz-cur*
    (declare (ignore s0 s2 old))
    (let ((x (min (1- dw) (+ x0 (floor (* px dstw) fbw))))
          (y (min (1- dh) (+ y0 (floor (* py dsth) fbh)))))
      (values x y (max 1 (min w (- dw x))) (max 1 (min h (- dh y)))))))

(defun %kz-cur-move (px py)
  "Put the cursor plane at desk pixel (PX, PY): at end of frame, POS0 (and POS2 at an edge)."
  (when *kz-cur*
    (multiple-value-bind (x y w h) (%kz-cur-pos px py)
      (%kz-wait-eof)
      (%zy-slot-wr (first *kz-cur*) (logior #xFF000000 (ash y 12) x))
      (%zy-slot-wr (second *kz-cur*) (logior (ash h 16) w))
      (mfence))))

(defun %kz-display-size ()
  (let* ((ctl (mem-ref (+ (%zy-hvs) #x50) :u32))
         (dw (logand (ash ctl -12) 4095)) (dh (logand ctl 4095)))
    (values (if (plusp dw) dw 1920) (if (plusp dh) dh 1080))))

(defun %kz-cur-install-rgb ()
  "RGB desk: copy the firmware's display-list entry for the console framebuffer into slots
   2200.., append the cursor plane, point DISPLIST1 at the copy.  NIL if the entry is not a
   single plane this understands."
  (let* ((old (mem-ref (+ (%zy-hvs) #x24) :u32))
         (words nil) (n 0))
    (loop (let ((w (mem-ref (+ (%zy-hvs) #x2000 (* (+ old n) 4)) :u32)))
            (when (or (= w #x80000000) (> n 64)) (return nil))
            (push w words) (setq n (+ n 1))))
    (setq words (nreverse words))
    (when (or (> n 64) (< n 4) (/= n (logand (ash (first words) -24) 63)))
      (return-from %kz-cur-install-rgb nil))     ; not exactly one plane entry
    (multiple-value-bind (dw dh) (%kz-display-size)
      (let* ((unity (logbitp 4 (first words)))
             (pos0 (second words))
             (x0 (logand pos0 4095)) (y0 (logand (ash pos0 -12) 4095))
             (fbw (hcon-get #x0C)) (fbh (hcon-get #x10))
             (dst (if unity nil (third words)))
             (dstw (if dst (logand dst #xFFF) fbw)) (dsth (if dst (logand (ash dst -16) #xFFF) fbh))
             (k (max 1 (round dstw fbw))))
        (hcon-map-nc (%zy-buf-base) #x200000)
        (multiple-value-bind (w h) (%kz-cur-make-image k)
          (let ((slot 2200) (i 0))
            (dolist (wd words) (%zy-slot-wr (+ slot i) wd) (setq i (+ i 1)))
            (setf *kz-cur* (list (+ slot i 1) (+ slot i 2) w h x0 y0 dstw dsth fbw fbh dw dh old))
            (multiple-value-bind (cx cy cw ch) (%kz-cur-pos *zero-px* *zero-py*)
              (dolist (wd (%kz-cur-words cx cy cw ch)) (%zy-slot-wr (+ slot i) wd) (setq i (+ i 1))))
            (%zy-slot-wr (+ slot i) #x80000000)
            (mfence)
            (%kz-wait-eof)
            (setf (mem-ref (+ (%zy-hvs) #x24) :u32) slot)
            t))))))

(defun %kz-cur-yuv-words (fbw fbh dw sh)
  "The cursor entry for the Y'CbCr desk (scaled to DW x SH at 0,0), and *KZ-CUR* for it; the
   POS0 slot is fixed by where %ZERO-PRESENT-YUV writes it (after the 28-word picture entry)."
  (let ((k (max 1 (round dw fbw))))
    (multiple-value-bind (w h) (%kz-cur-make-image k)
      (multiple-value-bind (dw2 dh2) (%kz-display-size)
        (declare (ignore dw2))
        (setf *kz-cur* (list (+ (%zy-slot) 29) (+ (%zy-slot) 30) w h 0 0 dw sh fbw fbh dw dh2 nil))
        (multiple-value-bind (cx cy cw ch) (%kz-cur-pos *zero-px* *zero-py*)
          (%kz-cur-words cx cy cw ch))))))

(defun %kz-cur-uninstall ()
  (when *kz-cur*
    (let ((old (car (last *kz-cur*))))
      (when old (%kz-wait-eof) (setf (mem-ref (+ (%zy-hvs) #x24) :u32) old)))
    (setf *kz-cur* nil)))

;;; --- the screen thread (kiln zero --threads) ----------------------------------------------
;;;
;;; Everything that writes the screen runs on one thread, an executor pinned to core 2: the
;;; desk's blits and presents (main hands them over with BT-CALL) and the POINTER, which it
;;; moves itself whenever the mouse counters (kept by the USB thread) change -- so the arrow
;;; follows the mouse at the poll rate however long the desk takes over a frame, and main never
;;; redraws or re-presents for it.  It owns *ZERO-PX*/*ZERO-PY*; main only reads them to make
;;; its pointer events.  On the Y'CbCr path a present copies the desk's planes once into a
;;; CLEAN buffer (cacheable, at 0x10900000) and every frame shown -- a present or a pointer move
;;; -- is built from it, so a pointer move never reads planes the desk may be drawing into.

(defvar *kz-scr* nil)
(defvar *kz-scr-mx* 0)                    ; the mouse counters this thread last applied
(defvar *kz-scr-my* 0)
(defun %kz-clean () #x10900000)           ; 512 KB, free RAM (modus test/rpi-smp/README.md map)

(defun %kz-zy-show (fb)
  "Build the back scanout buffer from the clean copy of FB's planes, draw the pointer, flip."
  (destructuring-bind (bufs back old last dw dh) *zy*
    (declare (ignore old last dw dh))
    (let* ((buf (nth back bufs))
           (bytes (+ (* (glass:fb-width fb) (glass:fb-height fb))
                     (* 2 (glass:fb-chroma-width fb) (glass:fb-chroma-height fb))))
           (ptrs (%zy-ptrs buf fb)))
      (%zy-copy buf (%kz-clean) bytes)
      (%zy-pointer buf fb)
      (%zy-slot-wr (+ (%zy-slot) 5) (logior #xC0000000 (first ptrs)))
      (%zy-slot-wr (+ (%zy-slot) 6) (logior #xC0000000 (second ptrs)))
      (%zy-slot-wr (+ (%zy-slot) 7) (logior #xC0000000 (third ptrs)))
      (setf (second *zy*) (- 1 back))
      (setq *zy-presents* (+ *zy-presents* 1))
      (setq *zy-last* (get-internal-real-time))
      (unless *zy-first* (setq *zy-first* *zy-last* *zy-presents* 1)))))

(defun %kz-present-yuv (fb)
  "On the screen thread: FB's planes into the clean buffer, then show it.  The first present
   (the display-list entry, the scaling kernel) is the ordinary one."
  (if (or (null *zy*) (null (fourth *zy*)))
      (progn (%zero-present-yuv fb)
             (let ((ysz (* (glass:fb-width fb) (glass:fb-height fb)))
                   (csz (* (glass:fb-chroma-width fb) (glass:fb-chroma-height fb))))
               (%zy-copy (%kz-clean) (+ (%val->word (glass:fb-y fb)) 7) ysz)
               (%zy-copy (+ (%kz-clean) ysz) (+ (%val->word (glass:fb-u fb)) 7) csz)
               (%zy-copy (+ (%kz-clean) ysz csz) (+ (%val->word (glass:fb-v fb)) 7) csz)))
      (if *kz-hw-cursor*
          ;; no arrow to keep out of the picture: straight into the back buffer, then the
          ;; plane pointers swapped at END OF FRAME (vsync -- a swap mid-frame can tear)
          (destructuring-bind (bufs back old last dw dh) *zy*
            (declare (ignore old last dw dh))
            (let* ((buf (nth back bufs)) (ptrs (%zy-ptrs buf fb))
                   (ysz (* (glass:fb-width fb) (glass:fb-height fb)))
                   (csz (* (glass:fb-chroma-width fb) (glass:fb-chroma-height fb))))
              (%zy-copy (first ptrs) (+ (%val->word (glass:fb-y fb)) 7) ysz)
              (%zy-copy (second ptrs) (+ (%val->word (glass:fb-u fb)) 7) csz)
              (%zy-copy (third ptrs) (+ (%val->word (glass:fb-v fb)) 7) csz)
              (%kz-wait-eof)
              (%zy-slot-wr (+ (%zy-slot) 5) (logior #xC0000000 (first ptrs)))
              (%zy-slot-wr (+ (%zy-slot) 6) (logior #xC0000000 (second ptrs)))
              (%zy-slot-wr (+ (%zy-slot) 7) (logior #xC0000000 (third ptrs)))
              (setf (second *zy*) (- 1 back) (fourth *zy*) fb)
              (setq *zy-presents* (+ *zy-presents* 1) *zy-last* (get-internal-real-time))
              (unless *zy-first* (setq *zy-first* *zy-last* *zy-presents* 1))))
      (let ((ysz (* (glass:fb-width fb) (glass:fb-height fb)))
            (csz (* (glass:fb-chroma-width fb) (glass:fb-chroma-height fb))))
        (%zy-copy (%kz-clean) (+ (%val->word (glass:fb-y fb)) 7) ysz)
        (%zy-copy (+ (%kz-clean) ysz) (+ (%val->word (glass:fb-u fb)) 7) csz)
        (%zy-copy (+ (%kz-clean) ysz csz) (+ (%val->word (glass:fb-v fb)) 7) csz)
        (setf (fourth *zy*) fb)
        (%kz-zy-show fb))))
  0)

(defun %kz-scr-idle ()
  "The screen thread between calls: follow the mouse."
  (when *kz-scr-paused* (return-from %kz-scr-idle nil))
  (let ((nx (mouse-x)) (ny (mouse-y)))
    (when (or (/= nx *kz-scr-mx*) (/= ny *kz-scr-my*))
      (setf *zero-px* (max 0 (min (1- (hcon-get #x0C)) (+ *zero-px* (- nx *kz-scr-mx*))))
            *zero-py* (max 0 (min (1- (hcon-get #x10)) (+ *zero-py* (- ny *kz-scr-my*))))
            *kz-scr-mx* nx *kz-scr-my* ny)
      (cond (*kz-hw-cursor* (%kz-cur-move *zero-px* *zero-py*))   ; one word, at end of frame
            ((and *zy* (fourth *zy*)) (%kz-zy-show (fourth *zy*)))
            (t (%zero-pointer-hide) (%zero-pointer-show))))))

(defvar *kz-scr-paused* nil)              ; T: the screen thread leaves the pointer alone

(defun %kz-on-screen (fn)
  "FN on the screen thread when there is one, else here."
  (if *kz-scr* (bt-call *kz-scr* fn) (funcall fn)))

(defun kz-scr-start (&optional yuv)
  "Start the screen thread on core 2 (after the USB thread).  YUV: the desk will be Y'CbCr
   (its first present puts the cursor in its own display list).  The handle, or NIL without
   threads."
  (when (and (null *kz-scr*) *kz-usb* (fboundp 'bt-start-executor))
    (%zero-blit-code)                     ; the exec page, made here: the JIT's bump is main's
    (setf *kz-scr-mx* (mouse-x) *kz-scr-my* (mouse-y))
    ;; THE HARDWARE CURSOR, on main (its state is main's): on the RGB desk now, over the
    ;; firmware's plane; on the Y'CbCr desk with the first present.  The software arrow stays
    ;; if the firmware's entry is not one plane this understands.
    (setf *kz-scr* (bt-start-executor 2 #'%kz-scr-idle)))
  (when (and *kz-scr* (null *kz-cur*))
    (setf *kz-hw-cursor* t)
    (unless (or yuv (%kz-cur-install-rgb))
      (setf *kz-hw-cursor* nil)))
  (when *kz-scr*
    (bt-call *kz-scr* (lambda () (setf *kz-scr-mx* (mouse-x) *kz-scr-my* (mouse-y)
                                       *kz-scr-paused* nil) 0)))
  *kz-scr*)

;;; --- the audio thread (kiln zero --threads) -----------------------------------------------
;;;
;;; Sound goes out over HDMI (modus net/hdmi-audio.lisp: LPCM into the firmware's HDMI link,
;;; config.txt hdmi_drive=2).  Its FIFO is fed by a polled pump, so an executor on core 3 runs
;;; HDMI-AUDIO-PUMP over and over; anything that makes sound fills the ring with
;;; HDMI-AUDIO-WRITE / -WRITE-FRAMES (48 kHz stereo 16-bit).  (kz-beep) is the smoke test.

(defvar *kz-audio* nil)
(defvar *kz-audio-start* nil)             ; what HDMI-AUDIO-START answered: T or why not

(defun %kz-audio-idle () (hdmi-audio-pump))

(defun kz-audio-start ()
  "Bring HDMI audio up and start the audio thread on core 3.  Its handle, or NIL (no threads,
   or the link has no audio: *KZ-AUDIO-START* says why)."
  (when (and (null *kz-audio*) *kz-usb* (fboundp 'bt-start-executor) (fboundp 'hdmi-audio-start))
    (setf *kz-audio-start* (hdmi-audio-start 48000))
    (when (eq *kz-audio-start* t)
      (setf *kz-audio* (bt-start-executor 3 #'%kz-audio-idle))))
  *kz-audio*)

(defun kz-beep (&optional (hz 440) (ms 300))
  "A triangle-wave tone through HDMI (starts the audio thread if need be)."
  (kz-audio-start)
  (if *kz-audio* (hdmi-audio-tone hz ms) *kz-audio-start*))

;;; --- screen --------------------------------------------------------------------------------

(defvar *zero-blit-code* nil)             ; the native row copier's exec page, once made

(defun %zero-blit-words (scr)
  ;; movz/movk x3 = SCR; ldp x0,x1 / x2,x4 / x5,x6 = dst src w h dst-stride src-stride;
  ;; per row: one odd pixel, then pairs -- ldp two words, lsr #1 each (the fixnum tag),
  ;; stp them as two u32 pixels; dsb; ret.  (as/objdump on the Pi 5: kiln's asm is not
  ;; in the image.)
  (list (logior #xD2800003 (ash (logand scr #xFFFF) 5))
        (logior #xF2A00003 (ash (logand (ash scr -16) #xFFFF) 5))
        #xA9400460 #xA9411062 #xA9421865 #xB4000284 #xAA0003E7 #xAA0103E8 #xAA0203E9
        #x360000A9 #xF840850A #xD341FD4A #xB80044EA #xD1000529 #xB40000E9 #xA8C12D0A
        #xD341FD4A #xD341FD6B #x28812CEA #xD1000929 #x17FFFFFA #x8B050000 #x8B060021
        #xD1000484 #x17FFFFED #xD5033F9F #xD65F03C0))

(defun %zero-blit-code ()
  "The exec page holding the row copier (at 0) and its arguments (at 512)."
  (or *zero-blit-code*
      (let ((code (%mmap-exec-page 4096)))
        (hcon-poke code (%zero-blit-words (+ code 512)))
        (%jit-icache-flush code 512)
        (setf *zero-blit-code* code))))

(defun %zero-blit (addr wh xy stride)
  "Copy a block of tagged pixel words at ADDR (row length STRIDE) to the screen at XY.
   NATIVE: a pixel at a time in Lisp was 85 ns, a 260x110 window 3.4 ms of every drag
   frame; the row copier is a few instructions a pixel.  Nothing between taking ADDR and
   the call allocates, so the vector cannot move under it."
  (let* ((w (logand wh #xFFFF)) (h (floor wh 65536))
         (x0 (logand xy #xFFFF)) (y0 (floor xy 65536))
         (stride (if (zerop stride) w stride))
         (sw (hcon-get #x0C)) (sh (hcon-get #x10))
         (cols (min w (- sw x0))) (rows (min h (- sh y0))))
    (%zero-pointer-hide)
    (when (and (> cols 0) (> rows 0))
      (let* ((code (%zero-blit-code)) (scr (+ code 512)))
        (hcon-u64 scr (%zero-pixel-addr x0 y0))
        (hcon-u64 (+ scr 8) addr)
        (hcon-u64 (+ scr 16) cols)
        (hcon-u64 (+ scr 24) rows)
        (hcon-u64 (+ scr 32) (hcon-get #x08))
        (hcon-u64 (+ scr 40) (* 8 stride))
        (%jit-call code)))
    (%zero-pointer-show)
    0))

;;; --- glyphs, rendered before the core is saved -------------------------------------------
;;;
;;; Rasterising a glyph from its outline costs ~5 ms at 16 px on the Zero (40 px digits, more),
;;; and the desk loop is the render loop: the Clock's once-a-second redraw of a digit it had not
;;; drawn yet took a 20-40 ms frame.  The core build calls this after JIT-EAGER, so glass's glyph
;;; cache -- heap like everything else -- is saved full and a booted desk never rasterises what it
;;; shows.  Every glyph at all four of the cache's quarter-pixel pen offsets, since a run's later
;;; glyphs land on any of them.  Sizes and fonts are the desk's own (app.lisp: titles and menu
;;; 16, the Clock's 40 digits and 13 caption, Notes' 17 body and bold 22 title).

(defparameter *kz-prerender*
  '((nil 13 :ascii) (nil 16 :ascii) (nil 17 :ascii) (nil 40 "0123456789:") (t 22 :ascii)))

(defun kiln-zero-prerender-glyphs ()
  "Fill glass's glyph cache with *KZ-PRERENDER*.  Returns the cache's size."
  (dolist (spec *kz-prerender*)
    (destructuring-bind (bold size chars) spec
      (let ((font (glass:default-font bold))
            (codes (if (eq chars :ascii)
                       (loop for c from 32 to 126 collect c)
                       (map 'list (function char-code) chars))))
        (dolist (code codes)
          (let ((gid (scribe:font-glyph-index font code)))
            (dotimes (quarter 4)
              (glass::%glyph-entry font gid size quarter)))))))
  (glass::glyph-cache-count))

;;; Breadcrumbs on the serial port: each stage of KILN-ZERO-MAIN, and the FIRST use of each
;;; pseudo-syscall (size, fill, event, blit) -- so a start that never reaches the screen says
;;; how far it got.  The board is single-threaded: when the app is wedged, serial is the only
;;; voice it has.
(defvar *kz-said* 0)
(defun %kz-say (s) (write-string-serial s) (write-char-serial 10))

(defun %kiln-sys (n a b c &optional (d 0))
  (let ((bit (case n (1001 1) (1002 2) (1004 4) (1005 8) (t 0))))
    (when (and (plusp bit) (zerop (logand *kz-said* bit)))
      (setf *kz-said* (logior *kz-said* bit))
      (%kz-say (case n (1001 "KZ:size") (1002 "KZ:fill") (1004 "KZ:event") (t "KZ:blit")))))
  (case n
    (1001 (case a (0 (hcon-get #x0C)) (1 (hcon-get #x10)) (t 1)))
    (1002 (%kz-on-screen (lambda ()
                           (%zero-pointer-hide)
                           (hcon-nfill (hcon-get #x04) (* (hcon-get #x10) (hcon-get #x08)) c)
                           (%zero-pointer-show) 0)))
    (1004 (%zero-next-event))
    (1005 (%kz-on-screen (lambda () (%zero-blit a b c d))))
    ;; the FIRST present makes *ZY* (a list: main's, since a thread may not store its own
    ;; objects in a global); every later one is the screen thread's
    (1007 (cond ((null *kz-scr*) (%zero-present-yuv a))
                ((and *zy* (fourth *zy*)) (bt-call *kz-scr* (lambda () (%kz-present-yuv a))))
                (t (%kz-present-yuv a)))
          0)
    (1010 1)
    (t 0)))

(defun kiln-zero-main (&key media autoplay (yuv t) frames)
  "The phone app on the Zero's screen, until a character arrives on the serial port.  MEDIA
   opens the media player on the files under /media/ of the mounted cabinet (kiln zero
   --media installs the player, mounts the cabinet and puts the clips there); the player
   decodes on this thread, in the time between events (WARP-MEDIA:*COOPERATIVE*).  AUTOPLAY, a
   file name under /media/, starts it playing once the desk is up."
  ;; The screen's state block outlives a board reset: trust it only once this boot has
  ;; brought the console up (the kernel zeroes its ready word at reset).
  (unless (hcon-ready-p) (hcon-init))
  (setq *kz-frame-limit* frames)
  (kz-usb-start)                          ; threads: input on core 1 from here on
  (kz-scr-start (and media yuv))          ; ... and the screen on core 2
  ;; ... and HDMI audio on core 3 -- except for media: there core 3 decodes (and with no mixer
  ;; on the Zero yet, a film plays silent anyway)
  (unless media (kz-audio-start))
  (let ((ready (hcon-get 0)))
    (setf *zero-events* nil *zero-mouse* nil *zero-under* nil
          *zero-px* (floor (hcon-get #x0C) 2) *zero-py* (floor (hcon-get #x10) 2))
    (setf *kz-said* 0)
    (%kz-say "KZ:start")
    ;; bytes already waiting on serial are not a request to stop.  BOUNDED: the first start
    ;; after a netboot never drew, with netboot's LF left on the line -- a drain that
    ;; trusts READ-CHAR-SERIAL to empty the line it polls can spin forever if it does not.
    (dotimes (i 64) (if (hid-serial-ready-p) (read-char-serial) (return)))
    (%kz-say (if (hid-serial-ready-p) "KZ:serial-not-drained" "KZ:drained"))
    (hcon-put 0 0)                        ; the text console stops drawing
    (unwind-protect
         (catch 'kiln-zero-exit
           (%kz-say "KZ:app")
           (setf (fill-pointer *zero-repl-buf*) 0)
           (format t "~&DESK> ") (finish-output)       ; the serial line is a REPL from here
           (when media
             (setf *kiln-bundle-dir* "/")
             (flet ((wm (name v) (setf (symbol-value (find-symbol name "WARP-MEDIA")) v)))
               ;; the library lists audio only by default; a board with its own screen plays
               ;; films too -- the containers warp-media's engine opens
               (wm "*EXTENSIONS*" (append '("webm" "mkv" "mp4" "mpg" "mpeg" "ts")
                                          (symbol-value (find-symbol "*EXTENSIONS*" "WARP-MEDIA"))))
               ;; COOPERATIVE even on a threaded board: the decoder runs here, between events,
               ;; while USB, the screen and audio keep their cores.  Measured under QEMU on the
               ;; merged stack (2026-10-16): cooperative 3.57 fps; the decoder on its own thread
               ;; (warp-media's LINK, *FRAME-POOL*, *READ-ON-UI*) stalls -- under 40 presents in
               ;; 15 minutes -- for a reason not yet found.  Threaded decoding comes back when it
               ;; is: (wm "*COOPERATIVE*" nil) (wm "*READ-ON-UI*" t) (wm "*FRAME-POOL*" t).
               (wm "*COOPERATIVE*" t)))
           (if (and media yuv)
               ;; the screen in Y'CbCr: every framebuffer :I420, pictures stay planes
               (let ((glass:*default-fb-format* :i420))
                 (setf (symbol-value (find-symbol "*FRAME-FORMAT*" "WARP-MEDIA")) :i420)
                 (kiln-app-main :top 0 :media media :autoplay autoplay))
               (kiln-app-main :top 0 :media media :autoplay (and media autoplay))))
      (%kz-on-screen (lambda ()
                       (setf *kz-scr-paused* t)
                       (%kz-cur-uninstall)
                       (%zero-yuv-restore)
                       (%zero-pointer-hide)
                       0))
      (setf *kz-hw-cursor* nil)
      (hcon-put 0 ready)
      (hcon-nfill (hcon-get #x04) (* (hcon-get #x10) (hcon-get #x08)) (hcon-get #x28))
      (hcon-put #x1C 0) (hcon-put #x20 0))))
