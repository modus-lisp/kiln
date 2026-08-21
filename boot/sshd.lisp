;;;; sshd.lisp — the control plane: conch's SSH server, answering with the
;;;; configuration TUI.
;;;;
;;;; This is how you configure a kiln box, and it is deliberately the ONE surface
;;;; that authenticates before it does anything.  The credential is the ed25519
;;;; key you already have; no relay, no certificate, no browser extension, and
;;;; nothing to enrol.  Being SSH, it also works identically whether the box is
;;;; this laptop or the hardware this is eventually meant to run on — which is
;;;; the whole reason to prefer it to a first-run web page.
;;;;
;;;; The host key and authorized_keys both live on the mounted volume, so the
;;;; box keeps its identity across image rebuilds and known_hosts stays quiet.

(require :asdf)
(require :sb-posix)

(defun env (name default) (or (sb-ext:posix-getenv name) default))

(defvar *etc* (env "KILN_ETC" "/etc/kiln"))
(defvar *port* (or (ignore-errors (parse-integer (env "KILN_SSH_PORT" "2222"))) 2222))

(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :conch)
    ;; seal/http for the fetch, jzon to read the reply.
    ;;
    ;; NOT cl-nostr, which has a nip05 resolver already and is the proper home for
    ;; one: it still depends on cl+ssl for wss:// relay TLS, and cl+ssl is an FFI
    ;; binding to OpenSSL.  This control plane needs to look up one string, not a
    ;; C TLS stack, so it goes to seal directly and stays FFI-free.
    (asdf:load-system :seal/http)
    (asdf:load-system :com.inuoe.jzon)))

