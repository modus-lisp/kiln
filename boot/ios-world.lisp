;;;; ios-world.lisp — the world a phone app carries: built ON THE MAC for an
;;;; iPhone, ON AN aarch64 LINUX HOST for Android (KILN_APP=android).
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

(defvar *kiln-root* (let ((r (modus-int::%cli-getenv "KILN_ROOT")))
                      (if (and r (> (length r) 0)) r (error "KILN_ROOT is not set"))))
(defvar *kiln-ql* (modus-int::%cli-getenv "KILN_QL"))

;; No media in this world (warp, cassette and reel are left out): the desk, Clock and
;; Terminal first.  reed stays -- glass's audio mixes with it.
;; SSH in the Terminal: conch, with its crypto (natrium) and host-key sibling (seal).
(dolist (repo '("glass" "cram" "gesso" "scribe" "brotli-pure" "reed" "cl-transport"
                "natrium" "seal" "conch"))
  (push (concatenate 'string *kiln-root* "/" repo "/") asdf:*central-registry*))
(when (and *kiln-ql* (> (length *kiln-ql*) 0))
  (dolist (d (directory (concatenate 'string *kiln-ql* "/*/")))
    (push d asdf:*central-registry*)))

;; seal/http is loaded here, not at the phone's Terminal: the phone has no source tree to load from.
(defvar *kiln-systems*
  '("glass/fb" "bordeaux-threads" "cram" "scribe" "gesso" "glass" "glass/text"
    "reed" "glass/audio" "glass/desk" "conch" "seal/http"))

(dolist (s *kiln-systems*)
  (format t "~&kiln: ~A~%" s)
  (asdf:load-system s))
;; The app (vessel's src/app.lisp) and the platform's way to the screen: KILN_APP is
;; "ios" (the default) or "android".  Both are vessel's -- kiln only assembles.  KILN_VESSEL
;; names vessel's src/ (bin/kiln passes it); otherwise the vessel checkout beside kiln.
(defvar *kiln-app* (let ((a (modus-int::%cli-getenv "KILN_APP"))) (if (and a (> (length a) 0)) a "ios")))
(defvar *kiln-vessel* (let ((v (modus-int::%cli-getenv "KILN_VESSEL")))
                        (if (and v (> (length v) 0)) v (concatenate 'string *kiln-root* "/vessel/src"))))
(load (concatenate 'string *kiln-vessel* "/" *kiln-app* ".lisp"))
(load (concatenate 'string *kiln-vessel* "/app.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-ssh.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-objc.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-swift.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-storybook.lisp"))
(load (concatenate 'string *kiln-vessel* "/actions.lisp"))

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
  (handler-case (progn (funcall thunk) (format t "~&kiln: warmed ~A~%" what))
    (serious-condition (e) (format t "~&kiln: could not warm ~A: ~A~%" what e))))
(%kiln-warm "vorbis transforms"
            (lambda () (loop for n = 64 then (* n 2) while (<= n 8192) do (reed::imdct-plan n))))
(%kiln-warm "aac tables"
            (lambda ()
              (reed::aac-imdct-long-matrix) (reed::aac-imdct-short-matrix)
              (reed::aac-sf-decoder) (reed::aac-spec-decoder 0)
              (reed::aac-pow43 0) (reed::aac-ensure-windows)))

;; THE TLS TRUST STORE, now.  The phone has no CA bundle file (seal's :system reads
;; /etc/ssl/cert.pem and its kin), so the Mac's bundle is parsed here and the parsed store is
;; the snapshot's: https verifies against it with no file on the phone.
(%kiln-warm "tls trust store"
            (lambda ()
              (setf seal.http:*trust-store*
                    (seal::make-trust-store-from-pem (seal::read-file-string "/etc/ssl/cert.pem")))))

;; One more pass for anything the per-system passes left: modus's JIT-EAGER runs to a
;; fixpoint, retrying a failed module once its callees have gone native.
(let ((r (modus-int::%jit-eager-all)))
  (format t "~&kiln: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
          (first r) (second r) (third r)))

(let ((core (modus-int::%cli-getenv "KILN_CORE")))
  (format t "~&kiln: saving ~A~%" core)
  (save-and-die core))
