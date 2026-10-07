;;;; ios.lisp — the iPhone app's entry point: glass on the phone's own screen.
;;;;
;;;; Loaded into the world `kiln ios' snapshots (boot/ios-world.lisp), so it is
;;;; native code by the time the phone runs it.  The app's modus.args say
;;;;   --core @kiln.core --eval (kiln-ios-main)
;;;; and this takes it from there: a glass framebuffer, the media player drawn
;;;; into it, touch turned into glass pointer events, and the picture copied to
;;;; the screen whenever the player repaints.  No VNC and no sockets: the
;;;; screen is the iOS shim's framebuffer (modus's host/ios/modus-ui.m),
;;;; reached through pseudo-syscalls 1001-1005.
;;;;
;;;; In CL-USER on purpose: it calls modus internals (%GC-SAFE-BLOCK-6,
;;;; %GC-WORD-OF, %CLI-COLLECT-ARGV), which a script names unqualified.

(defun %kiln-sys (n a b c &optional (d 0)) (%gc-safe-block-6 n a b c d))

(defun %kiln-bundle-dir ()
  "The app bundle: the directory of the file after --core (the shim resolved
   @kiln.core to a path beside the executable)."
  (let ((args (%cli-collect-argv)))
    (loop for (a b) on args
          when (and (stringp a) (string= a "--core") (stringp b))
            do (return (directory-namestring b)))))

(defun %kiln-blit (fb x y)
  "Copy glass framebuffer FB to the screen at (X, Y): pseudo-syscall 1005
   reads its pixel vector in place (element 0 is the vector's word + 7)."
  (let* ((px (glass::fb-pixels fb))
         (addr (+ (%gc-word-of px (%conv-addr #x100050A0)) 7)))
    (%kiln-sys 1005 addr (+ (glass::fb-width fb) (* (glass::fb-height fb) 65536))
               (+ x (* y 65536)))))

;;; THE SPEAKER.  glass's mixer normally runs its own 20 ms clock thread, and on modus that
;;; thread's frames cannot be stored into the shared mix (the store guard).  So here the MAIN
;;; loop is the clock: after each paint it tops the device's queue up to a cushion, one
;;; MIXER-TICK and one sink frame at a time.  The device -- an AudioQueue in the shim,
;;; pseudo-syscalls 1010-1012 -- keeps the real time and plays silence if the loop is late.
(defconstant +kiln-rate+ 48000)
(defparameter *kiln-cushion* 7200 "Samples to keep queued: 150 ms.")

(defun %kiln-audio-write (frame)
  (%kiln-sys 1011 (+ (%gc-word-of frame (%conv-addr #x100050A0)) 7) (length frame) 0))

(defun %kiln-pump-audio (mixer sink)
  "Mix and queue until the device holds *KILN-CUSHION* samples; at most a few ticks a call,
   so a long pause costs one cushion's catching-up and not a stall of the picture."
  (dotimes (i 12)
    (when (>= (%kiln-sys 1012 0 0 0) *kiln-cushion*) (return))
    (glass:mixer-tick mixer)
    (let ((f (glass:sink-next-frame sink)))
      (when f (%kiln-audio-write f)))))

(defun %kiln-clock-app (fb)
  "A second window for the desk: the time, redrawn once a second."
  (let ((last -1))
    (values nil nil
            (lambda ()
              (let ((now (get-universal-time)))
                (when (/= now last)
                  (setf last now)
                  (multiple-value-bind (s m h) (decode-universal-time now)
                    (glass:fb-fill fb #x10141a)
                    (glass:fb-text fb 16 20 (format nil "~2,'0d:~2,'0d:~2,'0d" h m s)
                                   :size 40 :color #xe6ebf2)
                    (glass:fb-text fb 16 80 "modus on the phone" :size 13 :color #x8b949e))
                  t))))))

(defun %kiln-keysym-char (ks)
  "The character an X11 KEYSYM types, or NIL."
  (cond ((= ks #xff0d) #\Newline)
        ((= ks #xff09) #\Space)
        ((<= #x20 ks #xff) (code-char ks))
        ((<= #x1000000 ks #x110ffff) (code-char (- ks #x1000000)))))

(defun %kiln-wrap (line width size font)
  "LINE broken into rows no wider than WIDTH at SIZE in FONT: at spaces, and inside a word only
   when the word alone is wider than a row."
  (let ((rows '()) (row ""))
    (flet ((fits (s) (<= (glass:text-width s :size size :font font) width)))
      (dolist (word (let ((acc '()) (start 0))          ; split, keeping each word's trailing space
                      (loop for k from 0 below (length line)
                            when (char= (char line k) #\Space)
                              do (push (subseq line start (1+ k)) acc) (setf start (1+ k)))
                      (push (subseq line start) acc)
                      (nreverse acc)))
        (cond ((fits (concatenate 'string row (string-right-trim " " word)))
               (setf row (concatenate 'string row word)))
              (t
               (when (plusp (length row)) (push row rows))
               (setf row "")
               ;; a word longer than a row: as many characters as fit, then the rest
               (loop for ch across word
                     do (if (fits (concatenate 'string row (string ch)))
                            (setf row (concatenate 'string row (string ch)))
                            (progn (push row rows) (setf row (string ch))))))))
      (push row rows)
      (nreverse rows))))

(defun %kiln-notes-app (fb)
  "Somewhere to type, looking like the phone's own notes: 17-point text on white, the first line
   a bold title, words wrapped whole, a thin gold caret.  The caret goes where you tap (and follows
   a drag), typing and Backspace work at it, a hardware keyboard's arrows move it, and the view
   scrolls to keep it in sight."
  (let ((lines (vector "")) (cl 0) (cc 0) (top-row 0) (dirty t)
        (body (glass:default-font)) (bold (glass:default-font t))
        (size 17) (lh 23) (tsize 22) (tlh 30) (margin 16) (top 14)
        (ink #x1c1c1e) (paper #xffffff) (caret #xe0a800)
        (layout nil))                     ; the visual rows, rebuilt when the text changes
    (labels ((style (li) (if (zerop li) (values bold tsize tlh) (values body size lh)))
             (rows ()
               ;; #((line start text font size height) ...): every visual row in order; a line's
               ;; rows partition it exactly, so START is the column its first character is at
               (or layout
                   (setf layout
                         (let ((w (- (glass:fb-width fb) (* 2 margin))) (out '()))
                           (dotimes (li (length lines) (coerce (nreverse out) 'vector))
                             (multiple-value-bind (font sz h) (style li)
                               (let ((start 0))
                                 (dolist (r (%kiln-wrap (aref lines li) w sz font))
                                   (push (list li start r font sz h) out)
                                   (incf start (length r))))))))))
             (changed () (setf layout nil dirty t))
             (caret-row ()
               ;; the row holding the caret: the last row of its line that starts at or before it
               (let ((rs (rows)) (best 0))
                 (dotimes (k (length rs) best)
                   (destructuring-bind (li start &rest _) (aref rs k)
                     (declare (ignore _))
                     (when (and (= li cl) (<= start cc)) (setf best k))))))
             (row-x (row col)
               ;; the x of column COL of ROW (COL relative to the line)
               (destructuring-bind (li start text font sz h) row
                 (declare (ignore li h))
                 (+ margin (glass:text-width (subseq text 0 (max 0 (min (length text) (- col start))))
                                             :size sz :font font))))
             (col-at (row x)
               ;; the column of ROW nearest the x coordinate X: the closest character boundary
               (destructuring-bind (li start text font sz h) row
                 (declare (ignore li h))
                 (let ((best 0) (bestd most-positive-fixnum) (w 0)
                       ;; a wrapped row's trailing space belongs before the next row, not after
                       (n (if (and (plusp (length text)) (char= (char text (1- (length text))) #\Space))
                              (1- (length text)) (length text))))
                   (loop for k from 0 to n
                         do (let ((d (abs (- (+ margin w) x))))
                              (when (< d bestd) (setf best k bestd d)))
                            (when (< k n)
                              (incf w (glass:text-width (string (char text k)) :size sz :font font))))
                   (+ start best))))
             (place (k x)
               ;; the caret onto visual row K at x X
               (let ((r (aref (rows) k))) (setf cl (first r) cc (col-at r x) dirty t)))
             (visible-count (from)
               (let ((room (- (glass:fb-height fb) top margin)) (used 0) (n 0) (rs (rows)))
                 (loop for k from from below (length rs)
                       do (incf used (sixth (aref rs k)))
                          (when (> used room) (return))
                          (incf n))
                 (max 1 n)))
             (scroll-to-caret ()
               (let ((k (caret-row)))
                 (when (< k top-row) (setf top-row k))
                 (loop while (>= k (+ top-row (visible-count top-row))) do (incf top-row))))
             (redraw ()
               (scroll-to-caret)
               (glass:fb-fill fb paper)
               (let ((rs (rows)) (ck (caret-row)) (y top))
                 (loop for k from top-row below (min (length rs) (+ top-row (visible-count top-row)))
                       do (destructuring-bind (li start text font sz h) (aref rs k)
                            (declare (ignore li start))
                            (glass:fb-text fb margin (+ y (floor (- h (* 1.2 sz)) 2)) text
                                           :size sz :color ink :font font)
                            (when (= k ck)
                              (glass:fb-rect fb (1+ (row-x (aref rs k) cc))
                                             (+ y (floor (- h (* 1.25 sz)) 2)) 2 (round (* 1.25 sz)) caret))
                            (incf y h)))))
             (row-at-y (py)
               ;; the visual row at local y PY, counting from the first shown; past the end, the last
               (let ((rs (rows)) (y top))
                 (loop for k from top-row below (length rs)
                       do (incf y (sixth (aref rs k)))
                          (when (< py y) (return-from row-at-y k)))
                 (1- (length rs))))
             (edit (ks)
               (let* ((line (aref lines cl)) (ch (%kiln-keysym-char ks)))
                 (cond
                   ((= ks #xff08)                                  ; BackSpace
                    (cond ((plusp cc)
                           (setf (aref lines cl) (concatenate 'string (subseq line 0 (1- cc)) (subseq line cc)))
                           (decf cc))
                          ((plusp cl)                              ; join with the line above
                           (let ((prev (aref lines (1- cl))))
                             (setf (aref lines (1- cl)) (concatenate 'string prev line)
                                   lines (concatenate 'vector (subseq lines 0 cl) (subseq lines (1+ cl))))
                             (decf cl) (setf cc (length prev))))))
                   ((= ks #xff51)                                  ; Left
                    (cond ((plusp cc) (decf cc))
                          ((plusp cl) (decf cl) (setf cc (length (aref lines cl))))))
                   ((= ks #xff53)                                  ; Right
                    (cond ((< cc (length line)) (incf cc))
                          ((< cl (1- (length lines))) (incf cl) (setf cc 0))))
                   ((or (= ks #xff52) (= ks #xff54))               ; Up, Down: the row above or below
                    (let* ((k (caret-row)) (x (row-x (aref (rows) k) cc))
                           (k2 (+ k (if (= ks #xff52) -1 1))))
                      (when (< -1 k2 (length (rows))) (place k2 x))))
                   ((eql ch #\Newline)                            ; split the line at the caret
                    (setf lines (concatenate 'vector (subseq lines 0 cl)
                                             (vector (subseq line 0 cc) (subseq line cc))
                                             (subseq lines (1+ cl))))
                    (incf cl) (setf cc 0))
                   (ch
                    (setf (aref lines cl) (concatenate 'string (subseq line 0 cc) (string ch) (subseq line cc)))
                    (incf cc))))
               (changed)))
      (values (lambda (down ks) (when down (edit ks)))
              ;; a press puts the caret where it lands, and a drag carries it along
              (lambda (mask x y)
                (when (logbitp 0 mask) (place (row-at-y y) x)))
              (lambda () (when dirty (setf dirty nil) (redraw) t))))))

(defun %kiln-blit-region (big k x0 y0 x y w h)
  "Show desk rectangle (X,Y,W,H), already magnified by K into BIG, at screen offset (X0,Y0):
   pseudo-syscall 1005 reads the block in place, BIG's row length as its stride."
  (let* ((bw (glass:fb-width big))
         (base (+ (%gc-word-of (glass:fb-pixels big) (%conv-addr #x100050A0)) 7))
         (addr (+ base (* 8 (+ (* y k bw) (* x k))))))
    (%kiln-sys 1005 addr (+ (* w k) (* (* h k) 65536))
               (+ (+ x0 (* x k)) (* (+ y0 (* y k)) 65536)) bw)))

(defun kiln-ios-main (&key autoplay)
  "The app: a glass desk (glass/desk) on the phone's screen -- windows dragged by their title
   bars, a root menu on the background -- with the media player open.  AUTOPLAY, a file name in
   the bundle's media folder, starts playing once the first picture is up (kiln ios
   --autoplay=FILE) -- for trying a build without touching it."
  (let* ((sw (%kiln-sys 1001 0 0 0))
         (sh (%kiln-sys 1001 1 0 0))
         (dir (or (%kiln-bundle-dir) "./"))
         ;; THE SCREEN IS IN DEVICE PIXELS and the desk is laid out in desktop pixels, so glass
         ;; magnifies it, at the screen's own scale (3 on this phone): ONE DESK PIXEL IS ONE
         ;; POINT, and 16-pixel text is iOS's 16-point text.  At 2x it was two-thirds of that
         ;; and read as tiny.  Touches divide by the same K.
         (k (max 1 (%kiln-sys 1001 2 0 0)))
         (y0 (* 60 (%kiln-sys 1001 2 0 0)))          ; below the status bar
         (dw (floor sw k))
         (dh (floor (- sh y0 (* 20 k)) k))
         (x0 (floor (- sw (* dw k)) 2))
         (big (glass:make-framebuffer (* dw k) (* dh k)))
         ;; SOUND: a mixer whose clock is this loop (see %KILN-PUMP-AUDIO), and a
         ;; speaker at its rate.  No speaker, no mixer -- the player then paces the
         ;; picture by the wall clock, as it did before there was sound.
         (speaker (zerop (%kiln-sys 1010 +kiln-rate+ 0 0)))
         (mixer (and speaker (glass:make-mixer :rate +kiln-rate+)))
         (sink (and mixer (glass:mixer-subscribe mixer :name "speaker" :rate +kiln-rate+)))
         (lib (warp-media:make-library :root (concatenate 'string dir "media/") :mixer mixer))
         (desk (glass.desk:make-desk (glass:make-framebuffer dw dh))))
    (format t "~&kiln: ~Dx~D screen, desk ~Dx~D at ~Dx, media from ~A~%" sw sh dw dh k dir)
    (%kiln-sys 1002 0 (+ sw (* sh 65536)) #x1E2530)
    ;; TOUCH-SIZED CHROME: a 34-point title bar to drag by, 44-point menu rows (iOS's
    ;; minimum touch target), 16-point labels
    (setf glass.desk:*title-h* 34 glass.desk:*menu-item-h* 44 glass.desk:*menu-w* 220
          glass.desk:*font-size* 16)
    ;; the media and notes windows take the width of the phone
    (glass.desk:desk-register-app desk "Media"
                                  (lambda (fb) (warp-media-glass:make-media-window fb lib))
                                  :width dw :height 440)
    (glass.desk:desk-register-app desk "Clock" #'%kiln-clock-app :width 260 :height 110)
    (glass.desk:desk-register-app desk "Notes" #'%kiln-notes-app :width dw :height 300)
    ;; THE KEYBOARD: a keys button on each title bar raises that window and shows or hides
    ;; the phone's keyboard (pseudo-syscall 1006); what is typed arrives as key events below
    (let ((up nil))
      (setf (glass.desk:desk-keyboard-fn desk)
            (lambda () (setf up (not up)) (%kiln-sys 1006 (if up 1 0) 0 0))))
    (glass.desk:desk-open desk "Media")
    (format t "~&kiln: ~:[no speaker~;speaker at ~D Hz~]~%" speaker +kiln-rate+)
    (when autoplay
      (let ((path (concatenate 'string dir "media/" autoplay)))
        (if (probe-file path)
            (progn (format t "~&kiln: autoplay ~A~%" autoplay)
                   (warp-media:play-path (warp-media:library-player lib) path))
            (format t "~&kiln: autoplay ~A: no such file~%" autoplay))))
    (format t "~&kiln: ~D track~:P~%"
            (length (warp-media:folder-tracks (concatenate 'string dir "media/"))))
    ;; A tap or a repaint that signals is logged and dropped: one bad gesture
    ;; must not take the app down (an error out of here ends the process).
    (loop
     (handler-case
      (let ((e (%kiln-sys 1004 0 0 0)))
        (if (zerop e)
            (let ((t0 (get-internal-real-time)))
              (when mixer (%kiln-pump-audio mixer sink))
              ;; ONLY WHAT CHANGED is magnified and shown: a video window is a fifth of the
              ;; screen, and the whole of it 2x was most of a frame
              (multiple-value-bind (changed x y w h) (glass.desk:desk-tick desk)
                (when changed
                  (glass:fb-blit-scaled-region big (glass.desk:desk-fb desk) k x y w h)
                  (%kiln-blit-region big k x0 y0 x y w h)
                  (%kiln-sys 1003 0 0 0)))
              ;; a frame is 16 ms; sleep only what is left of it, not 16 ms on top of the work
              (let ((left (- 16 (floor (- (get-internal-real-time) t0) 1000))))
                (when (> left 1) (%sleep-ms left))))
            (let ((type (floor e 1099511627776))
                  (y (logand (floor e 1048576) #xFFFFF))
                  (x (logand e #xFFFFF)))
              (if (= type 4)
                  ;; a key: the keysym is the low 40 bits; a press and its release
                  (let ((ks (logand e #xFFFFFFFFFF)))
                    (glass.desk:desk-key desk t ks)
                    (glass.desk:desk-key desk nil ks))
                  (glass.desk:desk-pointer desk (if (= type 3) 0 1)
                                           (floor (- x x0) k) (floor (- y y0) k))))))
       (error (c) (format t "~&kiln: ~A~%" (%escape-describe c)))))))
