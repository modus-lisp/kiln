;;;; session.lisp — a session is an identity, and the identity is where it lives.
;;;;
;;;; WHAT THIS REPLACES.  There used to be one key per HOST, in /etc/kiln/nostr-sec, and
;;;; every desktop launched on that machine signed with it.  That presumes two launches
;;;; on one host mean something to each other, and they do not: they are two desktops
;;;; that happen to share a kernel.  It also produced the failure that ate an evening —
;;;; two processes holding one identity, both answering the same offer, and a phone
;;;; getting whichever replied first.
;;;;
;;;; So the unit is the SESSION.  One nsec per session; several seats can watch one
;;;; session and share its npub, which is the relationship worth being able to prove.
;;;; Two sessions on one host share nothing and look like nothing to each other, which
;;;; is the relationship worth NOT implying.
;;;;
;;;; THE NAME IS THE PUBKEY.  A session is named with BIP-39 words derived from its own
;;;; public key, so the name is not a label attached to an identity — it is a short
;;;; reading OF it. `amber-crisp-ladder' can be said down a phone, and it is checkable
;;;; against the npub rather than merely associated with it.  It is also why the name
;;;; makes a good directory: finding a session by name and finding it by identity are
;;;; the same lookup.
;;;;
;;;; A NEW SESSION EACH TIME.  That is the default and not a fallback: `--resume' is how
;;;; you ask for an old identity, by name or — when only one is idle — by itself.  The
;;;; resumed session keeps its nsec and npub, so a link issued before the restart still
;;;; verifies and enrolled devices stay enrolled.  Otherwise a fresh identity, which a
;;;; Nostr client takes in its stride and which is much the lesser evil next to two live
;;;; desktops claiming to be the same one.
;;;;
;;;; AND NOTHING ELSE IS AN IDENTITY.  There is no host key to fall back to, and that is
;;;; deliberate: a fallback is how one host key ends up signing for four desktops again,
;;;; quietly, on the one machine where nobody re-read the configuration.
;;;;
;;;; THE LIABILITY IS RUNNING ONE SESSION TWICE, and it cannot be prevented from here —
;;;; a second process can always be started.  What it can do is notice: the session
;;;; directory holds a lock naming the pid that took it, and a launch that finds a LIVE
;;;; pid there says so loudly rather than quietly becoming the second voice.

(in-package :cl-user)

(defun %session-dir-root ()
  (or (sb-ext:posix-getenv "KILN_SESSIONS")
      (format nil "~a/sessions" (or (sb-ext:posix-getenv "KILN_ETC") "/etc/kiln"))))

