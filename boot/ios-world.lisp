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

;; The media player: warp's window over cassette (containers) and reel/reed (video and audio decoders);
;; glass's audio mixes it.  SSH in the Terminal: conch, with its crypto (natrium) and host-key sibling (seal).
(dolist (repo '("glass" "cram" "warp" "warp/glass" "warp/media" "gesso" "scribe" "brotli-pure"
                "cassette" "reed" "reel" "cl-transport" "natrium" "seal" "conch"))
  (push (concatenate 'string *kiln-root* "/" repo "/") asdf:*central-registry*))
(when (and *kiln-ql* (> (length *kiln-ql*) 0))
  (dolist (d (directory (concatenate 'string *kiln-ql* "/*/")))
    (push d asdf:*central-registry*)))

;; seal/http is loaded here, not at the phone's Terminal: the phone has no source tree to load from.
(defvar *kiln-systems*
  '("glass/fb" "bordeaux-threads" "cram" "scribe" "gesso" "glass" "glass/text"
    "warp" "warp-glass" "reel" "reed" "cassette" "glass/audio" "warp-media" "warp-media/glass"
    "glass/desk" "glass/voice-apps" "conch" "seal/http"))

(dolist (s *kiln-systems*)
  (format t "~&kiln: ~A~%" s)
  (asdf:load-system s))
;; The app (vessel's src/app.lisp) and the platform's way to the screen: KILN_APP is
;; "ios" (the default) or "android".  Both are vessel's -- kiln only assembles.  KILN_VESSEL
;; names vessel's src/ (bin/kiln passes it); otherwise the vessel checkout beside kiln.
(defvar *kiln-app* (let ((a (modus-int::%cli-getenv "KILN_APP"))) (if (and a (> (length a) 0)) a "ios")))
(defvar *kiln-vessel* (let ((v (modus-int::%cli-getenv "KILN_VESSEL")))
                        (if (and v (> (length v) 0)) v (concatenate 'string *kiln-root* "/vessel/src"))))
;; THE WIRE FORMAT (modus net/term.lisp): the bridge's data and events are terms, the same bytes the
;; actor messages use.  KILN_MODUS is the modus checkout (bin/kiln passes it).  The codec needs a read cursor
;; from its caller: a cell of ours (the events decode from theirs, see vessel's ios-swift.lisp).
(defvar *kiln-modus* (let ((m (modus-int::%cli-getenv "KILN_MODUS")))
                       (if (and m (> (length m) 0)) m (concatenate 'string *kiln-root* "/modus"))))
(defvar *term-cursor* (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
(defun decode-ptr-addr ()
  (+ (modus-int::%gc-word-of *term-cursor* (modus-int::%conv-addr #x100050A0)) 7))
(load (concatenate 'string *kiln-modus* "/net/term.lisp"))
(load (concatenate 'string *kiln-vessel* "/" *kiln-app* ".lisp"))
(load (concatenate 'string *kiln-vessel* "/app.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-ssh.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-objc.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-swift.lisp"))
(load (concatenate 'string *kiln-vessel* "/gpu.lisp"))
(load (concatenate 'string *kiln-vessel* "/speech.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-storybook.lisp"))
(load (concatenate 'string *kiln-vessel* "/watch-storybook.lisp"))
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

;; Opus, and the containers' first-use tables, by decoding a few files' audio through (their sizes are CELT's)
(dolist (f '("wpt-test.webm" "t5-av.webm" "opus-ogg.ogg"))
  (let ((path (concatenate 'string *kiln-root* "/cassette/vectors/" f)))
    (when (probe-file path)
      (%kiln-warm f (lambda ()
                      (let ((wp (cassette:open-media path :audio t)))
                        (loop (unless (cassette:next-audio-frame wp) (return)))))))))

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
