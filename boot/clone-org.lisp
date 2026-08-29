;;;; clone-org.lisp — check the whole modus-lisp org out of GitHub, using the
;;;; org's own git implementation.
;;;;
;;;; cairn is git in pure Common Lisp: the object model, the pack format, the
;;;; smart-HTTP transfer protocol, all of it — cloning over HTTPS on seal's TLS,
;;;; which is itself pure Common Lisp on natrium's crypto.  There is no libgit2
;;;; here, no libcurl, no OpenSSL, and no `git` binary in the image at all.  A
;;;; clone travels cairn -> seal -> natrium and never leaves Lisp.
;;;;
;;;; seed.sh has already put cairn and its four dependencies in KILN_SEED as
;;;; tarballs, because cairn cannot clone itself into existence.  From here on
;;;; every repo — including a fresh, real checkout of cairn itself — is cloned
;;;; by the code below, pinned to the commit named in repos.lock.
;;;;
;;;;   sbcl --script boot/clone-org.lisp
;;;;
;;;; Env: MODUS_ORG (modus-lisp), MODUS_ROOT (/opt/modus-lisp),
;;;;      KILN_SEED (/opt/kiln-seed), KILN_LOCK (/kiln/repos.lock), KILN_JOBS (4)

(require :asdf)
(require :sb-posix)

(defun env (name default)
  (or (sb-ext:posix-getenv name) default))

(defvar *org*  (env "MODUS_ORG"  "modus-lisp"))
(defvar *root* (env "MODUS_ROOT" "/opt/modus-lisp"))
(defvar *seed* (env "KILN_SEED"  "/opt/kiln-seed"))
(defvar *lock* (env "KILN_LOCK"  "/kiln/repos.lock"))
(defvar *jobs* (max 1 (or (ignore-errors (parse-integer (env "KILN_JOBS" "4"))) 4)))

;;; Load cairn out of the seed tree — the only time anything is read from there.
(asdf:initialize-source-registry
 `(:source-registry (:tree ,(pathname (concatenate 'string *seed* "/")))
                    :inherit-configuration))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :cairn)))

;;; ---------------------------------------------------------------- the lock

(defun parse-lock (path)
  "Return a list of (name branch commit) from repos.lock, ignoring #comments."
  (with-open-file (in path)
    (loop for line = (read-line in nil)
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
          unless (or (zerop (length trimmed)) (char= (char trimmed 0) #\#))
            collect (let ((words '()) (start nil))
                      (dotimes (i (1+ (length trimmed)))
                        (let ((sep (or (= i (length trimmed))
                                       (member (char trimmed i) '(#\Space #\Tab)))))
                          (cond ((and sep start) (push (subseq trimmed start i) words)
                                                 (setf start nil))
                                ((not (or sep start)) (setf start i)))))
                      (nreverse words)))))

;;; --------------------------------------------------------------- reporting

(defvar *say-lock* (sb-thread:make-mutex :name "kiln-report"))

(defun say (fmt &rest args)
  (sb-thread:with-mutex (*say-lock*)
    (apply #'format *error-output* fmt args)
    (finish-output *error-output*)))

(defun short-sha (sha) (subseq sha 0 (min 8 (length sha))))

;;; ----------------------------------------------------------------- cloning

(defun repo-at-commit-p (dir commit)
  "True when DIR is already a checkout sitting on COMMIT — makes this idempotent."
  (and (probe-file (merge-pathnames ".git/" (pathname (concatenate 'string dir "/"))))
       (ignore-errors
        (string= commit (cairn:head-commit (cairn:open-repository dir))))))

(defun clone-one (name branch commit)
  (let ((dir (concatenate 'string *root* "/" name))
        (url (format nil "https://github.com/~a/~a" *org* name)))
    (when (repo-at-commit-p dir commit)
      (say "  = ~a already at ~a~%" name (short-sha commit))
      (return-from clone-one t))
    ;; A partial directory from a failed attempt would make cairn refuse; clear it.
    (ignore-errors
     (uiop:delete-directory-tree (pathname (concatenate 'string dir "/"))
                                 :validate t :if-does-not-exist :ignore))
    ;; cairn's clone chatters to *standard-output*; keep the log to one line each.
    (let ((repo (let ((*standard-output* (make-broadcast-stream)))
                  (cairn:clone url dir))))
      ;; clone checks out the remote's HEAD.  Pin it to the locked commit — a
      ;; no-op in the common case where the lock IS the current head.
      (let ((head (cairn:head-commit repo)))
        (if (string= head commit)
            (say "  + ~a ~a (~a)~%" name (short-sha commit) branch)
            (progn (cairn:checkout repo commit)
                   ;; ...AND MAKE THE METADATA SAY SO.  CHECKOUT moves the working tree and
                   ;; leaves the branch ref where it was, so a pinned repo had the right
                   ;; FILES and a .git that named a different commit — `git rev-parse HEAD'
                   ;; answered with the tip, and `git status' showed every change since the
                   ;; pin as a local deletion.  The files were never wrong; the repository
                   ;; was lying about which commit they were.
                   ;;
                   ;; The branch ref rather than a detached HEAD, because the lock names a
                   ;; branch as well as a commit: this workspace IS on that branch, at that
                   ;; commit, and a later `git pull' should mean what it looks like it means.
                   (%write-branch-ref dir branch commit)
                   (say "  + ~a ~a (~a, pinned back from ~a)~%"
                        name (short-sha commit) branch (short-sha head)))))
      t)))

