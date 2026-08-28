;;;; ops-test.lisp — boot/ops.lisp, on a bare SBCL with nothing else loaded.
;;;;
;;;; ops.lisp exists so that an AI inside a running image can ask five plain
;;;; questions without rebuilding them from sb-thread internals each session.
;;;; Its whole point is that it works on a bare SBCL — the fast gate runs on
;;;; Debian's, before any of the org's code exists — so that is exactly how it
;;;; is tested here: loaded alone, then poked.
;;;;
;;;; The pothole worth a test of its own: /proc/net/tcp's lines are indented, so
;;;; a naive split shifts every field and PORTS reports nothing, silently.  The
;;;; first version of this file shipped that bug.  A test that reads a real
;;;; /proc table is the only kind that would have caught it.
;;;;
;;;;   sbcl --script t/ops-test.lisp

(require :sb-posix)

(defparameter *here*
  (merge-pathnames "../boot/ops.lisp"
                   (make-pathname :name nil :type nil :defaults *load-truename*)))

(handler-case (load *here*)
  (error (e)
    (format *error-output* "~&ops-test: boot/ops.lisp failed to load: ~a~%" e)
    (sb-ext:exit :code 1)))

(defpackage :kiln-ops-test (:use :cl) (:import-from :kiln-ops #:split-spaces))
(in-package :kiln-ops-test)

(defvar *fails* 0)
(defun ok (name got want)
  (if (equal got want)
      (format t "  ok   ~a~%" name)
      (progn (incf *fails*)
             (format t "  FAIL ~a~%     want [~s] got [~s]~%" name want got))))

;;; ---- split-spaces ------------------------------------------------------------

(ok "split-spaces: runs of spaces, no empties"
    (kiln-ops::split-spaces "  0:  00000000:BB8A  00000000:0000  0A  x  ")
    '("0:" "00000000:BB8A" "00000000:0000" "0A" "x"))

(ok "split-spaces: single spaces"
    (kiln-ops::split-spaces "a b c") '("a" "b" "c"))

(ok "split-spaces: empty string"
    (kiln-ops::split-spaces "") nil)

;;; ---- ports -------------------------------------------------------------------
;;; A real /proc table, captured verbatim: indented lines, a header, one LISTEN
;;; (st 0A) and one ESTABLISHED (st 01) that must NOT be reported.  Fed through
;;; TCP-LISTEN-LINES, which takes a path — the real PORTS hardcodes /proc, which
;;; is read-only, so the test cannot write there.

(defparameter *fake-proc*
  "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:BB8A 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 80032 1 00000000e43f9199 100 0 0 10 0
   1: 0100007F:3039 0100007F:BB8A 01 00000000:00000000 00:00000000 00000000  1001        0 80033 1 00000000e43f9198 100 0 0 10 0
")

(let ((path (format nil "/tmp/kiln-ops-test-tcp-~d" (sb-unix:unix-getpid))))
  (with-open-file (out path :direction :output :if-exists :supersede)
    (write-string *fake-proc* out))
  (unwind-protect
       (let ((s (make-string-output-stream)))
         (dolist (addr (kiln-ops::tcp-listen-lines path))
           (let ((colon (position #\: addr)))
             (format s "~d/listen~%"
                     (parse-integer (subseq addr (1+ colon)) :radix 16))))
         (ok "ports: the listener is found, the connection is not"
             (get-output-stream-string s) "48010/listen
"))
    (delete-file path)))

;;; ---- the surface -------------------------------------------------------------

(ok "help: every op is registered and documented"
    (let ((s (make-string-output-stream)))
      (kiln-ops:help s)
      (let ((text (get-output-stream-string s)))
        (mapcar (lambda (op) (and (search (format nil "~a " op) text) t))
                '(PS MEM PORTS BT PID HELP))))
    '(t t t t t t))

(ok "ps: names every live thread and counts them"
    (let ((s (make-string-output-stream)))
      (kiln-ops:ps s)
      (let ((text (get-output-stream-string s)))
        (list (and (search "main thread" text) t) (and (search "alive" text) t))))
    '(t t))

(ok "mem: reports used and total"
    (let ((s (make-string-output-stream)))
      (kiln-ops:mem s)
      (and (search "MiB" (get-output-stream-string s)) t))
    t)
(ok "pid: a positive integer"
    (let ((s (make-string-output-stream)))
      (kiln-ops:pid s)
      (parse-integer (string-trim '(#\Newline) (get-output-stream-string s))))
    (sb-unix:unix-getpid))

(ok "bt: a thread that exists answers with its own stack"
    (let ((s (make-string-output-stream)))
      (sb-thread:make-thread (lambda () (loop (sleep 60))) :name "ops-test-sleeper")
      (sleep 0.2)
      (kiln-ops:bt "ops-test-sleeper" s 5)
      (let ((text (get-output-stream-string s)))
        ;; The interrupt's own frames are what print; the assertion is that the
        ;; named thread answered at all, not what its stack looks like.
        (list (and (search "ops-test-sleeper" text) t)
              (and (search "PRINT-BACKTRACE" text) t))))
    '(t t))

(ok "bt: a thread that does not exist says so"
    (let ((s (make-string-output-stream)))
      (kiln-ops:bt "no-such-thread" s 1)
      (and (search "no live thread" (get-output-stream-string s)) t))
    t)

(sb-ext:exit :code (if (zerop *fails*) 0 1))
