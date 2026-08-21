;;;; build.lisp — load the desktop's whole world and dump it as an SBCL core.
;;;;
;;;; The expensive part of starting a glass desktop is compiling McCLIM and the
;;;; modus-lisp systems under it.  Doing that once at image-build time and
;;;; saving the result means `kiln run` starts in about a second instead of a
;;;; minute.
;;;;
;;;; Deliberately NOT baked in: the desktop's own startup logic.  The core holds
;;;; only *loaded systems*; the entry point stays glass's own
;;;; backend/inspect/serve-desktop.lisp, whose quickload calls then find
;;;; everything already present and return immediately.  glass stays the single
;;;; source of truth for what a desktop is, and kiln does not fork it.
;;;;
;;;;   sbcl --dynamic-space-size 4096 --script boot/build.lisp

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defvar *core* (or (sb-ext:posix-getenv "KILN_CORE") "/opt/kiln/modus.core"))

;; Hunchentoot pulls cl+ssl -- OpenSSL through a CFFI binding -- unless told not
;; to, and it is the only thing that puts a C library in this image.  The gateway
;; serves plain HTTP on the container's loopback and lets WebRTC do the
;; encrypting, so its TLS half is dead weight here.  Set before anything loads it.
(push :hunchentoot-no-ssl *features*)

(defun note (fmt &rest args)
  (format *error-output* "~&kiln/build: ~?~%" fmt args)
  (finish-output *error-output*))

;;; Systems the desktop cannot start without.  A failure here must fail the
;;; build — an image that boots to a backtrace is worse than one that never got
;;; built.
(defparameter *required*
  '(;; third-party, from Quicklisp
    :mcclim :mcclim-render :clim-examples :clim-listener :chipz
    ;; the display stack itself
    :sb-concurrency :glass :glass/vncauth :glass/text :glass/term :pigment
    ;; the browser path: noVNC over a WebRTC data channel, served by hunchentoot
    :webrtc-data :hunchentoot
    ;; the control plane: conch's SSH server, and what the config TUI needs to
    ;; resolve a NIP-05 (seal/http + jzon).  These are in the CORE because
    ;; sshd.lisp runs from it -- `sbcl --script' implies --no-userinit, so a
    ;; plain script cannot see Quicklisp and cannot find jzon at all.
    :conch :seal/http :com.inuoe.jzon))

;;; Systems the desktop is explicitly written to run without — serve-desktop.lisp
;;; wraps each in ignore-errors and adapts (a silent desktop is a working
;;; desktop).  We try them, report honestly, and carry on.
(defparameter *optional*
  '((:glass/audio-stream . "session audio")
    (:glass/speech       . "voice (chord; needs GLASS_VOICE at runtime)")
    (:glass/hearing      . "ear (stave; needs GLASS_EARS at runtime)")
    (:glass/dictation    . "dictation (speech -> keystrokes)")
    (:loom/glass         . "web browser")
    (:warren             . "file browser")))

(defvar *missing* '())

(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))

    (note "loading required systems (~d)" (length *required*))
    (dolist (sys *required*)
      (ql:quickload sys))

    ;; mcclim-glass.asd lives under glass/backend/ and is found by the tree scan
    ;; in the source-registry config, so no load-asd dance is needed here.
    (note "loading the McCLIM backend")
    (asdf:load-system :mcclim-glass)

    (note "loading optional systems (~d)" (length *optional*))
    (loop for (sys . what) in *optional*
          do (handler-case (asdf:load-system sys)
               (error (e)
                 (push (list sys what (princ-to-string e)) *missing*))))
    ;; The type-and-say window registers itself; absent without :glass/speech.
    (ignore-errors (asdf:load-system :mcclim-glass/speak))))

(note "required systems loaded")
(if *missing*
    (dolist (m (reverse *missing*))
      (note "optional NOT built: ~a (~a)" (first m) (second m)))
    (note "every optional system built too"))

;;; save-lisp-and-die refuses to run with other threads alive, and a stray
;;; loader thread would turn a good build into a confusing failure.
(let ((others (remove sb-thread:*current-thread* (sb-thread:list-all-threads))))
  (when others
    (note "joining ~d stray thread(s) before dump" (length others))
    (dolist (t* others)
      (ignore-errors (sb-thread:terminate-thread t*))
      (ignore-errors (sb-thread:join-thread t* :default nil)))))

(ensure-directories-exist *core*)
(note "dumping core -> ~a" *core*)
(sb-ext:save-lisp-and-die *core* :compression nil)
