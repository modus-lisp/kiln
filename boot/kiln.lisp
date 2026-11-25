;;;; kiln.lisp -- kiln for a machine with nothing on it but modus: `modus --kiln ...'.
;;;;
;;;;   modus.exe --kiln windows      the workspace here, modus.exe built by modus, vessel's
;;;;                                 apps in the Start menu
;;;;   modus.exe --kiln sync         every repo in repos.lock here: clone what is missing,
;;;;                                 fast-forward what is safe
;;;;
;;;; bin/kiln does these with bash and git; this does them with cairn (git in Lisp, over
;;;; seal's TLS) and Windows' own calls, from inside the executable dist ships.  No git,
;;;; no bash, no SBCL, no administrator.  boot/bundle.lisp puts it into modus.exe and
;;;; boot/main.lisp loads it; it runs on modus only.

(defpackage "KILN" (:use "COMMON-LISP") (:export "MAIN"))
(in-package "KILN")

(defvar *org* "modus-lisp")

(defun note (fmt &rest args)
  (format t "~&kiln: ~?~%" fmt args)
  (finish-output))

(define-condition kiln-error (error) ((text :initarg :text :reader kiln-error-text))
  (:report (lambda (c s) (write-string (kiln-error-text c) s))))
(defun die (fmt &rest args) (error 'kiln-error :text (format nil "~?" fmt args)))

;;; ------------------------------------------------------------------ the workspace

(defun dir-path (p) (uiop:ensure-directory-pathname (substitute #\/ #\\ (namestring p))))
(defun win (p) (substitute #\\ #\/ (namestring p)))

(defun parse-lock (path)
  "((NAME BRANCH COMMIT) ...) from repos.lock, without its #comments."
  (with-open-file (in path)
    (loop for line = (read-line in nil)
          while line
          for words = (uiop:split-string (string-trim '(#\Space #\Tab #\Return) line)
                                         :separator '(#\Space #\Tab))
          for ws = (remove "" words :test #'string=)
          when (and ws (char/= (char (first ws) 0) #\#))
            collect ws)))

(defun repo-dir (ws name) (merge-pathnames (concatenate 'string name "/") ws))
(defun repo-p (dir) (probe-file (merge-pathnames ".git/HEAD" dir)))

;;; ------------------------------------------------------------------------- sync

(defun sync-one (ws name)
  "Clone NAME into WS if it is missing, else fast-forward it when nothing can be lost.
   Returns a one-line report."
  (let ((dir (repo-dir ws name))
        (url (format nil "https://github.com/~a/~a" *org* name)))
    (handler-case
        (cond
          ((not (probe-file dir))
           (let ((repo (cairn:clone url (namestring dir))))
             (format nil "cloned  ~a ~a" name (subseq (cairn:head-commit repo) 0 8))))
          ((not (repo-p dir)) (format nil "skipped ~a: not a git checkout" name))
          (t
           (let ((repo (cairn:open-repository (namestring dir))))
             (multiple-value-bind (kind ref) (cairn::head-ref repo)
               (unless (eq kind :symbolic) (return-from sync-one (format nil "skipped ~a: detached HEAD" name)))
               (let ((branch (subseq ref (length "refs/heads/"))))
                 (multiple-value-bind (staged unstaged) (cairn:status repo)
                   (when (or staged unstaged)
                     (return-from sync-one (format nil "skipped ~a: uncommitted changes" name))))
                 (cairn:fetch repo)
                 (let ((head (cairn:head-commit repo))
                       (up (cairn:resolve-ref repo (format nil "refs/remotes/origin/~a" branch))))
                   (cond ((null up) (format nil "skipped ~a: no origin/~a" name branch))
                         ((string= head up) (format nil "current ~a" name))
                         ((equal (cairn:merge-base repo head up) head)
                          (cairn:checkout repo up)
                          (cairn::update-ref repo ref up)
                          (format nil "updated ~a ~a..~a" name (subseq head 0 8) (subseq up 0 8)))
                         (t (format nil "skipped ~a: diverged from origin/~a" name branch)))))))))
      (error (e) (format nil "FAILED  ~a: ~a" name e)))))

(defun sync (ws lock &key only)
  (let ((names (or only (mapcar #'first (parse-lock lock)))))
    (note "syncing ~d repos from github.com/~a into ~a" (length names) *org* (win ws))
    (let ((failed 0))
      (dolist (n names)
        (let ((line (sync-one ws n)))
          (when (search "FAILED" line) (incf failed))
          (format t "  ~a~%" line) (finish-output)))
      (when (plusp failed) (die "~d repos failed to sync" failed)))))

;;; ------------------------------------------------------------- Windows, by name

(defun w32 (type fn &rest args) (apply #'modus-int::w32-call* type fn args))
(defun octets (n) (make-array n :element-type '(unsigned-byte 8) :initial-element 0))
(defun put (v off n x) (dotimes (k n) (setf (aref v (+ off k)) (ldb (byte 8 (* 8 k)) x))))
(defun get64 (v off) (modus-int::w32-octets-get v off :u64))
(defun invalid-handle-p (h) (or (null h) (eql h 0) (eql h -1) (eql h #xFFFFFFFFFFFFFFFF)))

(defun self-exe ()
  (or (modus-int::%w32-module-file-name) (die "Windows will not say where this modus.exe is")))

(defun set-env (name value)
  (w32 :bool "kernel32.dll!SetEnvironmentVariableW" name (or value 0)))

(defun quote-arg (s) (if (find #\Space s) (format nil "\"~a\"" s) s))

(defun run (args &key cwd log env)
  "Run ARGS (the program first) in CWD with ENV ((NAME . VALUE) ...) added to this
   process's environment, its output in LOG; wait, and return its exit code."
  (let ((sa (octets 24)) (si (octets 104))
        ;; the program in Windows' form; every argument as given, since modus reads a
        ;; backslash in a path as part of a name
        (cmdline (format nil "~{~a~^ ~}" (cons (quote-arg (win (first args)))
                                                (mapcar (lambda (a) (quote-arg (namestring a))) (rest args))))))
    (put sa 0 4 24) (put sa 16 4 1)                     ; SECURITY_ATTRIBUTES, inheritable
    (let ((h (w32 :ptr "kernel32.dll!CreateFileW" (win log) #x40000000 3 (list :bytes sa) 2 128 0)))
      (when (invalid-handle-p h) (die "cannot write ~a" (win log)))
      (put si 0 4 104) (put si 60 4 #x100)               ; STARTUPINFOW, STARTF_USESTDHANDLES
      (put si 88 8 h) (put si 96 8 h)
      (dolist (e env) (set-env (car e) (cdr e)))
      (unwind-protect
           ;; (values OK LAST-ERROR PROCESS_INFORMATION): a :BYTES argument goes in but
           ;; is not one of the values, a :BUF one is
           (multiple-value-bind (ok err pi)
               (w32 :bool "kernel32.dll!CreateProcessW" 0 cmdline 0 0 1 #x08000000 0
                    (string-right-trim "\\" (win (or cwd (uiop:getcwd)))) (list :bytes si) '(:buf 24))
             (unless ok (die "cannot start ~a: ~a" (first args) (modus-int::w32-error-text err)))
             (let ((process (get64 pi 0)) (thread (get64 pi 8)))
               (w32 :bool "kernel32.dll!CloseHandle" thread)
               (w32 :u32 "kernel32.dll!WaitForSingleObject" process #xFFFFFFFF)
               (multiple-value-bind (ok2 err2 code) (w32 :bool "kernel32.dll!GetExitCodeProcess" process '(:out :u32))
                 (declare (ignore ok2 err2))
                 (w32 :bool "kernel32.dll!CloseHandle" process)
                 code)))
        (w32 :bool "kernel32.dll!CloseHandle" h)
        (dolist (e env) (set-env (car e) nil))))))

(defun file-text (path)
  (with-open-file (s path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (if (null s) ""
        (let ((b (make-array (file-length s) :element-type '(unsigned-byte 8))))
          (read-sequence b s)
          (map 'string (lambda (c) (if (< c 128) (code-char c) #\?)) b)))))

(defun tail (path n)
  (let* ((lines (uiop:split-string (file-text path) :separator '(#\Newline)))
         (lines (remove "" (mapcar (lambda (l) (string-right-trim '(#\Return) l)) lines) :test #'string=)))
    (last lines n)))

(defun copy-file (from to)
  (multiple-value-bind (ok err) (w32 :bool "kernel32.dll!CopyFileW" (win from) (win to) 0)
    (unless ok (die "cannot copy ~a to ~a: ~a" (win from) (win to) (modus-int::w32-error-text err)))))

(defparameter *compatibility-manifest*
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<assembly manifestVersion=\"1.0\" xmlns=\"urn:schemas-microsoft-com:asm.v1\">
  <compatibility xmlns=\"urn:schemas-microsoft-com:compatibility.v1\">
    <application><supportedOS Id=\"{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}\"/></application>
  </compatibility>
</assembly>
")

(defun add-manifest (exe)
  "Windows 10 compatibility, so Windows does not treat EXE as an older app (child windows
   may then be layered: a view can fade).  bin/kiln uses the SDK's mt.exe; this is the
   call mt.exe makes, UpdateResourceW: RT_MANIFEST (24), resource 1."
  (let ((data (map '(vector (unsigned-byte 8)) #'char-code *compatibility-manifest*))
        (h (w32 :ptr "kernel32.dll!BeginUpdateResourceW" (win exe) 0)))
    (if (invalid-handle-p h)
        (note "no compatibility manifest (BeginUpdateResource failed): views cannot fade")
        (let ((ok (w32 :bool "kernel32.dll!UpdateResourceW" h 24 1 0 (list :bytes data) (length data))))
          (unless (and (w32 :bool "kernel32.dll!EndUpdateResourceW" h (if ok 0 1)) ok)
            (note "no compatibility manifest (UpdateResource failed): views cannot fade"))))))

;;; ---------------------------------------------------------------------- windows

(defun builder-p ()
  "T when this modus carries the cross tooling a build script needs (MODUS_BUILDER=1)."
  (let ((p (find-package "MODUS.MVM")))
    (and p (fboundp (intern "%BUILDER-BUILD-IMAGE" p)))))

(defun lf-tree-p (modus)
  "NIL when modus's sources were checked out with CRLF line ends (git's core.autocrlf):
   such a tree builds different bytes."
  (let ((f (merge-pathnames "mvm/compiler.lisp" modus)))
    (with-open-file (s f :element-type '(unsigned-byte 8) :if-does-not-exist nil)
      (and s (let ((b (make-array (min 65536 (file-length s)) :element-type '(unsigned-byte 8))))
               (read-sequence b s)
               (not (find 13 b)))))))

(defun local-app-data ()
  (dir-path (or (uiop:getenv "LOCALAPPDATA") (die "no LOCALAPPDATA"))))

(defun build-windows (ws state)
  (let* ((modus (repo-dir ws "modus"))
         (self (self-exe))
         (builder (merge-pathnames "builder.exe" state))
         (exe (merge-pathnames "modus.exe" state)))
    (unless (repo-p modus) (die "no modus checkout in ~a (modus.exe --kiln sync)" (win ws)))
    (unless (lf-tree-p modus)
      (die "~a has CRLF line ends (git's core.autocrlf): delete it and let kiln clone it, or check it out with core.autocrlf=false"
           (win modus)))
    (unless (builder-p)
      (die "this modus.exe cannot build modus: it is not a builder (dist's modus.exe is)"))
    (let ((head (cairn:head-commit (cairn:open-repository (namestring modus)))))
      (note "modus ~a, built by this modus.exe" (subseq head 0 8)))
    (note "stage 1: a builder from this tree (a few minutes)")
    (let ((code (run (list self "--script" (namestring (merge-pathnames "mvm/build-win64-cli.lisp" modus))) :cwd modus
                     :log (merge-pathnames "stage1.log" state)
                     :env `(("MODUS_BUILDER" . "1") ("MODUS_NARROW_STRINGS" . "1") ("MODUS_FASL" . "0")
                            ("MODUS_WIN64_OUT" . ,(namestring builder))))))
      (unless (and (eql code 0) (probe-file builder))
        (format t "~{  ~a~%~}" (tail (merge-pathnames "stage1.log" state) 5))
        (die "stage 1 failed: ~a" (win (merge-pathnames "stage1.log" state)))))
    (note "stage 2: modus.exe from that builder")
    (let ((code (run (list builder "--script" (namestring (merge-pathnames "mvm/build-win64-cli.lisp" modus))) :cwd modus
                     :log (merge-pathnames "stage2.log" state)
                     :env `(("MODUS_FASL" . "0") ("MODUS_WIN64_OUT" . ,(namestring exe))))))
      (unless (and (eql code 0) (probe-file exe))
        (format t "~{  ~a~%~}" (tail (merge-pathnames "stage2.log" state) 5))
        (die "stage 2 failed: ~a" (win (merge-pathnames "stage2.log" state)))))
    (let ((check (merge-pathnames "check.lisp" state)) (log (merge-pathnames "check.log" state)))
      (with-open-file (s check :direction :output :if-exists :supersede)
        (write-line "(princ (+ 1 2))" s))
      (run (list exe "--script" check) :log log)
      (unless (search "3" (file-text log)) (die "the new modus.exe does not run")))
    exe))

(defun install-windows (ws exe dest)
  (ensure-directories-exist dest)
  (let ((vessel (merge-pathnames "vessel.exe" dest))
        (log (merge-pathnames "install.log" (make-pathname :name nil :type nil :defaults exe))))
    (copy-file exe vessel)
    (add-manifest vessel)
    (note "installed ~a" (win vessel))
    (run (list vessel "--script" (merge-pathnames "vessel/windows/install.lisp" ws))
         :log log :env `(("VESSEL_INSTALL_EXE" . ,(win vessel))))
    (let ((lines (remove-if-not (lambda (l) (uiop:string-prefix-p "install:" l))
                                (tail log 1000))))
      (unless lines
        (format t "~{  ~a~%~}" (tail log 5))
        (die "the Start menu items were not made: ~a" (win log)))
      (format t "~{~a~%~}" lines)
      (note "in the Start menu: Hello 3D, Storybook, chirp"))))

(defun windows (ws lock args)
  (let ((build t) (dest nil) (do-sync t))
    (dolist (a args)
      (cond ((string= a "--no-build") (setq build nil))
            ((string= a "--no-sync") (setq do-sync nil))
            ((uiop:string-prefix-p "--dest=" a) (setq dest (dir-path (subseq a 7))))
            (t (die "windows: unknown argument ~a (modus.exe --kiln help)" a))))
    (let* ((state (merge-pathnames ".kiln/windows/" ws))
           (dest (or dest (merge-pathnames "Programs/Vessel/" (local-app-data)))))
      (ensure-directories-exist state)
      (when do-sync (sync ws lock))
      (let ((exe (if build
                     (build-windows ws state)
                     (or (probe-file (merge-pathnames "modus.exe" state))
                         (die "no build to install (run --kiln windows without --no-build)")))))
        (install-windows ws exe dest)))))

;;; ------------------------------------------------------------------------- main

(defparameter *usage* "modus.exe --kiln COMMAND -- kiln with nothing installed but modus.exe.

  windows [--no-sync] [--no-build] [--dest=DIR]
        Sync the workspace (the current directory), build modus.exe from its modus
        checkout with this modus.exe (two stages, about 20 minutes), install it as
        DIR\\vessel.exe (default %LOCALAPPDATA%\\Programs\\Vessel), and put Hello 3D,
        Storybook and chirp in the Start menu.  No administrator.
  sync  Every repo in repos.lock, here: clone what is missing (with cairn, git in
        Lisp), fast-forward what is safe, leave anything else as it is.
  help  This.

The workspace is the current directory; --workspace=DIR before the command names another.
")

(defun main (args &key lock)
  (let ((ws (dir-path (uiop:getcwd))))
    (loop while (and args (uiop:string-prefix-p "--workspace=" (first args)))
          do (setq ws (dir-path (subseq (pop args) 12))))
    (handler-case
        (let ((cmd (or (first args) "help")))
          (cond ((string= cmd "sync") (sync ws lock))
                ((string= cmd "windows") (windows ws lock (rest args)))
                ((member cmd '("help" "--help" "-h") :test #'string=) (write-string *usage*))
                (t (die "unknown command ~a (modus.exe --kiln help)" cmd))))
      (kiln-error (e)
        (format t "~&kiln: ~a~%" e)
        (finish-output)
        (uiop:quit 1)))))
