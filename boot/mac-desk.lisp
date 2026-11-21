;;;; mac-desk.lisp — the desk in a native macOS window, LOADED FROM SOURCE at startup.
;;;;
;;;;   KILN_ROOT=… KILN_QL=… modus-gui-app < commands
;;;;   (load "/…/kiln/boot/mac-desk.lisp")
;;;;
;;;; The first step toward a snapshot (save-and-die): the glass desk and vessel's app, from source, in the
;;;; native image.  No media player and no SSH, which the phone's world has and this first cut does not need.
;;;; The platform is vessel's ios.lisp: its pseudo-syscalls 1001-1012 are the same contract the Mac window
;;;; answers (host/macos/modus-ui-mac.m), so the desk runs unchanged.

(defvar *kiln-root* (let ((r (modus-int::%cli-getenv "KILN_ROOT")))
                      (if (and r (> (length r) 0)) r (error "KILN_ROOT is not set"))))
(defvar *kiln-ql* (modus-int::%cli-getenv "KILN_QL"))

;; Quicklisp's first, the workspace's repos after it (quicklisp has other libraries under some of our names).
(when (and *kiln-ql* (> (length *kiln-ql*) 0))
  (dolist (d (directory (concatenate 'string *kiln-ql* "/*/")))
    (push d asdf:*central-registry*)))
(dolist (repo '("glass" "cram" "gesso" "scribe" "brotli-pure" "pigment" "stencil" "png-pure" "webp-pure"
                "quill" "warren" "json-simple"
                ;; glass depends on cl-transport (its listeners), and glass/audio on reed; both take seal and natrium
                "cl-transport" "reed" "seal" "natrium"))
  (push (concatenate 'string *kiln-root* "/" repo "/") asdf:*central-registry*))

(defvar *desk-systems*
  '("glass/fb" "bordeaux-threads" "cram" "scribe" "gesso" "glass" "glass/text"
    "glass/desk" "glass/wm-core" "glass/mixer-desk" "glass/audio"
    ;; seal: its UTF-8 encoder is how ios-swift.lisp hands text to the native components
    "seal"))

(dolist (s *desk-systems*)
  (format t "~&kiln: ~A~%" s)
  (asdf:load-system s))

;; vessel: the platform (the same pseudo-syscalls on Mac as on the phone), then the app itself
(defvar *kiln-vessel* (concatenate 'string *kiln-root* "/vessel/src"))
(load (concatenate 'string *kiln-vessel* "/ios.lisp"))
;; ios.lisp makes the desk a RACK, the phone's layout, where a tap on empty space does nothing (the root
;; menu is a long press there).  A Mac has a pointer and floating windows: a tap on the desktop opens the
;; root menu, as on the desk everywhere else.  Set after ios.lisp, before app.lisp reads it.
(setq *kiln-desk-layout* :float)
(load (concatenate 'string *kiln-vessel* "/app.lisp"))

;; THE NATIVE BRIDGES, as the phone's world has them (boot/ios-world.lisp): the wire format (modus net/term.lisp),
;; the Objective-C runtime (ios-objc.lisp, pseudo-syscall 1040), Lisp-calls-Swift (ios-swift.lisp, 1060: on the
;; Mac its functions are modus's host/macos/swift/, the same names), and the storybook over them.
(defvar *kiln-modus* (let ((m (modus-int::%cli-getenv "KILN_MODUS")))
                       (if (and m (> (length m) 0)) m (concatenate 'string *kiln-root* "/modus"))))
(defvar *term-cursor* (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
(defun decode-ptr-addr ()
  (+ (modus-int::%gc-word-of *term-cursor* (modus-int::%conv-addr #x100050A0)) 7))
(load (concatenate 'string *kiln-modus* "/net/term.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-objc.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-swift.lisp"))
;; the Mac's own: the window's title, chrome and size (modus's host/macos/swift/MacWindow.swift)
(load (concatenate 'string *kiln-vessel* "/mac-window.lisp"))
;; the storybook's GPU and speech stories name these packages (their Swift halves are not on the Mac yet)
(load (concatenate 'string *kiln-vessel* "/gpu.lisp"))
(load (concatenate 'string *kiln-vessel* "/speech.lisp"))
;; the camera (modus's host/ios/swift/Camera.swift): the storybook's camera story names its package
(load (concatenate 'string *kiln-vessel* "/camera.lisp"))
;; the microphone's samples (modus's host/ios/swift/Microphone.swift), for the storybook's microphone story
(load (concatenate 'string *kiln-vessel* "/microphone.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-storybook.lisp"))

(defun kiln-mac-main ()
  "The desk in the window.  A restored snapshot calls this (see below); a source load calls it at once."
  (format t "~&kiln: the desk~%")
  ;; THE WINDOW, as the person asked for it at launch: KILN_MAC_TITLE, and KILN_MAC_CHROME (standard, hidden-title,
  ;; transparent or none).  Before the desk lays itself out, so it starts clear of a transparent bar.
  (let ((title (modus-int::%cli-getenv "KILN_MAC_TITLE"))
        (chrome (modus-int::%cli-getenv "KILN_MAC_CHROME")))
    (when (and chrome (> (length chrome) 0))
      (kiln-mac:window-chrome (intern (string-upcase chrome) :keyword)))
    (when (and title (> (length title) 0)) (kiln-mac:window-title title)))
  ;; KILN_STORYBOOK=1 opens the native components' storybook over the desk at start, as on the phone;
  ;; KILN_STORYBOOK=NAME opens it at the story NAME (mic, camera, ...)
  (let ((story (modus-int::%cli-getenv "KILN_STORYBOOK")))
    (when story
      (funcall (find-symbol "STORYBOOK" "KILN-STORYBOOK") (if (string= story "1") nil story))))
  (kiln-app-main :top 0 :media nil))

;; KILN_CORE=PATH: compile the loaded world to native code and SAVE it, rather than run the desk: a later
;; run starts from the snapshot (modus --core PATH, then (kiln-mac-main)).  The same steps as kiln ios's
;; boot/ios-world.lisp.  Without KILN_CORE the desk starts now.
(let ((core (modus-int::%cli-getenv "KILN_CORE")))
  (if (and core (> (length core) 0))
      (let ((r (modus-int::%jit-eager-all)))
        (format t "~&kiln: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
                (first r) (second r) (third r))
        (format t "~&kiln: saving ~A~%" core)
        (save-and-die core))
      (kiln-mac-main)))
