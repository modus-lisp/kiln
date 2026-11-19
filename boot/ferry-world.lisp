;;;; ferry-world.lisp — the world of ferry, the SFTP client (the ferry repo): `kiln ios sim|device --app=ferry'.
;;;;
;;;;   KILN_ROOT=… KILN_QL=… KILN_VESSEL=… KILN_MODUS=… KILN_CORE=out.core  modus --script boot/ferry-world.lisp
;;;;
;;;; ios-world.lisp's shape with none of the desk: no glass, no media.  The app is native UIKit
;;;; (modus's host/ios/swift/Native.swift) driven from Lisp through vessel's ios-swift.lisp and
;;;; ios-native.lisp; its SSH is conch, its keys and passwords are in the keychain (vessel's
;;;; ios-ssh.lisp).  Compiled to native code here, saved with SAVE-AND-DIE; the app's modus.args say
;;;;   --core @kiln.core --eval (ferry:main)

(defvar *kiln-root* (let ((r (modus-int::%cli-getenv "KILN_ROOT")))
                      (if (and r (> (length r) 0)) r (error "KILN_ROOT is not set"))))
(defvar *kiln-ql* (modus-int::%cli-getenv "KILN_QL"))
(defvar *kiln-vessel* (let ((v (modus-int::%cli-getenv "KILN_VESSEL")))
                        (if (and v (> (length v) 0)) v (concatenate 'string *kiln-root* "/vessel/src"))))
(defvar *kiln-modus* (let ((m (modus-int::%cli-getenv "KILN_MODUS")))
                       (if (and m (> (length m) 0)) m (concatenate 'string *kiln-root* "/modus"))))

(dolist (repo '("natrium" "seal" "conch" "ferry"))
  (push (concatenate 'string *kiln-root* "/" repo "/") asdf:*central-registry*))
(when (and *kiln-ql* (> (length *kiln-ql*) 0))
  (dolist (d (directory (concatenate 'string *kiln-ql* "/*/")))
    (push d asdf:*central-registry*)))

(format t "~&kiln: ferry/core~%")
(asdf:load-system "ferry/core")

;; What vessel's iOS files take from the desk's world (vessel's ios.lisp and app.lisp), without the desk:
;; the pseudo-syscall, and the frame hooks ON-EVENT registers its pump in (ferry's loop pumps itself).
(defun %kiln-sys (n a b c &optional (d 0) (e 8))
  (declare (ignore e))
  (modus-int::%gc-safe-block-6 n a b c d))
(defvar *kiln-frame-hooks* nil)

;; THE WIRE FORMAT (modus net/term.lisp), with the read cursor the event decoder needs (see ios-world.lisp)
(defvar *term-cursor* (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
(defun decode-ptr-addr ()
  (+ (modus-int::%gc-word-of *term-cursor* (modus-int::%conv-addr #x100050A0)) 7))
(load (concatenate 'string *kiln-modus* "/net/term.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-ssh.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-swift.lisp"))
(load (concatenate 'string *kiln-vessel* "/ios-native.lisp"))

(format t "~&kiln: ferry~%")
(asdf:load-system "ferry")

(let ((r (modus-int::%jit-eager-all)))
  (format t "~&kiln: compiled ~D functions in ~D modules, ~D left to the interpreter~%"
          (first r) (second r) (third r)))

(let ((core (modus-int::%cli-getenv "KILN_CORE")))
  (format t "~&kiln: saving ~A~%" core)
  (save-and-die core))
