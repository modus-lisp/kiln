;;;; zero-bt.lisp — bordeaux-threads for a machine with ONE thread: the bare-metal Pi Zero.
;;;;
;;;; warp and warp-media take a lock around the player's state and, with threads, decode on a
;;;; thread of their own.  On the Zero there is one thread, so a lock has nothing to exclude and
;;;; is free; the player runs in WARP-MEDIA:*COOPERATIVE* mode and never asks for a thread, so
;;;; MAKE-THREAD failing loudly is how a path that does would be found, not a hang.

(defpackage #:bordeaux-threads
  (:nicknames #:bt)
  (:use #:cl)
  (:export #:make-lock #:with-lock-held #:acquire-lock #:release-lock
           #:make-recursive-lock #:with-recursive-lock-held
           #:make-thread #:current-thread #:all-threads #:thread-alive-p #:join-thread
           #:make-condition-variable #:condition-wait #:condition-notify))

(in-package #:bordeaux-threads)

(defun make-lock (&optional name) (list :lock name))
(defun make-recursive-lock (&optional name) (list :lock name))
(defmacro with-lock-held ((lock &rest options) &body body)
  (declare (ignore options))
  `(progn ,lock ,@body))
(defmacro with-recursive-lock-held ((lock &rest options) &body body)
  (declare (ignore options))
  `(progn ,lock ,@body))
(defun acquire-lock (lock &optional (wait t)) (declare (ignore lock wait)) t)
(defun release-lock (lock) (declare (ignore lock)) nil)
(defun make-thread (fn &key name)
  (declare (ignore fn))
  (error "bordeaux-threads: this board has one thread; nothing may start another (~a)" name))
(defun current-thread () :main)
(defun all-threads () (list :main))
(defun thread-alive-p (thread) (eq thread :main))
(defun join-thread (thread) (declare (ignore thread)) nil)
(defun make-condition-variable (&key name) (list :condition-variable name))
(defun condition-wait (cv lock &key timeout) (declare (ignore cv lock timeout)) nil)
(defun condition-notify (cv) (declare (ignore cv)) nil)
