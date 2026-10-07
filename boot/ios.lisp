;;;; ios.lisp — the iPhone app's entry point: glass on the phone's own screen.
;;;; The app itself is boot/app.lisp; this is iOS's way to the screen.
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

(defun kiln-ios-main (&key autoplay)
  "The iPhone app (boot/app.lisp), below the status bar."
  (kiln-app-main :autoplay autoplay :top 60))
