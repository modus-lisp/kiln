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
(defvar *zero-under* nil)                 ; (x y . pixels) under the drawn pointer
(defvar *zy* nil)          ; Y'CbCr screen: (bufs back-index old-displist fb dw dh) once set up
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
        (if (and *zy* (fourth *zy*))
            (%zero-present-yuv (fourth *zy*))
            (progn (%zero-pointer-hide) (%zero-pointer-show))))
      (setf *zero-mouse* (list nx ny nb)))))

(defun %zero-next-event ()
  ;; Ctrl-C or q on the serial port ends the app; any other byte is dropped.  It used to be
  ;; ANY byte, and the line carries strays (netboot's trailing LF, a reader opening the port):
  ;; the media app's first start ended itself before it had painted.
  (when (hid-serial-ready-p)
    (let ((c (read-char-serial)))
      (when (member (if (characterp c) (char-code c) c) '(3 113))
        (throw 'kiln-zero-exit nil))))
  (unless *zero-events* (%zero-poll))
  (if *zero-events* (pop *zero-events*) 0))

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
  "The arrow into BUF's luma at the pointer's place (black outline, white body)."
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
          (let ((i 0) (sh (min dh (floor (* dw (glass:fb-height fb)) (glass:fb-width fb)))))
            (dolist (w (%zy-words (glass:fb-width fb) (glass:fb-height fb) ptrs dw sh))
              (%zy-slot-wr (+ (%zy-slot) i) w) (setq i (+ i 1)))
            (setf (mem-ref (+ (%zy-hvs) #x24) :u32) (%zy-slot))))
      (setf (second *zy*) (- 1 back) (fourth *zy*) fb)
      (setq *zy-presents* (+ *zy-presents* 1)))))

(defun %zero-yuv-restore ()
  "Point the HVS back at the text console."
  (when *zy*
    (setf (mem-ref (+ (%zy-hvs) #x24) :u32) (third *zy*))
    (setf *zy* nil)))

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
    (1002 (%zero-pointer-hide)
          (hcon-nfill (hcon-get #x04) (* (hcon-get #x10) (hcon-get #x08)) c)
          (%zero-pointer-show) 0)
    (1004 (%zero-next-event))
    (1005 (%zero-blit a b c d))
    (1007 (%zero-present-yuv a) 0)
    (1010 1)
    (t 0)))

(defun kiln-zero-main (&key media autoplay (yuv t))
  "The phone app on the Zero's screen, until a character arrives on the serial port.  MEDIA
   opens the media player on the files under /media/ of the mounted cabinet (kiln zero
   --media installs the player, mounts the cabinet and puts the clips there); the player
   decodes on this thread, in the time between events (WARP-MEDIA:*COOPERATIVE*).  AUTOPLAY, a
   file name under /media/, starts it playing once the desk is up."
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
           (when media
             (setf *kiln-bundle-dir* "/")
             (setf (symbol-value (find-symbol "*COOPERATIVE*" "WARP-MEDIA")) t))
           (if (and media yuv)
               ;; the screen in Y'CbCr: every framebuffer :I420, pictures stay planes
               (let ((glass:*default-fb-format* :i420))
                 (setf (symbol-value (find-symbol "*FRAME-FORMAT*" "WARP-MEDIA")) :i420)
                 (kiln-app-main :top 0 :media media :autoplay autoplay))
               (kiln-app-main :top 0 :media media :autoplay (and media autoplay))))
      (%zero-yuv-restore)
      (%zero-pointer-hide)
      (hcon-put 0 ready)
      (hcon-nfill (hcon-get #x04) (* (hcon-get #x10) (hcon-get #x08)) (hcon-get #x28))
      (hcon-put #x1C 0) (hcon-put #x20 0))))
