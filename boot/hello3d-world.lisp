;;;; hello3d-world.lisp — hello, world in 3D (vessel's hello3d.lisp), its own Mac app:
;;;;
;;;;   kiln mac build --app=hello3d --entry='(hello3d:main)' --name="Hello 3D"
;;;;   kiln mac run --app=hello3d
;;;;   kiln ios sim --app=hello3d --install         (the phone: entry (hello3d:main :touch t), two thumbs)
;;;;
;;;; No desk: the native bridges (the wire format, the Objective-C and Swift bridges), the window's own calls, the
;;;; GPU, and the game.  Saved as a snapshot when KILN_CORE is set, as boot/mac-desk.lisp is.

(defvar *kiln-root* (let ((r (modus-int::%cli-getenv "KILN_ROOT")))
                      (if (and r (> (length r) 0)) r (error "KILN_ROOT is not set"))))
(defvar *kiln-ql* (modus-int::%cli-getenv "KILN_QL"))

(when (and *kiln-ql* (> (length *kiln-ql*) 0))
  (dolist (d (directory (concatenate 'string *kiln-ql* "/*/")))
    (push d asdf:*central-registry*)))
;; seal: its UTF-8 encoder is how ios-swift.lisp hands text to the native components (with natrium beneath it)
(dolist (repo '("seal" "natrium" "cl-transport"))
  (push (concatenate 'string *kiln-root* "/" repo "/") asdf:*central-registry*))
(asdf:load-system "seal")

;; the platform's calls, as vessel's ios.lisp makes them (the Mac window answers the same pseudo-syscalls), and
;; the frame hooks ios-swift.lisp hangs its event pump on (the desk's app.lisp defines them; there is no desk here)
(defun %kiln-sys (n a b c &optional (d 0) (e 8))
  (declare (ignore e))
  (modus-int::%gc-safe-block-6 n a b c d))
(defvar *kiln-frame-hooks* nil)

(defvar *kiln-vessel* (let ((v (modus-int::%cli-getenv "KILN_VESSEL")))      ; kiln ios passes it
                        (if (and v (> (length v) 0)) v (concatenate 'string *kiln-root* "/vessel/src"))))
(defvar *kiln-modus* (let ((m (modus-int::%cli-getenv "KILN_MODUS")))
                       (if (and m (> (length m) 0)) m (concatenate 'string *kiln-root* "/modus"))))
(defvar *term-cursor* (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
(defun decode-ptr-addr ()
  (+ (modus-int::%gc-word-of *term-cursor* (modus-int::%conv-addr #x100050A0)) 7))
(load (concatenate 'string *kiln-modus* "/net/term.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-objc.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-swift.lisp"))
(load (concatenate 'string *kiln-vessel* "/mac-window.lisp"))
(load (concatenate 'string *kiln-vessel* "/gpu.lisp"))
(load (concatenate 'string *kiln-vessel* "/gamepad.lisp"))
(load (concatenate 'string *kiln-vessel* "/sound.lisp"))
(load (concatenate 'string *kiln-vessel* "/hello3d.lisp"))

;; KILN_CORE=PATH: compile the world and save it; a run restores it and evaluates the entry, (hello3d:main)
(let ((core (modus-int::%cli-getenv "KILN_CORE")))
  (if (and core (> (length core) 0))
      (let ((r (modus-int::%jit-eager-all)))
        (format t "~&kiln: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
                (first r) (second r) (third r))
        (format t "~&kiln: saving ~A~%" core)
        (save-and-die core))
      (hello3d:main)))
