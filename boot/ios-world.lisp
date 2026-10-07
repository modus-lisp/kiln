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
    "warp" "warp-glass" "reel" "reed" "cassette" "glass/audio" "warp-media" "warp-media/glass" "glass/desk"))

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

;; THE DECODERS' TABLES, NOW, for the same kind of reason.  reed builds its transform plans,
;; codebooks and windows on first use and keeps them in globals.  On the phone first use is
;; the player's decoding thread, and modus refuses a thread's store of its own object into a
;; global (the shared-store guard): every file with sound failed to open.  Built here they
;; are the snapshot's.  Every size a Vorbis block may be (64..8192); AAC's tables are fixed;
;; Opus by decoding a file, which visits the sizes CELT uses.
(defun %kiln-warm (what thunk)
  (handler-case (progn (funcall thunk) (format t "~&kiln ios: warmed ~A~%" what))
    (serious-condition (e) (format t "~&kiln ios: could not warm ~A: ~A~%" what e))))
(%kiln-warm "vorbis transforms"
            (lambda () (loop for n = 64 then (* n 2) while (<= n 8192) do (reed::imdct-plan n))))
(%kiln-warm "aac tables"
            (lambda ()
              (reed::aac-imdct-long-matrix) (reed::aac-imdct-short-matrix)
              (reed::aac-sf-decoder) (reed::aac-spec-decoder 0)
              (reed::aac-pow43 0) (reed::aac-ensure-windows)))
(dolist (f '("wpt-test.webm" "t5-av.webm" "opus-ogg.ogg"))
  (let ((path (concatenate 'string *kiln-root* "/cassette/vectors/" f)))
    (when (probe-file path)
      (%kiln-warm f (lambda ()
                      (let ((wp (cassette:open-media path :audio t)))
                        (loop (unless (cassette:next-audio-frame wp) (return)))))))))

;; One more pass for anything the per-system passes left: modus's JIT-EAGER runs to a
;; fixpoint, retrying a failed module once its callees have gone native.
(let ((r (%jit-eager-all)))
  (format t "~&kiln ios: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
          (first r) (second r) (third r)))

(let ((core (%cli-getenv "KILN_CORE")))
  (format t "~&kiln ios: saving ~A~%" core)
  (save-and-die core))
