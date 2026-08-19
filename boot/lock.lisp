;;;; lock.lisp — refresh repos.lock against the org's current remote HEADs.
;;;;
;;;; Uses cairn's ref discovery, which is one HTTPS GET of info/refs per repo —
;;;; no clone, no packfile, no GitHub API and so no token and no rate limit.
;;;; The new lock goes to stdout; bin/kiln redirects it over the file.
;;;;
;;;;   sbcl --script boot/lock.lisp  > repos.lock
;;;;
;;;; The repo LIST comes from the existing lock, not from the org listing: this
;;;; deliberately refreshes what kiln already knows about rather than silently
;;;; adopting whatever appeared in the org overnight.  To add a repo, add a line
;;;; with any commit and re-run this — the branch is what's looked up.

(require :asdf)

(defun env (name default) (or (sb-ext:posix-getenv name) default))
(defvar *org*  (env "MODUS_ORG"  "modus-lisp"))
(defvar *root* (env "MODUS_ROOT" "/opt/modus-lisp"))
(defvar *lock* (env "KILN_LOCK"  "/kiln/repos.lock"))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,(pathname (concatenate 'string *root* "/")))
                    (:exclude "vendor" "deps") :inherit-configuration))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :cairn)))

(defun split-words (line)
  (let ((words '()) (start nil))
    (dotimes (i (1+ (length line)) (nreverse words))
      (let ((sep (or (= i (length line)) (member (char line i) '(#\Space #\Tab)))))
        (cond ((and sep start) (push (subseq line start i) words) (setf start nil))
              ((not (or sep start)) (setf start i)))))))

(defun read-lock (path)
  (with-open-file (in path)
    (loop for line = (read-line in nil) while line
          for tr = (string-trim '(#\Space #\Tab #\Return) line)
          unless (or (zerop (length tr)) (char= (char tr 0) #\#))
            collect (split-words tr))))

(defun remote-head (name branch)
  "Current sha for BRANCH at the org's NAME, plus the branch HEAD actually points
   at.  Returns (values sha default-branch)."
  (multiple-value-bind (refs caps head-target)
      (cairn:discover-refs (format nil "https://github.com/~a/~a.git" *org* name))
    (declare (ignore caps))
    (let* ((want (concatenate 'string "refs/heads/" branch))
           (hit  (assoc want refs :test #'string=))
           (deflt (and head-target
                       (let ((p (search "refs/heads/" head-target)))
                         (if p (subseq head-target (+ p (length "refs/heads/"))) head-target)))))
      (values (and hit (cdr hit)) deflt))))

(let* ((entries (read-lock *lock*))
       (rows '()))
  (format *error-output* "~&kiln/lock: reading ~d remote ref sets via cairn~%" (length entries))
  (dolist (e entries)
    (destructuring-bind (name branch &optional old) e
      (handler-case
          (multiple-value-bind (sha deflt) (remote-head name branch)
            (cond
              ((null sha)
               (format *error-output* "  ! ~a: no refs/heads/~a~@[ (default is ~a)~]~%"
                       name branch (and deflt (string/= deflt branch) deflt))
               (push (list name branch (or old "")) rows))
              (t
               (when (and deflt (string/= deflt branch))
                 (format *error-output* "  ~~ ~a: lock tracks ~a but HEAD is ~a~%" name branch deflt))
               (format *error-output* "  ~a ~a~@[ (was ~a)~]~%" name (subseq sha 0 8)
                       (and old (string/= old sha) (subseq old 0 8)))
               (push (list name branch sha) rows))))
        (error (e)
          (format *error-output* "  ✗ ~a: ~a — keeping old pin~%" name e)
          (push (list name branch (or old "")) rows)))))
  (setf rows (nreverse rows))
  (let ((w (reduce #'max rows :key (lambda (r) (length (first r)))))
        (b (reduce #'max rows :key (lambda (r) (length (second r))))))
    (format t "# repos.lock — every modus-lisp repo pinned to an exact commit.~%#~%~
               # Regenerate with:  bin/kiln lock~%~
               # Format: <repo>  <branch>  <commit>~%~%")
    (dolist (r rows)
      (format t "~va  ~va  ~a~%" w (first r) b (second r) (third r)))))
