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
         ;; THE SCREEN IS IN DEVICE PIXELS (3 per point on this phone) and the desk is laid
         ;; out in desktop pixels, so glass magnifies it -- FB-BLIT-SCALED at the largest
         ;; whole factor that keeps the media window's width on screen, which keeps glyph
         ;; edges exact.  Touches divide by the same K.
         (k (max 1 (floor sw warp-media-glass:+width+)))
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
    (glass.desk:desk-register-app desk "Media"
                                  (lambda (fb) (warp-media-glass:make-media-window fb lib))
                                  :width warp-media-glass:+width+ :height 560)
    (glass.desk:desk-register-app desk "Clock" #'%kiln-clock-app :width 260 :height 110)
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
              (glass.desk:desk-pointer desk (if (= type 3) 0 1)
                                       (floor (- x x0) k) (floor (- y y0) k)))))
       (error (c) (format t "~&kiln: ~A~%" (%escape-describe c)))))))
