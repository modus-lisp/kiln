;;;; ios-world.lisp — the world an iPhone app carries, built ON THE MAC.
;;;;
;;;;   KILN_ROOT=… KILN_QL=… KILN_CORE=out.core  modus --script boot/ios-world.lisp
;;;;
;;;; Run by `kiln ios' under the macOS build of the SAME modus image the app
;;;; will contain.  Loads the systems below from source, compiles every one of
;;;; them to native code (the JIT, which the phone does not have), and saves
;;;; the process with SAVE-AND-DIE.  The app then restores that snapshot at
;;;; launch: its compiled code rides in the app as signed, read-only pages and
;;;; the heap is relocated to wherever iOS put the app (modus's
;;;; lib/save-image.lisp, RELOCATION).
;;;;
;;;; NO THREADS ARE STARTED HERE.  A snapshot carries no threads; the player's
;;;; mixer and decoders start on the phone, after the restore.

(defvar *kiln-root* (let ((r (%cli-getenv "KILN_ROOT")))
                      (if (and r (> (length r) 0)) r (error "KILN_ROOT is not set"))))
(defvar *kiln-ql* (%cli-getenv "KILN_QL"))

(dolist (repo '("glass" "cram" "warp" "warp/glass" "warp/media" "gesso" "scribe" "brotli-pure"
                "cassette" "reed" "reel" "cl-transport"))
  (push (concatenate 'string *kiln-root* "/" repo "/") asdf:*central-registry*))
(when (and *kiln-ql* (> (length *kiln-ql*) 0))
  (dolist (d (directory (concatenate 'string *kiln-ql* "/*/")))
    (push d asdf:*central-registry*)))

(defvar *kiln-systems*
  '("glass/fb" "bordeaux-threads" "cram" "scribe" "gesso" "glass" "glass/text"
    "warp" "warp-glass" "reel" "reed" "cassette" "glass/audio" "warp-media" "warp-media/glass"))

(dolist (s *kiln-systems*)
  (format t "~&kiln ios: ~A~%" s)
  (asdf:load-system s))
(load (concatenate 'string *kiln-root* "/kiln/boot/ios.lisp"))

;; THE FONTS, NOW.  glass and scribe open their faces lazily, by path into the
;; source tree -- which exists on this Mac and not on the phone.  Opened here,
;; they are heap objects the snapshot carries.
(glass::default-font)
(glass::default-font t)
(dolist (f scribe::*face-files*)
  (scribe::%open-face (first f)))

;; TO A FIXPOINT.  The JIT compiles a function only once everything it calls is native, and
;; a module that failed is not retried -- so a definition that came before its callee, or a
;; callee REDEFINED later (reel's NEON loop-filter kernels replace the scalar ones), left its
;; callers interpreted for good: the whole VP8 loop filter, every pixel of every frame.  So
;; forget the failures and go again until a pass leaves no fewer modules interpreted.  (Not
;; "until nothing compiles": a module the native check does not recognise -- one of reel's
;; recompiles every pass -- would loop for ever, filling the JIT arena.)
(let ((left nil))
  (loop
    (setq *jit-eager-failed* nil)
    (let ((r (%jit-eager-all)))
      (format t "~&kiln ios: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
              (first r) (second r) (third r))
      (when (and left (>= (third r) left)) (return))
      (setq left (third r)))))

(let ((core (%cli-getenv "KILN_CORE")))
  (format t "~&kiln ios: saving ~A~%" core)
  (save-and-die core))
