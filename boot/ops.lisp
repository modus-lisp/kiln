;;;; ops.lisp — the image, described to whoever is inside it.
;;;;
;;;; An AI (or a person) reaching into a running kiln has the whole heap in front
;;;; of it, and every session so far has rebuilt the same five questions from
;;;; sb-thread and sb-kernel internals: what is running, how much memory, which
;;;; ports, what is this thread stuck in.  The primitives are one call each; the
;;;; potholes are not.  /proc/net/tcp's lines begin with spaces, so a naive split
;;;; shifts every field and reports nothing, silently.  This file is those five
;;;; answers, written once, named plainly, and documented in one place.
;;;;
;;;; It is deliberately dependency-free: no quicklisp, no cl-ppcre, nothing that
;;;; is not in a bare `sbcl --script'.  The fast tests load it on Debian's SBCL
;;;; before any of the org's code exists, and the image loads it before the
;;;; desktop does, so `kiln eval' can answer even when the desktop is not up.
;;;;
;;;; Nothing here mutates the image.  These are read-only eyes; the eval socket
;;;; is already the hand.

(defpackage :kiln-ops
  (:use :cl)
  (:export #:help #:ps #:mem #:ports #:bt #:pid))

(in-package :kiln-ops)

(defvar *ops* nil)

(defmacro defop (name args doc &body body)
  "Define an op and register it, so HELP is always truthful and never a list
   somebody forgot to update."
  `(progn (defun ,name ,args ,doc ,@body)
          (pushnew ',name *ops*)
          ',name))

(defun thread-name-or (thread)
  (or (sb-thread:thread-name thread) "(unnamed)"))

;;; ---- ps ----------------------------------------------------------------------

(defop ps (&optional (stream *standard-output*))
    "One line per thread; x marks the dead."
  (let ((threads (sort (copy-list (sb-thread:list-all-threads))
                       #'string< :key (lambda (th) (string (thread-name-or th)))))
        (alive 0))
    (dolist (th threads)
      (when (sb-thread:thread-alive-p th) (incf alive))
      (format stream "~[ ~;x~] ~a~%" (if (sb-thread:thread-alive-p th) 0 1)
              (thread-name-or th)))
    (format stream "~d threads, ~d alive~%" (length threads) alive)))

;;; ---- mem ---------------------------------------------------------------------

(defop mem (&optional (stream *standard-output*))
    "Dynamic space: used / total, and bytes consed since the image started."
  (format stream "~d / ~d MiB, ~,1f GiB consed since start~%"
          (floor (sb-kernel:dynamic-usage) 1048576)
          (floor (sb-ext:dynamic-space-size) 1048576)
          (/ (sb-ext:get-bytes-consed) 1.0e9)))

;;; ---- ports -------------------------------------------------------------------
;;; sb-bsd-sockets grew LIST-ALL-SOCKETS only recently, and the fast tests run on
;;; Debian's SBCL, which does not have it.  /proc/net/tcp is older than both and
;;; cannot lie: it is the kernel's own table, not ours.

(defun tcp-listen-lines (path)
  "The st==0A (TCP_LISTEN) lines of one /proc table, or NIL if there is none."
  (with-open-file (in path :if-does-not-exist nil)
    (when in
      (read-line in)                      ; the header
      (loop for line = (read-line in nil nil)
            while line
            ;; The lines are indented, so a plain split yields a leading "" and
            ;; every field index shifts by one.  Trim first; this is the bug that
            ;; made the first version of PORTS report nothing, silently.
            for fields = (split-spaces (string-left-trim " " line))
            when (string= (nth 3 fields) "0A")
            collect (nth 1 fields)))))

(defun split-spaces (line)
  "Split on runs of spaces.  Written by hand because the fast tests must run on
   a bare SBCL with nothing loaded but the standard."
  (loop for start = (position-if (lambda (c) (char/= c #\Space)) line)
        while start
        for end = (position #\Space line :start start)
        collect (subseq line start end)
        do (setf line (if end (subseq line end) ""))))

(defop ports (&optional (stream *standard-output*))
    "Listening TCP ports, read from the kernel's own tables."
  (dolist (addr (append (tcp-listen-lines "/proc/net/tcp")
                        (tcp-listen-lines "/proc/net/tcp6")))
    (let ((colon (position #\: addr)))
      (when colon
        (format stream "~d/listen~%"
                (parse-integer (subseq addr (1+ colon)) :radix 16))))))

;;; ---- bt ----------------------------------------------------------------------
;;; A thread that is wedged is the question behind every other question.  The
;;; interrupt must carry a timeout: INTERRUPT-THREAD on a thread that is itself
;;; stopped, or deep in a without-interrupts, would otherwise hang the caller
;;; forever, and an inspector that hangs is worse than one that is absent.

(defop bt (thread-name &optional (stream *standard-output*) (seconds 2))
    "The stack of the named thread, printed by that thread itself.  Waits at most
   SECONDS seconds; a thread that cannot be interrupted says so and moves on."
  (let* ((threads (remove-if-not
                   (lambda (th)
                     (and (sb-thread:thread-alive-p th)
                          (equal (thread-name-or th) thread-name)))
                   (sb-thread:list-all-threads)))
         (sem (sb-thread:make-semaphore)))
    (cond ((null threads)
           (format stream "no live thread named ~s~%" thread-name))
          (t
           (dolist (th threads)
             (sb-thread:interrupt-thread
              th (lambda ()
                   (unwind-protect
                        (print-backtrace stream)
                     (sb-thread:signal-semaphore sem))))
             (format stream "~&;; ~a~%" thread-name))
           ;; One wait per thread, with a deadline.  A thread that never answers
           ;; leaves the semaphore un-signalled; the timeout is the answer.
           (loop repeat (length threads)
                 do (sb-thread:wait-on-semaphore sem :timeout seconds))))))

(defun print-backtrace (stream)
  "Frame names only, newest first, capped.  A backtrace is for recognizing WHERE
   a thread is, not for reading its arguments over someone's shoulder."
  (let ((n 0))
    (loop for frame = (sb-di:top-frame) then (sb-di:frame-up frame)
          while frame
          do (incf n)
             (when (> n 40) (format stream "  ...~%") (return))
             (format stream "  ~2d: ~a~%" n
                     (ignore-errors
                       (sb-di:debug-fun-name (sb-di:frame-debug-fun frame)))))))

;;; ---- pid ---------------------------------------------------------------------

(defop pid (&optional (stream *standard-output*))
    "This image's OS process id."
  (format stream "~d~%" (sb-unix:unix-getpid)))

;;; ---- help --------------------------------------------------------------------

(defop help (&optional (stream *standard-output*))
    "List the ops an AI (or human) can call."
  (dolist (op (nreverse *ops*))
    (format stream "~a~10t~a~%" op (or (documentation op 'function) ""))))
