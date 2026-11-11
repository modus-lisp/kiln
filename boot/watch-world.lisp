;;;; watch-world.lisp — the world a real watch carries: the storybook of its native components, slim.
;;;;
;;;;   KILN_ROOT=… KILN_MODUS=… KILN_VESSEL=… KILN_CORE=out.core  modus --script boot/watch-world.lisp
;;;;
;;;; Run by `kiln ios watch-device' under the macOS build of the SAME modus image the watch app contains (the
;;;; compact, arm64_32-placed layout: modus docs/macos-hosting.md, "On a real watch").  The phone's world
;;;; (ios-world.lisp) is 200 MB of snapshot -- glass, its fonts, the codecs, TLS -- and a watch app gets ~300 MB
;;;; in all.  This one is modus and four files: the term codec, seal's UTF-8 (its package and port.lisp, not
;;;; its crypto), the Swift bridge and the watch storybook.  Compiled to native code here, saved, and restored
;;;; on the watch, as the phone's is.

(defun %kiln-env (name &optional default)
  (let ((v (modus-int::%cli-getenv name)))
    (if (and v (> (length v) 0)) v (or default (error "~A is not set" name)))))

(defvar *kiln-root* (%kiln-env "KILN_ROOT"))
(defvar *kiln-modus* (%kiln-env "KILN_MODUS" (concatenate 'string *kiln-root* "/modus")))
(defvar *kiln-vessel* (%kiln-env "KILN_VESSEL" (concatenate 'string *kiln-root* "/vessel/src")))

;; THE WIRE FORMAT (modus net/term.lisp), with a read cursor of ours, as ios-world.lisp has it.
(defvar *term-cursor* (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
(defun decode-ptr-addr ()
  (+ (modus-int::%gc-word-of *term-cursor* (modus-int::%conv-addr #x100050A0)) 7))
(load (concatenate 'string *kiln-modus* "/net/term.lisp"))

;; seal's UTF-8, which the bridge's text goes through: its packages and port.lisp, plain CL, alone.
(load (concatenate 'string *kiln-root* "/seal/src/packages.lisp"))
(load (concatenate 'string *kiln-root* "/seal/src/port.lisp"))

(load (concatenate 'string *kiln-vessel* "/watch.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-swift.lisp"))
(load (concatenate 'string *kiln-vessel* "/watch-storybook.lisp"))

(let ((r (modus-int::%jit-eager-all)))
  (format t "~&kiln: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
          (first r) (second r) (third r)))

(let ((core (modus-int::%cli-getenv "KILN_CORE")))
  (format t "~&kiln: saving ~A~%" core)
  (save-and-die core))