(defun %session-slurp (path)
  "First non-blank line of PATH, trimmed, or NIL."
  (ignore-errors
   (with-open-file (in path :if-does-not-exist nil)
     (when in
       (loop for line = (read-line in nil nil)
             while line
             for tr = (string-trim '(#\Space #\Tab #\Return) line)
             when (plusp (length tr)) return tr)))))

(defun %session-hex-p (s) (and (stringp s) (= (length s) 64)
                               (every (lambda (c) (digit-char-p c 16)) s)))

(defun %session-mint-secret ()
  "A fresh 64-hex secret.  /dev/urandom, and nothing else: this is key material, so the
   clock-and-pid fallback that is fine for NAMING a desktop is not fine here.  Better to
   fail loudly than to mint something guessable."
  (with-open-file (in "/dev/urandom" :element-type '(unsigned-byte 8))
    (let ((b (make-array 32 :element-type '(unsigned-byte 8))))
      (unless (= 32 (read-sequence b in))
        (error "session: could not read 32 bytes of entropy"))
      (string-downcase (format nil "~{~2,'0x~}" (coerce b 'list))))))

(defun %session-pubkey (secret)
  (let ((f (find-symbol "PUBLIC-KEY-OF-SECRET" "CL-NOSTR.KEYS")))
    (and f (fboundp f) (funcall f secret))))

(defun %session-name-for (secret)
  "The BIP-39 name of the session whose key is SECRET, or NIL if this image cannot say.

   Derived, never stored: the name and the identity are the same fact written two ways,
   so there is nothing to keep in step and nothing to disagree."
  (let ((wn (find-symbol "WORD-NAME" "GLASS"))
        (pk (%session-pubkey secret)))
    (when (and wn (fboundp wn) pk)
      (funcall wn :words 3 :bytes (if (stringp pk)
                                      ;; hex -> bytes
                                      (let ((v (make-array (floor (length pk) 2)
                                                           :element-type '(unsigned-byte 8))))
                                        (dotimes (i (length v) v)
                                          (setf (aref v i)
                                                (parse-integer pk :start (* 2 i) :end (+ 2 (* 2 i))
                                                                  :radix 16))))
                                      pk)))))

(defun %hostname ()
  (or (ignore-errors (sb-unix:unix-gethostname)) "?"))

(defun %split-space (s)
  (let ((out '()) (start 0))
    (loop for i from 0 to (length s)
          do (when (or (= i (length s)) (char= (char s i) #\Space))
               (when (> i start) (push (subseq s start i) out))
               (setf start (1+ i))))
    (nreverse out)))

(defun %session-holder (dir)
  "Who holds DIR's lock: NIL (nobody), a PID, or :ELSEWHERE.

   A PID ONLY MEANS SOMETHING IN ITS OWN NAMESPACE.  The container writes its pid 1
   here, and on the host pid 1 is launchd — alive, unrelated, and the wrong answer in
   the dangerous direction.  So the lock records the hostname that took it, and a lock
   from somewhere else is reported as :ELSEWHERE rather than guessed at.

   EPERM counts as ALIVE.  A process we may not signal is still a process; treating the
   refusal as absence is how a running session gets declared resumable."
  (let* ((held (%session-slurp (format nil "~a/lock" dir)))
         (parts (and held (%split-space held)))
         (pid (and parts (ignore-errors (parse-integer (first parts) :junk-allowed t))))
         (host (and parts (second parts))))
    (cond ((null pid) nil)
          ;; No hostname in the lock: written by an older kiln, so the pid's namespace is
          ;; unknown.  Unknown is not "free" — say so rather than trusting a number that
          ;; may belong to somebody else's process table.
          ((null host) :elsewhere)
          ((not (string= host (%hostname))) :elsewhere)
          ((handler-case (progn (sb-posix:kill pid 0) t)
             (sb-posix:syscall-error (e)
               ;; ESRCH is "no such process"; anything else (EPERM) means it is there.
               (/= (sb-posix:syscall-errno e) sb-posix:esrch))
             (error () nil))
           pid)
          (t nil))))

(defun %session-lock (dir)
  "Take DIR's lock, or report who has it.  Returns T if taken, else the holder.

   Advisory and racy by construction — two launches in the same millisecond can both
   win.  It is here to catch the case that actually happens (a second launch, minutes
   later, of a session already running) and not to be a mutex."
  (let ((held (%session-holder dir)))
    (if held
        held
        (progn (ignore-errors
                (with-open-file (o (format nil "~a/lock" dir) :direction :output
                                                              :if-exists :supersede
                                                              :if-does-not-exist :create)
                  (format o "~d ~a~%" (sb-posix:getpid) (%hostname))))
               t))))

(defun %session-live-pid (dir) (%session-holder dir))

(defun kiln-session-list ()
  "Every session on this machine, newest first: (NAME NPUB LIVE-PID SECONDS-OLD).

   `newest' is the nsec's write time, which is when the session was MINTED and not when
   it last ran — a session is its identity, and that is the moment the identity began."
  (let ((root (%session-dir-root)))
    (sort
     (loop for dir in (ignore-errors
                       (directory (merge-pathnames "*/" (format nil "~a/" root))))
           for name = (car (last (pathname-directory dir)))
           for nsec = (format nil "~ansec" (namestring dir))
           for secret = (%session-slurp nsec)
           when (%session-hex-p secret)
             collect (list name
                           (let ((enc (find-symbol "NPUB-ENCODE" "CL-NOSTR.BECH32"))
                                 (pk (%session-pubkey secret)))
                             (and enc (fboundp enc) pk (ignore-errors (funcall enc pk))))
                           (%session-live-pid (string-right-trim "/" (namestring dir)))
                           (or (ignore-errors (file-write-date nsec)) 0)))
     #'> :key #'fourth)))

(defun kiln-session-report (&optional (stream *error-output*))
  "Print the sessions, for somebody choosing one."
  (let ((all (kiln-session-list)))
    (if (null all)
        (format stream "~&@@ no sessions yet — start one without --resume~%")
        (progn
          (format stream "~&@@ sessions:~%")
          (dolist (s all)
            (destructuring-bind (name npub held &rest _) s
              (declare (ignore _))
              (format stream "@@   ~24a ~12a~@[  ~a~]~%"
                      name
                      (cond ((null held) "resumable")
                            ((eq held :elsewhere) "held (elsewhere)")
                            (t (format nil "RUNNING (~d)" held)))
                      npub)))))
    (finish-output stream)
    all))

(defun kiln-session (&key name resume)
  "Find or make a session.  Returns (values NAME SECRET NPUB FRESH-P).

   NEW IS THE DEFAULT.  RESUME is how you say otherwise: a name resumes that session, T
   resumes the only resumable one there is.  With T and a choice to make, this prints
   the sessions and refuses rather than picking for you — the wrong guess here is a
   desktop wearing somebody else's identity.

   Writes the secret 0600 and takes the directory's lock, saying so if a live pid holds
   it already."
  (let* ((root (%session-dir-root))
         (name (or name
                   (when (stringp resume) resume)
                   (let ((e (sb-ext:posix-getenv "KILN_RESUME")))
                     (and e (plusp (length e)) (not (string= e "1")) e))))
         (fresh nil)
         secret)
    ;; --resume with nothing to point at: resume the only one, or show the list.
    (when (and (null name) (or (eq resume t)
                               (equal (sb-ext:posix-getenv "KILN_RESUME") "1")))
      (let ((free (remove-if #'third (kiln-session-list))))
        (cond ((= 1 (length free)) (setf name (first (first free))))
              ((null free)
               (format *error-output* "~&@@ nothing to resume — no session here is idle.~%")
               (kiln-session-report)
               (sb-ext:exit :code 1))
              (t
               (format *error-output* "~&@@ which one?  --resume=<name>~%")
               (kiln-session-report)
               (sb-ext:exit :code 1)))))
    (when name
      (setf secret (%session-slurp (format nil "~a/~a/nsec" root name)))
      (unless (%session-hex-p secret) (setf secret nil))
      ;; A name that resolves to nothing is a typo, not an instruction to invent a
      ;; session with that name: resuming is asking for a PARTICULAR identity.
      (when (and (null secret) (or resume (sb-ext:posix-getenv "KILN_RESUME")))
        (format *error-output* "~&@@ no session called ~a.~%" name)
        (kiln-session-report)
        (sb-ext:exit :code 1)))
    (unless secret
      (setf secret (%session-mint-secret) fresh t)
      (setf name (or name (%session-name-for secret)
                     ;; No cl-nostr in this image: still a session, just one that cannot
                     ;; read its own name.  The key is what matters; the words are for us.
                     (format nil "session-~d" (sb-posix:getpid)))))
    (let ((dir (format nil "~a/~a" root name)))
      (ensure-directories-exist (format nil "~a/" dir))
      (ignore-errors (sb-posix:chmod root #o700))
      (ignore-errors (sb-posix:chmod dir #o700))
      (when fresh
        (with-open-file (o (format nil "~a/nsec" dir) :direction :output
                                                      :if-exists :supersede
                                                      :if-does-not-exist :create)
          (format o "~a~%" secret))
        (ignore-errors (sb-posix:chmod (format nil "~a/nsec" dir) #o600)))
      (let ((held (%session-lock dir)))
        (unless (eq held t)
          (format *error-output*
                  "~&@@ session ~a is ALREADY RUNNING as pid ~d.~%~
                     @@   Two processes on one identity both answer the same offer, and~%~
                     @@   whoever asks gets whichever replies first.  Stop that one, or~%~
                     @@   start without --resume to get a session of your own.~%"
                  name held)
          (finish-output *error-output*)))
      (values name secret
              (let ((enc (find-symbol "NPUB-ENCODE" "CL-NOSTR.BECH32"))
                    (pk (%session-pubkey secret)))
                (and enc (fboundp enc) pk (ignore-errors (funcall enc pk))))
              fresh))))
