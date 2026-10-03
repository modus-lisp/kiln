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

(defun kiln-ios-main ()
  (let* ((sw (%kiln-sys 1001 0 0 0))
         (sh (%kiln-sys 1001 1 0 0))
         (dir (or (%kiln-bundle-dir) "./"))
         ;; THE SCREEN IS IN DEVICE PIXELS (3 per point on this phone) and the
         ;; window is laid out in desktop pixels, so glass magnifies it --
         ;; FB-BLIT-SCALED at the largest whole factor that fits the width,
         ;; which keeps glyph edges exact.  Touches divide by the same K.
         (fw warp-media-glass:+width+)
         (k (max 1 (floor sw fw)))
         (y0 (* 60 (%kiln-sys 1001 2 0 0)))          ; below the status bar
         (fh (min 640 (floor (- sh y0 (* 20 k)) k)))
         (x0 (floor (- sw (* fw k)) 2))
         (big (glass:make-framebuffer (* fw k) (* fh k)))
         ;; SOUND: a mixer whose clock is this loop (see %KILN-PUMP-AUDIO), and a
         ;; speaker at its rate.  No speaker, no mixer -- the player then paces the
         ;; picture by the wall clock, as it did before there was sound.
         (speaker (zerop (%kiln-sys 1010 +kiln-rate+ 0 0)))
         (mixer (and speaker (glass:make-mixer :rate +kiln-rate+)))
         (sink (and mixer (glass:mixer-subscribe mixer :name "speaker" :rate +kiln-rate+)))
         (lib (warp-media:make-library :root (concatenate 'string dir "media/") :mixer mixer))
         (fb (glass:make-framebuffer fw fh)))
    (format t "~&kiln: ~Dx~D screen, media from ~A~%" sw sh dir)
    (%kiln-sys 1002 0 (+ sw (* sh 65536)) #x1E2530)
    (multiple-value-bind (on-key on-pointer dirty-p) (warp-media-glass:make-media-window fb lib)
      (declare (ignore on-key))
      (funcall dirty-p)
      (progn (glass:fb-blit-scaled big fb 0 0 k) (%kiln-blit big x0 y0))
      (%kiln-sys 1003 0 0 0)
      ;; NOT PLAYING ON OPEN: a tap on a track starts it.
      (format t "~&kiln: ~:[no speaker~;speaker at ~D Hz~]~%" speaker +kiln-rate+)
      (format t "~&kiln: ~D track~:P~%"
              (length (warp-media:folder-tracks (concatenate 'string dir "media/"))))
      ;; A tap or a repaint that signals is logged and dropped: one bad gesture
      ;; must not take the app down (an error out of here ends the process).
      (loop
       (handler-case
        (let ((e (%kiln-sys 1004 0 0 0)))
          (if (zerop e)
              (progn
                (when mixer (%kiln-pump-audio mixer sink))
                (when (funcall dirty-p)
                  (progn (glass:fb-blit-scaled big fb 0 0 k) (%kiln-blit big x0 y0))
                  (%kiln-sys 1003 0 0 0))
                (%sleep-ms 16))
              (let ((type (floor e 1099511627776))
                    (y (logand (floor e 1048576) #xFFFFF))
                    (x (logand e #xFFFFF)))
                (funcall on-pointer (if (= type 3) 0 1)
                         (floor (- x x0) k) (floor (- y y0) k)))))
         (error (c) (format t "~&kiln: ~A~%" (%escape-describe c))))))))
