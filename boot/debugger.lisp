;;;; debugger.lisp — a thread that dies should not take the desktop with it.
;;;;
;;;; WHAT THIS REPLACES.  The image runs --disable-debugger, which sets SBCL's
;;;; *INVOKE-DEBUGGER-HOOK* to a function that prints a backtrace and QUITS.  For a
;;;; non-interactive build that is right: nothing is going to answer a debugger prompt on a
;;;; detached process, and hanging is worse than dying.  But it applies to EVERY thread, and
;;;; a desktop is a dozen of them.  Measured, on this machine: an app's decode worker called
;;;; a generic function with no applicable method -- one missing DEFMETHOD, in a file being
;;;; edited live -- and the whole session went down, taking the terminal, the chat, the voice
;;;; and two days of uptime with it.  The failure was in a leaf; the blast radius was
;;;; everything.
;;;;
;;;; WHAT IT DOES INSTEAD.  A worker thread that dies gets the CLIM debugger, on the desktop
;;;; that is already running, and the rest of the image carries on.  That is the live-coding
;;;; answer: the frame with the missing method is sitting right there, and typing the
;;;; DEFMETHOD and restarting the thread beats reading a backtrace out of a log.
;;;;
;;;; THREE THINGS ARE DELIBERATE, and each was learned by getting it wrong first.
;;;;
;;;;   THE MAIN THREAD KEEPS THE OLD BEHAVIOUR.  A main thread parked inside a GUI debugger
;;;;   is a desktop with no way to tell you it is stuck -- it just stops, silently, which is
;;;;   strictly worse than a loud exit.  Main dies the way it always did.
;;;;
;;;;   *INVOKE-DEBUGGER-HOOK*, NOT CLIM-DEBUGGER:INSTALL-DEBUGGER.  That function sets the
;;;;   ANSI *DEBUGGER-HOOK*, and --disable-debugger's hook runs first and quits, so
;;;;   installing the CLIM debugger the documented way does nothing at all here.
;;;;
;;;;   THE PORT HAS TO BE NAMED.  CLIM-DEBUGGER calls FIND-PORT, and with no
;;;;   *DEFAULT-SERVER-PATH* McCLIM reaches for CLX and fails with "Environment variable
;;;;   DISPLAY is not set".  There is no X here.  The one live port is glass's, already
;;;;   carrying the desktop, so the debugger is pointed at that.
;;;;
;;;; And if any of it fails -- no port yet, a debugger that will not open -- the reason is
;;;; logged and ONLY the dead thread is killed.  Falling back to the old hook would quit the
;;;; image, which is the thing being fixed.

(in-package :cl-user)

(defvar *kiln-hard-hook* nil
  "SBCL's own --disable-debugger hook, kept so the main thread can still use it.")

(defvar *kiln-in-debugger* nil
  "Bound per-thread while the CLIM debugger is up, so an error raised INSIDE the
   debugger does not recurse into another one.")

(defun %kiln-clim-debugger (condition hook)
  "Open the CLIM debugger on the running glass desktop.  Signals if it cannot."
  (let* ((ports (symbol-value (find-symbol "*ALL-PORTS*" "CLIM-INTERNALS")))
         (port (first ports)))
    (unless port (error "no CLIM port is open yet"))
    (let ((path (funcall (find-symbol "PORT-SERVER-PATH" "CLIM-INTERNALS") port))
          (fm   (first (funcall (find-symbol "FRAME-MANAGERS" "CLIM-INTERNALS") port))))
      (progv (list (find-symbol "*DEFAULT-SERVER-PATH*" "CLIM")
                   (find-symbol "*DEFAULT-FRAME-MANAGER*" "CLIM"))
             (list path fm)
        (funcall (find-symbol "DEBUGGER" "CLIM-DEBUGGER") condition hook)))))

(defun kiln-install-debugger ()
  "Point worker-thread errors at the CLIM debugger instead of at process exit.
   Idempotent, and a no-op in an image with no CLIM-DEBUGGER — the surface is
   optional and a core built without it should still boot."
  (unless (find-package "CLIM-DEBUGGER")
    (return-from kiln-install-debugger nil))
  (unless *kiln-hard-hook*
    (setf *kiln-hard-hook* sb-ext:*invoke-debugger-hook*))
  (setf sb-ext:*invoke-debugger-hook*
        (lambda (condition hook)
          (cond
            ((or *kiln-in-debugger*
                 (sb-thread:main-thread-p sb-thread:*current-thread*))
             (funcall *kiln-hard-hook* condition hook))
            (t
             (let ((*kiln-in-debugger* t))
               (format *error-output* "~&kiln: thread ~A died: ~A~%"
                       (sb-thread:thread-name sb-thread:*current-thread*) condition)
               (finish-output *error-output*)
               (handler-case (%kiln-clim-debugger condition hook)
                 (serious-condition (e)
                   (format *error-output* "~&kiln: no debugger for it (~A) — thread dropped~%" e)
                   (finish-output *error-output*)))
               ;; Returning here would fall through to SBCL's own handler and quit, which is
               ;; exactly what this file exists to avoid.  The worker is finished either way;
               ;; the desktop is not.
               (sb-thread:abort-thread))))))
  t)
