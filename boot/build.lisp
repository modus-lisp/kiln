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

;; In the image, ASDF is configured by /etc/common-lisp/source-registry.conf.d.
;; Running on a host there is no such file, so KILN_SOURCE_TREE says "scan this
;; tree instead" -- with the same exclusions, which are not optional: without them
;; scribe's deps/cram and modus's vendor/chipz turn up as duplicate systems.
(let ((tree (sb-ext:posix-getenv "KILN_SOURCE_TREE")))
  (when tree
    (asdf:initialize-source-registry
     `(:source-registry (:tree ,(pathname (concatenate 'string tree "/")))
                        (:exclude "vendor" "deps") :inherit-configuration))))

;; Quicklisp lives in two places, for a reason.  On a host it is the user's, at
;; ~/quicklisp.  In the image it is /opt/quicklisp -- system-wide, because the
;; image runs as an unprivileged user who does not own /root and should not need
;; to.  KILN_QUICKLISP overrides both.
(let ((setup (find-if #'probe-file
                      (remove nil
                              (list (let ((e (sb-ext:posix-getenv "KILN_QUICKLISP")))
                                      (and e (merge-pathnames "setup.lisp" (concatenate 'string e "/"))))
                                    #p"/opt/quicklisp/setup.lisp"
                                    (merge-pathnames "quicklisp/setup.lisp"
                                                     (user-homedir-pathname)))))))
  (unless setup
    (format *error-output* "~&kiln/build: no Quicklisp found (tried KILN_QUICKLISP, ~
                            /opt/quicklisp, ~~/quicklisp).~%~
                            kiln/build: the desktop needs McCLIM, which comes from there.~%")
    (sb-ext:quit :unix-status 1))
  (load setup))

;; QUICKLISP'S OWN HTTP CLIENT STALLS IN THE BUILD GUEST, and it stalls in the way
;; that is hardest to read: it resolves the host, gets a response, prints the
;; archive's size -- and then the transfer never finishes.  The build sits on one
;; fetch that takes half a second from the host, with no error and no timeout, so it
;; looks like a slow compile rather than a dead socket.
;;
;; curl is already how this image fetches quicklisp.lisp itself, so use it for the
;; archives too.  Both schemes, because the default dist serves plain http and it is
;; the http one that hangs.  Looked up by name: ql-http does not exist until the line
;; above ran.
(let ((var (find-symbol "*FETCH-SCHEME-FUNCTIONS*" :ql-http))
      (fetch (lambda (url file &rest ignored)
               (declare (ignore ignored))
               (let ((out (merge-pathnames file)))
                 (uiop:run-program (list "curl" "-fsSL" "--retry" "3" "--retry-all-errors"
                                         "-o" (namestring out) url))
                 (values out out)))))
  (when (and var (boundp var))
    (dolist (scheme '("http" "https"))
      (push (cons scheme fetch) (symbol-value var)))))

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
    ;; ...and the SAME path from away, over nostr signalling.  These are in the CORE
    ;; and not optional, because the alternative is what shipped: a box whose config
    ;; says KILN_NOSTR=y, which starts, announces the gateway, and then cannot load
    ;; it -- the rootfs is read-only, so a system that is not in the core cannot be
    ;; compiled at boot, and the failure surfaces as "Can't create directory"
    ;; naming a fasl cache rather than the system that is actually missing.
    ;; glass/nostr earns its place twice over: the DESKTOP answers admission with
    ;; it now, so without it the screen comes up and refuses every offer.
    :webrtc-media/rtc :glass/mic-stream :glass/nostr :cl-nostr
    ;; The outbound gate.  In the CORE rather than optional for the same reason as
    ;; the nostr systems above: a policy is applied at boot, and a box whose config
    ;; names one cannot compile the system that reads it -- the rootfs is read-only.
    ;; It costs almost nothing (usocket, which is here already) and arms nothing on
    ;; its own; see cl-transport/docs/GATE.md.
    :cl-transport
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
      (:glass/mic          . "microphone (in-image; the socket is glass/mic-stream)")
    (:glass/speech       . "voice (chord; needs GLASS_VOICE at runtime)")
    (:glass/hearing      . "ear (stave; needs GLASS_EARS at runtime)")
    (:glass/dictation    . "dictation (speech -> keystrokes)")
    (:loom/glass         . "web browser")
    (:warren             . "file browser")
      (:spool/app          . "podcasts (spool)")))

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
    ;; The two model-backed WINDOWS.  These are separate systems from :glass/speech and
    ;; :glass/hearing, which are the engines — loading the ear does not load the app that
    ;; puts a Listen window on the menu, and the menu entry silently vanishes when its
    ;; package is absent.  That is exactly how Listen went missing after Speak was added
    ;; here and its sibling was not.
    (dolist (sys '(:mcclim-glass/speak :mcclim-glass/listen :mcclim-glass/mixer
               :mcclim-glass/music))
      (handler-case (asdf:load-system sys)
        (error (e) (push (list sys "menu window" (princ-to-string e)) *missing*))))))

(note "required systems loaded")
(if *missing*
    (dolist (m (reverse *missing*))
      (note "optional NOT built: ~a (~a)" (first m) (second m)))
    (note "every optional system built too"))

;;; ---- housekeeping, in the CORE so every path gets it ------------------------------
;;; SBCL promotes a surviving object one generation per GC (NUMBER-OF-GCS-BEFORE-PROMOTION
;;; is 1 the whole way up), so anything outliving a few collections reaches the oldest
;;; generation — which nothing collects except a FULL gc.  Garbage that gets there stays
;;; for the life of the process.  Measured on a container session: 372 MB live at ten
;;; minutes, 131 after one (GC :FULL T), climbing near 100 MB a minute under a client until
;;; the kernel killed it at 36 minutes (anon-rss 4077128 kB, status 137).
;;;
;;; This lived in one.lisp first, which fixed the container and nothing else: `kiln local'
;;; generates its own boot file and never loads one.lisp, so the welded desktop — the one
;;; with no container limit and therefore the longest uptime — still had the leak.  A core
;;; init hook is the one place BOTH paths pass through, along with `repl' and `modus'.
;;;
;;; Threads do not survive a dump, so this registers the intent and the hook makes the
;;; thread at startup.  Quiet unless it reclaimed enough to have been worth the pause, so
;;; the log carries the trend rather than the heartbeat.
(push (lambda ()
        (let ((secs (or (ignore-errors
                          (parse-integer (or (sb-ext:posix-getenv "KILN_GC_SECONDS") "300")))
                        300)))
          (when (plusp secs)
            (sb-thread:make-thread
             (lambda ()
               (loop
                 (sleep secs)
                 (handler-case
                     (let ((before (sb-kernel:dynamic-usage)))
                       (sb-ext:gc :full t)
                       (let ((freed (- before (sb-kernel:dynamic-usage))))
                         (when (> freed (* 64 1024 1024))
                           (format *error-output* "~&[gc] full — reclaimed ~a MB, ~a MB live~%"
                                   (round freed 1048576)
                                   (round (sb-kernel:dynamic-usage) 1048576))
                           (finish-output *error-output*))))
                   ;; Housekeeping must never be the thing that takes the desktop down.
                   (error () nil))))
             :name "kiln-gc"))))
      sb-ext:*init-hooks*)

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
