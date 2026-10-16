;;;; zero-bt.lisp — bordeaux-threads on the bare-metal Pi Zero, over modus's SB-THREAD.
;;;;
;;;; warp and warp-media take a lock around the player's state and, with threads, decode on a
;;;; thread of their own.  Locks are SB-THREAD recursive mutexes on every board (on a board without
;;;; threads modus's single-threaded answers make one a flag).  THREADS exist on a board built
;;;; with `kiln zero --threads' (modus net/bare-threads.lisp: threads on cores 1-3): there
;;;; MAKE-THREAD is SB-THREAD:MAKE-THREAD, and the media decoder ("warp-media-decode") is placed
;;;; on core 3.  On a board without them MAKE-THREAD fails loudly -- the player runs in
;;;; WARP-MEDIA:*COOPERATIVE* mode there and never asks.

(defpackage #:bordeaux-threads
  (:nicknames #:bt)
  (:use #:cl)
  (:export #:make-lock #:with-lock-held #:acquire-lock #:release-lock
           #:make-recursive-lock #:with-recursive-lock-held
           #:make-thread #:destroy-thread #:current-thread #:all-threads #:thread-alive-p #:join-thread
           #:make-condition-variable #:condition-wait #:condition-notify))

(in-package #:bordeaux-threads)

;;; A KERNEL function's name is interned only once some loaded source has READ it, so
;;; FIND-SYMBOL answers NIL for one nothing mentions (BT-PIN-NEXT: the decoder's
;;; MAKE-THREAD called NIL).  INTERN finds the image's function either way.
(defun %kernel-fn (name)
  (let ((s (intern name "COMMON-LISP-USER")))
    (and (fboundp s) s)))

(defun %threaded-p ()
  "Whether this board runs threads (modus bare-threads.lisp is in the image)."
  (and (%kernel-fn "BT-START-EXECUTOR") t))

(defun make-lock (&optional name) (sb-thread:make-mutex :name name))
(defun make-recursive-lock (&optional name) (sb-thread:make-mutex :name name))
(defmacro with-lock-held ((lock &rest options) &body body)
  (declare (ignore options))
  `(sb-thread:with-recursive-lock (,lock) ,@body))
(defmacro with-recursive-lock-held ((lock &rest options) &body body)
  (declare (ignore options))
  `(sb-thread:with-recursive-lock (,lock) ,@body))
(defun acquire-lock (lock &optional (wait t)) (sb-thread:grab-mutex lock :waitp wait))
(defun release-lock (lock) (sb-thread:release-mutex lock))

(defun make-thread (fn &key name)
  (unless (%threaded-p)
    (error "bordeaux-threads: this board has one thread; nothing may start another (~a)" name))
  ;; the media decoder gets core 3 to itself: the USB thread has core 1, the screen core 2
  (when (and (stringp name) (search "decode" name))
    (funcall (%kernel-fn "BT-PIN-NEXT") 3))
  (sb-thread:make-thread fn :name name))
(defun destroy-thread (thread)
  (error "bordeaux-threads: modus threads are not destroyed; tell yours to stop (~a)" thread))
(defun current-thread () sb-thread:*current-thread*)
(defun all-threads () (list sb-thread:*current-thread*))   ; the shim keeps no list we may read
(defun thread-alive-p (thread) (sb-thread:thread-alive-p thread))
(defun join-thread (thread) (sb-thread:join-thread thread :default nil))
(defun make-condition-variable (&key name) (sb-thread:make-waitqueue :name name))
(defun condition-wait (cv lock &key timeout) (sb-thread:condition-wait cv lock :timeout timeout))
(defun condition-notify (cv) (sb-thread:condition-notify cv))
