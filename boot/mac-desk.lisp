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
    "glass/desk" "glass/wm-core" "glass/mixer-desk" "glass/audio"))

(dolist (s *desk-systems*)
  (format t "~&kiln: ~A~%" s)
  (asdf:load-system s))

;; vessel: the platform (the same pseudo-syscalls on Mac as on the phone), then the app itself
(defvar *kiln-vessel* (concatenate 'string *kiln-root* "/vessel/src"))
(load (concatenate 'string *kiln-vessel* "/ios.lisp"))
(load (concatenate 'string *kiln-vessel* "/app.lisp"))

(defun kiln-mac-main ()
  "The desk in the window.  A restored snapshot calls this (see below); a source load calls it at once."
  (format t "~&kiln: the desk~%")
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
