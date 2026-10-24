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
;;;;      KILN_SEED (/opt/kiln-seed), KILN_LOCK (/kiln/repos.lock), KILN_JOBS (4),
;;;;      KILN_EXTRA_CA (unset: a PEM file of CAs to trust in addition to the system
;;;;      bundle -- see INSTALL-TRUST), HTTPS_PROXY / https_proxy (unset: an
;;;;      http://host:port proxy that tunnels with CONNECT -- see INSTALL-PROXY)

(require :asdf)
(require :sb-posix)

(defun env (name default)
  (or (sb-ext:posix-getenv name) default))

(defvar *org*  (env "MODUS_ORG"  "modus-lisp"))
(defvar *root* (env "MODUS_ROOT" "/opt/modus-lisp"))
(defvar *seed* (env "KILN_SEED"  "/opt/kiln-seed"))
(defvar *lock* (env "KILN_LOCK"  "/kiln/repos.lock"))
(defvar *jobs* (max 1 (or (ignore-errors (parse-integer (env "KILN_JOBS" "4"))) 4)))
(defvar *extra-ca* (let ((p (env "KILN_EXTRA_CA" nil))) (and p (plusp (length p)) p)))

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

;;; -------------------------------------------------------------------- trust

;;; A network that intercepts TLS presents its own CA, which the system bundle does
;;; not hold.  KILN_EXTRA_CA names a PEM file of CAs to trust IN ADDITION, and it is
;;; applied here and nowhere else: seal's *trust-store* is set for this process
;;; before any thread starts, so only the build's own fetches trust it.  The system
;;; bundle is not touched, and the runtime is a different process that never sees
;;; this setting.  Each extra certificate is logged by fingerprint, so the build's
;;; output says exactly which CA it trusted.
;;;
;;; Trusting an interceptor is safe for this step and only this step: every clone is
;;; checked out at a commit named in repos.lock, and git names content by hash, so
;;; an interceptor can observe the bytes but cannot change them.

(defun hex (bytes)
  (format nil "~{~(~2,'0x~)~}" (coerce bytes 'list)))

(defun system-ca-bundle ()
  "The public roots, wherever this system keeps them: Debian's path in the image,
/etc/ssl/cert.pem on a Mac."
  (or (find-if #'probe-file '("/etc/ssl/certs/ca-certificates.crt" "/etc/ssl/cert.pem"
                              "/etc/pki/tls/certs/ca-bundle.crt"))
      (error "kiln: no system CA bundle found")))

(defun install-trust ()
  (if (null *extra-ca*)
      (say "kiln: trust: system roots only~%")
      (let ((extra (progn
                     (unless (probe-file *extra-ca*)
                       (error "KILN_EXTRA_CA=~a does not exist" *extra-ca*))
                     (uiop:read-file-string *extra-ca*)))
            (system (uiop:read-file-string (system-ca-bundle))))
        (let ((ders (seal:pem-certificates extra)))
          (unless ders (error "KILN_EXTRA_CA=~a holds no certificates" *extra-ca*))
          (dolist (der ders)
            (say "@@ trust extra-ca ~a~%" (hex (seal:sha256 der)))))
        ;; One store: the system roots and the extra ones.  Parsed here, once, and
        ;; handed to seal as an object, so nothing reads the extra file again.
        (setf seal.http:*trust-store*
              (seal:make-trust-store-from-pem
               (concatenate 'string system (string #\Newline) extra))))))

;;; -------------------------------------------------------------------- proxy

;;; A network that allows no direct connection out names an HTTP proxy that tunnels
;;; with CONNECT, in HTTPS_PROXY.  The clones then go cairn -> seal -> cl-transport's
;;; :http-connect carrier -> the proxy, and seal's TLS runs end to end inside the tunnel,
;;; so the proxy sees only ciphertext unless it also intercepts -- which is what
;;; KILN_EXTRA_CA is for, and the two compose.
;;;
;;; cl-transport is in the seed for this, and is loaded only when a proxy is named, so a
;;; build without one does exactly what it did before.  Its symbols are looked up after
;;; it loads, because this file is read before it exists.
;;;
;;; A proxy URL can carry credentials.  They go to the proxy as Proxy-Authorization and
;;; nowhere else: the log names host and port, and no error message quotes the URL.
;;; NO_PROXY is not consulted -- every fetch here goes to the one forge.

(defvar *https-proxy*
  (let ((p (or (env "https_proxy" nil) (env "HTTPS_PROXY" nil))))
    (and p (plusp (length p)) p)))

(defun %percent-decode (s)
  (with-output-to-string (out)
    (loop with i = 0 while (< i (length s))
          do (let ((c (char s i)))
               (if (and (char= c #\%) (<= (+ i 3) (length s))
                        (digit-char-p (char s (+ i 1)) 16) (digit-char-p (char s (+ i 2)) 16))
                   (progn (write-char (code-char (parse-integer s :start (1+ i) :end (+ i 3) :radix 16)) out)
                          (incf i 3))
                   (progn (write-char c out) (incf i)))))))

(defun %parse-proxy-url (url)
  "(values HOST PORT USERINFO) for http://[user[:pass]@]host:port[/].  Signals, without
   quoting URL, if it is not that shape."
  (let ((prefix "http://"))
    (unless (and (> (length url) (length prefix))
                 (string-equal prefix url :end2 (length prefix)))
      (error "HTTPS_PROXY must be an http:// URL (the proxy is spoken to in plain HTTP, with CONNECT)"))
    (let* ((rest (subseq url (length prefix)))
           (rest (subseq rest 0 (or (position #\/ rest) (length rest))))
           (at (position #\@ rest :from-end t))
           (userinfo (and at (subseq rest 0 at)))
           (hostport (if at (subseq rest (1+ at)) rest))
           (colon (position #\: hostport :from-end t))
           (port (and colon (ignore-errors (parse-integer hostport :start (1+ colon))))))
      (unless (and colon (plusp colon) port (< 0 port 65536))
        (error "HTTPS_PROXY must name a host and a port, as http://host:port"))
      (values (subseq hostport 0 colon) port userinfo))))

(defun install-proxy ()
  (if (null *https-proxy*)
      (say "kiln: proxy: none, connecting directly~%")
      (multiple-value-bind (host port userinfo)
          ;; NOT LEFT TO THE DEBUGGER: --script prints a backtrace on an unhandled error,
          ;; and the backtrace shows %PARSE-PROXY-URL's argument -- the URL, password and
          ;; all.  The message alone says what is wrong.
          (handler-case (%parse-proxy-url *https-proxy*)
            (error (e)
              (say "kiln: ~a~%" e)
              (sb-ext:quit :unix-status 1)))
        (handler-bind ((warning #'muffle-warning))
          (let ((*standard-output* (make-broadcast-stream)))
            (asdf:load-system :cl-transport)))
        (let ((dial (find-symbol "DIAL" "CL-TRANSPORT"))
              (proxy (cons host port)))
          (when userinfo
            (setf (symbol-value (find-symbol "*HTTP-PROXY-AUTHORIZATION*" "CL-TRANSPORT"))
                  (format nil "Basic ~a"
                          (seal:base64-encode
                           (sb-ext:string-to-octets (%percent-decode userinfo)
                                                    :external-format :utf-8)))))
          ;; Set before any thread starts, like *trust-store*, so every clone sees it.
          (setf seal.http:*dial*
                (lambda (h p tm)
                  (funcall dial h p :transport :http-connect :proxy proxy :timeout tm)))
          (say "@@ proxy http-connect ~a:~d~:[~; (with credentials)~]~%" host port userinfo)))))

;;; -------------------------------------------------------------------- main

(install-trust)
(install-proxy)

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
