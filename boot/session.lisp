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
;;;; A NEW SESSION EACH TIME, unless one is named.  KILN_SESSION=<name> resumes: same
;;;; nsec, same npub, so a link issued before a restart still verifies and enrolled
;;;; devices stay enrolled.  Without it, a fresh identity — which a Nostr client takes
;;;; in its stride, and which is much the lesser evil next to two live desktops claiming
;;;; to be the same one.
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

(defun %session-lock (dir)
  "Take DIR's lock, or report who has it.  Returns T if taken, or the pid holding it.

   Advisory and racy by construction — two launches in the same millisecond can both
   win.  It is here to catch the case that actually happens (a second launch, minutes
   later, of a session already running) and not to be a mutex."
  (let* ((path (format nil "~a/lock" dir))
         (held (%session-slurp path))
         (pid (and held (ignore-errors (parse-integer held :junk-allowed t)))))
    (if (and pid (ignore-errors (sb-posix:kill pid 0) t))
        pid
        (progn (ignore-errors
                (with-open-file (o path :direction :output :if-exists :supersede
                                        :if-does-not-exist :create)
                  (format o "~d~%" (sb-posix:getpid))))
               t))))

(defun kiln-session (&key name)
  "Find or make a session.  Returns (values NAME SECRET NPUB FRESH-P).

   NAME (or KILN_SESSION) resumes an existing session; without one this mints a new
   identity and names it after its own public key.  Writes the secret 0600 and takes the
   directory's lock, complaining if somebody live is already holding it."
  (let* ((root (%session-dir-root))
         (name (or name
                   (let ((e (sb-ext:posix-getenv "KILN_SESSION")))
                     (and e (plusp (length e)) e))))
         (fresh nil)
         secret)
    ;; A named session that exists is a resume; a named one that does not is a new
    ;; session that was told what to be called, which is the only case where the name
    ;; and the key are allowed to disagree.
    (when name
      (setf secret (%session-slurp (format nil "~a/~a/nsec" root name)))
      (unless (%session-hex-p secret) (setf secret nil)))
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
                     @@   start without KILN_SESSION to get a session of your own.~%"
                  name held)
          (finish-output *error-output*)))
      (values name secret
              (let ((enc (find-symbol "NPUB-ENCODE" "CL-NOSTR.BECH32"))
                    (pk (%session-pubkey secret)))
                (and enc (fboundp enc) pk (ignore-errors (funcall enc pk))))
              fresh))))
