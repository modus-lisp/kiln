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
;;;; A character on the serial port ends the app and gives the screen back to the text console.

(in-package :cl-user)

;;; app.lisp names the media player's symbols; without the player (MEDIA NIL) the packages
;;; still have to exist for the file to read.
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
(defvar *zero-under* nil)                 ; (x y . pixels) under the drawn pointer
(defvar *zero-px* 0)
(defvar *zero-py* 0)

(defun %zero-pixel-addr (x y) (+ (hcon-get #x04) (* y (hcon-get #x08)) (* x 4)))
(defun %zero-on-screen-p (x y) (and (< -1 x (hcon-get #x0C)) (< -1 y (hcon-get #x10))))

(defun %zero-pointer-hide ()
  (when *zero-under*
    (destructuring-bind (x y . saved) *zero-under*
      (dotimes (r 16)
        (dotimes (c 11)
          (let ((v (pop saved)))
            (when (%zero-on-screen-p (+ x c) (+ y r))
              (setf (mem-ref (%zero-pixel-addr (+ x c) (+ y r)) :u32) v))))))
    (setf *zero-under* nil)))

(defun %zero-pointer-show ()
  (let ((x *zero-px*) (y *zero-py*) (saved nil))
    (dotimes (r 16)
      (let ((line (nth r *zero-arrow*)))
        (dotimes (c 11)
          (if (%zero-on-screen-p (+ x c) (+ y r))
              (let ((a (%zero-pixel-addr (+ x c) (+ y r))))
                (push (mem-ref a :u32) saved)
                (case (char line c)
                  (#\2 (setf (mem-ref a :u32) #x000000))
                  (#\1 (setf (mem-ref a :u32) #xffffff))))
              (push 0 saved)))))
    (setf *zero-under* (list* x y (nreverse saved)))))

;;; --- events --------------------------------------------------------------------------------

(defvar *zero-events* nil)                ; queued app events, oldest first
(defvar *zero-mouse* nil)                 ; (x y buttons) of the mouse counters last seen

(defun %zero-keysym (c)
  (cond ((= c 13) #xff0d) ((= c 127) #xff08) ((= c 9) #xff09) ((= c 27) #xff1b) (t c)))

(defun %zero-event (type x y) (+ (* type 1099511627776) (* y 1048576) x))

(defun %zero-poll ()
  "Turn what the keyboard and mouse did since the last call into queued events."
  (hid-split-poll)
  (loop (let ((c (hid-ring-pop)))
          (when (< c 0) (return))
          (setf *zero-events* (append *zero-events*
                                      (list (+ (* 4 1099511627776) (%zero-keysym c)))))))
  (destructuring-bind (lx ly lb) (or *zero-mouse* (list (mouse-x) (mouse-y) (mouse-buttons)))
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
        (%zero-pointer-hide) (%zero-pointer-show))
      (setf *zero-mouse* (list nx ny nb)))))

(defun %zero-next-event ()
  (when (hid-serial-ready-p) (read-char-serial) (throw 'kiln-zero-exit nil))
  (unless *zero-events* (%zero-poll))
  (if *zero-events* (pop *zero-events*) 0))

;;; --- screen --------------------------------------------------------------------------------

(defun %zero-blit (addr wh xy stride)
  "Copy a block of tagged pixel words at ADDR (row length STRIDE) to the screen at XY."
  (let* ((w (logand wh #xFFFF)) (h (floor wh 65536))
         (x0 (logand xy #xFFFF)) (y0 (floor xy 65536))
         (stride (if (zerop stride) w stride))
         (sw (hcon-get #x0C)) (sh (hcon-get #x10)))
    (%zero-pointer-hide)
    (dotimes (r h)
      (let ((y (+ y0 r)))
        (when (< y sh)
          (let ((src (+ addr (* 8 r stride))) (dst (%zero-pixel-addr x0 y)))
            (dotimes (c (min w (- sw x0)))
              ;; a :u64 load hands back the element's fixnum value, i.e. the pixel
              (setf (mem-ref (+ dst (* 4 c)) :u32) (mem-ref (+ src (* 8 c)) :u64)))))))
    (%zero-pointer-show)
    0))

(defun %kiln-sys (n a b c &optional (d 0))
  (case n
    (1001 (case a (0 (hcon-get #x0C)) (1 (hcon-get #x10)) (t 1)))
    (1002 (%zero-pointer-hide)
          (hcon-nfill (hcon-get #x04) (* (hcon-get #x10) (hcon-get #x08)) c)
          (%zero-pointer-show) 0)
    (1004 (%zero-next-event))
    (1005 (%zero-blit a b c d))
    (1010 1)
    (t 0)))

(defun kiln-zero-main ()
  "The phone app on the Zero's screen, until a character arrives on the serial port."
  (let ((ready (hcon-get 0)))
    (setf *zero-events* nil *zero-mouse* nil *zero-under* nil
          *zero-px* (floor (hcon-get #x0C) 2) *zero-py* (floor (hcon-get #x10) 2))
    ;; bytes already waiting on serial are not a request to stop
    (loop (if (hid-serial-ready-p) (read-char-serial) (return)))
    (hcon-put 0 0)                        ; the text console stops drawing
    (unwind-protect
         (catch 'kiln-zero-exit (kiln-app-main :top 0 :media nil))
      (%zero-pointer-hide)
      (hcon-put 0 ready)
      (hcon-nfill (hcon-get #x04) (* (hcon-get #x10) (hcon-get #x08)) (hcon-get #x28))
      (hcon-put #x1C 0) (hcon-put #x20 0))))