(load (merge-pathnames "config.lisp" (or *load-truename* #p"/kiln/boot/")))

(setf kiln-config:*config-path* (format nil "~a/config" *etc*))

;;; ---- NIP-05 ------------------------------------------------------------------

(defun split-at (char string)
  (let ((i (position char string)))
    (if i (values (subseq string 0 i) (subseq string (1+ i))) (values "_" string))))

(defun resolve-nip05 (address)
  "NIP-05 name@domain -> (VALUES PUBKEY-HEX ERROR-STRING).

   GET https://domain/.well-known/nostr.json?name=NAME and read names[name].  A
   bare domain resolves the special name \"_\", per the spec."
  (handler-case
      (multiple-value-bind (name domain) (split-at #\@ address)
        (let ((r (seal.http:http-get
                  (format nil "https://~a/.well-known/nostr.json?name=~a" domain name)
                  :headers '(("Accept" . "application/json")))))
          (cond
            ((/= (seal.http:response-status r) 200)
             (values nil (format nil "HTTP ~d" (seal.http:response-status r))))
            (t
             (let* ((text (sb-ext:octets-to-string
                           (coerce (seal.http:response-body r) '(vector (unsigned-byte 8)))
                           :external-format :utf-8))
                    (json (com.inuoe.jzon:parse text))
                    (names (and (hash-table-p json) (gethash "names" json)))
                    (key (and (hash-table-p names) (gethash name names))))
               (cond
                 ((null names) (values nil "no \"names\" object"))
                 ((null key) (values nil (format nil "~a is not listed" name)))
                 ((not (and (stringp key) (= (length key) 64)))
                  (values nil "listed value is not a 64-hex pubkey"))
                 (t (values (string-downcase key) nil))))))))
    (error (e) (values nil (let ((s (princ-to-string e)))
                             (subseq s 0 (min 60 (length s))))))))

(setf kiln-config:*resolve-nip05* #'resolve-nip05)

;;; ---- authorized_keys --------------------------------------------------------

(defun split-on (char string)
  (let ((out '()) (start 0))
    (dotimes (i (1+ (length string)) (nreverse out))
      (when (or (= i (length string)) (char= (char string i) char))
        (when (> i start) (push (subseq string start i) out))
        (setf start (1+ i))))))

(defun authorized-keys (path)
  "Parse an OpenSSH authorized_keys file into the 32-byte ed25519 keys conch
   wants.  Only ssh-ed25519 is understood — it is the only client key type
   conch's publickey auth verifies, so anything else is skipped loudly rather
   than silently ignored."
  (let ((keys '()))
    (when (probe-file path)
      (with-open-file (in path)
        (loop for line = (read-line in nil) while line do
          (let* ((line (string-trim '(#\Space #\Tab #\Return) line)))
            (unless (or (zerop (length line)) (char= (char line 0) #\#))
              (let ((fields (split-on #\Space line)))
                (cond
                  ((and (>= (length fields) 2) (string= (first fields) "ssh-ed25519"))
                   (handler-case
                       (let* ((blob (seal:base64-decode (second fields)))
                              ;; blob = u32 len "ssh-ed25519" u32 len <32 bytes>
                              (key (subseq blob (- (length blob) 32))))
                         (push (coerce key '(simple-array (unsigned-byte 8) (*))) keys))
                     (error (e)
                       (format *error-output* "~&kiln/sshd: unreadable key: ~a~%" e))))
                  (t (format *error-output*
                             "~&kiln/sshd: skipping ~a key — conch verifies ssh-ed25519 only~%"
                             (first fields))))))))))
    (nreverse keys)))

;;; ---- the session ------------------------------------------------------------

(defun utf8 (s) (sb-ext:string-to-octets s :external-format :utf-8))

(defun session (command chan)
  (declare (ignore command))
  (let* ((pty (conch:chan-pty chan)))
    (if (null pty)
        ;; No pty: a full-screen TUI would just spray escapes at a pipe.
        (progn
          (conch:chan-write
           chan (utf8 (format nil "kiln: this is the configuration TUI — connect with a terminal:~%~
                                   ~%    ssh -t -p ~d kiln@<host>~%~%" *port*)))
          1)
        (progn
          (when (conch:pty-p pty)
            ;; Fires on the read loop's thread; RUN-TUI asks for the size itself.
            (setf (conch:pty-on-resize pty) (lambda (c r) (declare (ignore c r)) nil)))
          (kiln-config:run-tui
           :out (lambda (s) (ignore-errors (conch:chan-write chan (utf8 s))))
           :read-byte (lambda () (handler-case (conch:chan-read-byte chan) (error () nil)))
           :more-p (lambda () (plusp (conch:chan-avail chan)))
           :size-fn (lambda () (values (conch:pty-cols pty) (conch:pty-rows pty)))
           :cols (conch:pty-cols pty) :rows (conch:pty-rows pty))
          0))))

;;; ---- main -------------------------------------------------------------------

(defun start ()
  "Serve the control plane.  Returns NIL (having said why) rather than exiting,
   so this can be a thread inside the desktop's image as well as a process."
  (let* ((host-key (format nil "~a/host_ed25519" *etc*))
         (auth-file (format nil "~a/authorized_keys" *etc*))
         (keys (authorized-keys auth-file)))
    (cond
      ((not (probe-file host-key))
       (format *error-output* "~&kiln/sshd: no host key at ~a — not starting~%" host-key)
       (finish-output *error-output*)
       nil)
      ((null keys)
       ;; conch reads NIL as "any key with a valid signature", which for a control
       ;; plane is no authentication at all.  Refuse rather than quietly open up.
       (format *error-output* "~&kiln/sshd: no ssh-ed25519 keys in ~a — refusing to start~%~
                               kiln/sshd: an empty authorized_keys would accept ANY key.~%"
               auth-file)
       (finish-output *error-output*)
       nil)
      (t
       (format *error-output* "~&kiln/sshd: ~d authorized key(s), config at ~a~%"
               (length keys) kiln-config:*config-path*)
       (finish-output *error-output*)
       ;; No forwarding: this session exists to configure the box.  The desktop
       ;; has its own published surface and does not need a tunnel punched to it.
       (conch:serve *port* :host-key host-key :authorized-keys keys
                           :handler #'session :allow-forwarding nil)))))

;;; Run on load only when this file IS the program.  one.lisp sets
;;; KILN_SSHD_EMBEDDED and calls START on a thread of its own instead.
(unless (sb-ext:posix-getenv "KILN_SSHD_EMBEDDED")
  (unless (start) (sb-ext:quit :unix-status 1)))