(defun %write-branch-ref (dir branch commit)
  "Point DIR's BRANCH at COMMIT, so git agrees with the files cairn just checked out.

   Written directly because that is what a ref IS — forty hex digits and a newline in
   .git/refs/heads/<branch>.  Loose refs win over packed ones, so this is also the whole of
   what has to change."
  (let ((path (format nil "~a/.git/refs/heads/~a" dir branch)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (format out "~a~%" commit))))

(defun clone-with-retry (name branch commit)
  "One retry: a TLS handshake or a socket can lose a race under parallelism."
  (handler-case (clone-one name branch commit)
    (error (e)
      (say "  ! ~a failed (~a) — retrying~%" name (type-of e))
      (handler-case (clone-one name branch commit)
        (error (e2) (say "  ✗ ~a FAILED: ~a~%" name e2) nil)))))

;;; -------------------------------------------------------------------- main

(let* ((repos (parse-lock *lock*))
       (queue (copy-list repos))
       (qlock (sb-thread:make-mutex :name "kiln-queue"))
       (failed '())
       (flock (sb-thread:make-mutex :name "kiln-failed")))
  (ensure-directories-exist (pathname (concatenate 'string *root* "/")))
  (say "~&kiln: cloning ~d repos from ~a with cairn (~d jobs)~%~
        kiln: cairn -> seal (TLS) -> natrium (crypto); no git, no libcurl, no FFI~%~%"
       (length repos) *org* *jobs*)
  (let ((workers
          (loop repeat (min *jobs* (length repos))
                collect (sb-thread:make-thread
                         (lambda ()
                           (loop
                             (let ((job (sb-thread:with-mutex (qlock) (pop queue))))
                               (unless job (return))
                               (destructuring-bind (name branch commit) job
                                 (unless (clone-with-retry name branch commit)
                                   (sb-thread:with-mutex (flock) (push name failed)))))))
                         :name "kiln-clone"))))
    (mapc #'sb-thread:join-thread workers))
  (terpri *error-output*)
  (if failed
      (progn (say "kiln: ~d repo(s) failed: ~{~a~^ ~}~%" (length failed) (nreverse failed))
             (sb-ext:quit :unix-status 1))
      (say "kiln: ~d repos checked out into ~a — every one of them by cairn~%"
           (length repos) *root*)))
