;;;; zero-boot.lisp — what a kiln zero CARD does when it powers on, before the desk.
;;;;
;;;; A card has no builder beside it to type (ssh-boot) at the board, so its restart hook is
;;;; BOOT-MAIN, which reads the card's cmdline.txt (bootargs, one line, space-separated) and:
;;;;
;;;;   1. brings the network up: the USB tree, the I/O core and modus's SSH server (ssh-boot),
;;;;      with DHCP first when NET=dhcp (the default) and 10.0.0.2 via 10.0.0.1 when nothing
;;;;      answers or NET=static;
;;;;   2. gives the SSH server a host key of its own -- derived from NSEC, so it survives a reboot,
;;;;      or random for this boot -- in place of the image's all-zero default, and the client keys
;;;;      it accepts (SSH_KEYS); with none, it accepts no one;
;;;;   3. on a thread of its own, once SNTP has set the clock: a NIP-17 private message (NIP-59
;;;;      gift wrap) to each OWNER on each RELAY, with what the board is -- its npub, address,
;;;;      host key, image -- so an owner learns where it came up and how to reach it;
;;;;
;;;; and then runs the desk.  Nothing in 1-3 can keep the desk from starting: each step that
;;;; fails says so on the console and in kmsg, and the next one runs.
;;;;
;;;;   NSEC=nsec1...             the board's identity: its nostr key, and its SSH host key's seed
;;;;                             (absent: both fresh each boot, and the message says so)
;;;;   OWNER=npub1...[,npub1..]  who is told the board is up
;;;;   RELAYS=wss://a[,wss://b]  where the message is sent (RELAY= too)
;;;;   SSH_KEYS=AAAAC3...[,...]  the Ed25519 keys SSH accepts: the base64 field of each
;;;;                             authorized_keys line (a bootarg holds no spaces)
;;;;   NET=dhcp|static|off       how the address is found (default dhcp)
;;;;   DESK=off                  no desk: a headless board, its REPL on the serial console
;;;;
;;;; cl-nostr, seal and natrium are --with systems the card build adds; this file names their
;;;; functions by name, so kiln-zero loads without them.

(defpackage #:kiln-zero-boot
  (:use #:cl)
  (:export #:boot-main #:net-start #:report #:report-text #:status #:set-ca-pem))
(in-package #:kiln-zero-boot)

(defvar *log* nil "What each step did, newest first: (step . text).")
(defvar *nostr-secret* nil "This board's nostr secret key (32 bytes).")
(defvar *host-public* nil "The SSH host key's public half (32 bytes).")
(defvar *net-mode* nil "How the address was found: :dhcp, :static, :off, or NIL (not started).")
(defvar *trust-store* nil "seal's trust store, parsed from the build machine's CA bundle when the core was made.")
(defvar *report-thread* nil)
(defvar *report-results* nil "Per relay: (url . :sent / :rejected / the error).")

(defun %sym (name pkg)
  (let ((p (find-package pkg)))
    (and p (find-symbol name p))))
(defun %fn (name pkg)
  ;; a KERNEL function (MODUS-INT, MODUS.SSH, ...) has no symbol until something interns its
  ;; name, so FIND-SYMBOL misses one nothing has typed: INTERN finds the image's function
  (let ((s (if (and (> (length pkg) 4) (string= "MODUS" pkg :end2 5) (find-package pkg))
               (intern name pkg)
               (%sym name pkg))))
    (unless (and s (fboundp s)) (error "kiln-zero-boot: ~a::~a is not in this image" pkg name))
    (symbol-function s)))
(defun %kernel (name) (symbol-function (intern name "MODUS-INT")))
(defun %kernel-var (name) (intern name "MODUS-INT"))

(defun %note (step fmt &rest args)
  (let ((text (apply #'format nil fmt args)))
    (push (cons step text) *log*)
    (ignore-errors (format t "~&kiln-zero-boot: ~a: ~a~%" step text) (finish-output))
    text))

(defun %kmsg (level tag a b c)
  (ignore-errors (funcall (%kernel "KMSG-EVENT") level tag a b c)))

(defun %wait-ms (ms)
  "Sleep MS on a thread (CL:SLEEP does nothing on bare metal)."
  (funcall (%kernel "%NS-WAIT") 0 0 ms))

;;; ---- bootargs ------------------------------------------------------------------------------
(defun %bootarg (name)
  (let ((v (ignore-errors (funcall (%kernel "%CLI-GETENV") name))))
    (and (stringp v) (plusp (length v)) v)))

(defun %split (s ch)
  (let ((out '()) (start 0))
    (loop for i = (position ch s :start start)
          do (let ((part (subseq s start i)))
               (when (plusp (length part)) (push part out)))
             (if i (setf start (1+ i)) (return)))
    (nreverse out)))

(defun %bootarg-list (&rest names)
  (loop for n in names append (let ((v (%bootarg n))) (and v (%split v #\,)))))

;;; ---- bytes ---------------------------------------------------------------------------------
(defun %u8 (n) (make-array n :element-type '(unsigned-byte 8)))
(defun %bytes (string) (map '(vector (unsigned-byte 8)) #'char-code string))
(defun %cat (&rest vs)
  (let ((out (%u8 (reduce #'+ vs :key #'length))) (p 0))
    (dolist (v vs out) (replace out v :start1 p) (incf p (length v)))))

(defun %base64 (bytes &key (pad t))
  (let ((abc "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        (out (make-string-output-stream)) (n (length bytes)))
    (do ((i 0 (+ i 3))) ((>= i n))
      (let ((b (+ (ash (aref bytes i) 16)
                  (if (< (+ i 1) n) (ash (aref bytes (+ i 1)) 8) 0)
                  (if (< (+ i 2) n) (aref bytes (+ i 2)) 0))))
        (write-char (char abc (ldb (byte 6 18) b)) out)
        (write-char (char abc (ldb (byte 6 12) b)) out)
        (cond ((< (+ i 1) n) (write-char (char abc (ldb (byte 6 6) b)) out))
              (pad (write-char #\= out)))
        (cond ((< (+ i 2) n) (write-char (char abc (ldb (byte 6 0) b)) out))
              (pad (write-char #\= out)))))
    (get-output-stream-string out)))

(defun %unbase64 (s)
  (let ((abc "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        (acc 0) (bits 0) (out '()))
    (loop for c across s
          for v = (position c abc)
          while v
          do (setf acc (logior (ash (logand acc #xFFFF) 6) v)) (incf bits 6)
             (when (>= bits 8) (decf bits 8) (push (ldb (byte 8 bits) acc) out)))
    (coerce (nreverse out) '(vector (unsigned-byte 8)))))

(defun %sha256 (bytes) (funcall (%fn "SHA256" "NATRIUM") bytes))
(defun %random (n) (funcall (%fn "RANDOM-BYTES" "NATRIUM") n))

(defun %ssh-blob (pub)
  "The SSH wire form of an Ed25519 public key: string \"ssh-ed25519\", string KEY."
  (%cat (%u8-of 0 0 0 11) (%bytes "ssh-ed25519") (%u8-of 0 0 0 32) pub))
(defun %u8-of (&rest bs) (coerce bs '(vector (unsigned-byte 8))))

(defun host-key-line ()
  (and *host-public* (format nil "ssh-ed25519 ~a" (%base64 (%ssh-blob *host-public*)))))
(defun host-key-fingerprint ()
  (and *host-public* (format nil "SHA256:~a" (%base64 (%sha256 (%ssh-blob *host-public*)) :pad nil))))

;;; ---- identity --------------------------------------------------------------------------------
(defun %identity ()
  "This board's nostr secret and its SSH host key's seed: from NSEC, or fresh."
  (let ((nsec (%bootarg "NSEC")))
    (if nsec
        (let ((sk (funcall (%fn "NSEC-DECODE" "CL-NOSTR.BECH32") nsec)))
          (setf sk (coerce sk '(vector (unsigned-byte 8))))
          (unless (= (length sk) 32) (error "NSEC is not a 32-byte key"))
          ;; the host key is DERIVED, not the nostr key itself: one secret, two curves, kept apart
          (values sk (%sha256 (%cat sk (%bytes "modus ssh host key"))) :nsec))
        (values (%random 32) (%random 32) :fresh))))

(defun npub ()
  (and *nostr-secret*
       (funcall (%fn "NPUB-ENCODE" "CL-NOSTR.BECH32")
                (funcall (%fn "PUBLIC-KEY-OF-SECRET" "CL-NOSTR.KEYS") *nostr-secret*))))

;;; ---- 1. the network ----------------------------------------------------------------------------
(defun %ip-string (addr)
  (format nil "~d.~d.~d.~d" (ldb (byte 8 0) addr) (ldb (byte 8 8) addr)
          (ldb (byte 8 16) addr) (ldb (byte 8 24) addr)))
(defun %state-u8 (off)
  (cl-user::mem-ref (+ (funcall (%kernel "E1000-STATE-BASE")) off) :u8))
(defun %state-u32 (off)
  "The four bytes at the network state's OFF, first byte lowest (an IP address in network order
   comes back with its first octet in the low byte)."
  (logior (%state-u8 off) (ash (%state-u8 (+ off 1)) 8)
          (ash (%state-u8 (+ off 2)) 16) (ash (%state-u8 (+ off 3)) 24)))

(defun address () (ignore-errors (%ip-string (%state-u32 #x18))))
(defun gateway () (ignore-errors (%ip-string (%state-u32 #x1C))))
(defun mac ()
  (ignore-errors (format nil "~{~2,'0x~^:~}" (loop for i below 6 collect (%state-u8 (+ 8 i))))))

(defun net-start ()
  "The network, the I/O core and the SSH server (modus's SSH-BOOT), as NET= says."
  (let ((mode (let ((m (%bootarg "NET"))) (if m (intern (string-upcase m) :keyword) :dhcp))))
    (if (eq mode :off)
        (setf *net-mode* :off)
        (progn
          (setf (symbol-value (%kernel-var "*SSH-BOOT-DHCP*")) (eq mode :dhcp))
          (funcall (%kernel "SSH-BOOT"))
          (setf *net-mode*
                (if (and (eq mode :dhcp)
                         (eql 3 (logand (%state-u32 #x60) #xFF)))
                    :dhcp
                    :static))
          (%note "net" "~(~a~) ~a via ~a, mac ~a" *net-mode* (address) (gateway) (mac))))
    *net-mode*))

;;; ---- 2. SSH: a host key of its own, and who may log in -------------------------------------------
(defun ssh-start (host-seed)
  (let ((priv (coerce host-seed '(vector (unsigned-byte 8)))))
    (funcall (%fn "SSH-SET-HOST-KEY" "MODUS.SSH") priv)
    ;; the public half modus computed and serves (+0x730), not a second computation of it
    (setf *host-public* (coerce (loop for i below 32 collect (%state-u8 (+ #x730 i)))
                                '(vector (unsigned-byte 8))))
    (funcall (%fn "PRE-COMPUTE-HOST-SIGN" "MODUS.SSH")))
  (funcall (%fn "SSH-AUTHORIZE-KEYS-RESET" "MODUS.SSH"))
  (let ((n 0))
    (dolist (k (%bootarg-list "SSH_KEYS" "SSH_KEY") n)
      (let ((blob (%unbase64 k)))
        (if (and (= (length blob) 51) (equalp (subseq blob 4 15) (%bytes "ssh-ed25519")))
            (when (funcall (%fn "SSH-AUTHORIZE-KEY" "MODUS.SSH") (subseq blob 19 51)) (incf n))
            (%note "ssh" "SSH_KEYS: not an ssh-ed25519 key, skipped: ~a" k))))
    (%note "ssh" "host key ~a; ~d client key~:p allowed" (host-key-fingerprint) n)
    n))

;;; ---- 3. the report -------------------------------------------------------------------------------
(defun %image-commit ()
  (ignore-errors
   (let* ((fn (%fn "IMAGE-CONFIGURATION" "MODUS"))
          (data (funcall fn :data t)))
     (getf (getf data :build) :commit))))

(defun %utc (ut)
  (multiple-value-bind (s m h d mo y) (decode-universal-time ut 0)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d UTC" y mo d h m s)))

(defun report-text ()
  "What the owner is sent."
  (let ((ip (address)) (keys (ignore-errors (funcall (%fn "SSH-AUTH-KEYS-COUNT" "MODUS.SSH")))))
    (with-output-to-string (o)
      (format o "A modus Zero 2 W is up.~%~%")
      (format o "npub: ~a~:[ (fresh this boot: no NSEC on the card)~;~]~%" (npub) (%bootarg "NSEC"))
      (format o "address: ~a (~(~a~)), gateway ~a, mac ~a~%" ip *net-mode* (gateway) (mac))
      (format o "ssh: ssh modus@~a~%" ip)
      (format o "host key: ~a~%  ~a~%" (host-key-fingerprint) (host-key-line))
      (format o "ssh logins allowed: ~a key~:p~%" (or keys 0) (or keys 0))
      (format o "clock: ~a~%" (%utc (get-universal-time)))
      (let ((c (%image-commit))) (when c (format o "modus: ~a~%" c)))
      (format o "~%Reply here to talk to the board's owner key; nothing reads replies yet.~%"))))

(defun %clock-set-p () (> (get-universal-time) 3970000000))   ; after 2025-10

(defun %send-one (url wrap-json event-id)
  "Publish WRAP-JSON on URL; :SENT when the relay answers OK true."
  (let* ((connect (%fn "CONNECT" "SEAL.WEBSOCKET"))
         (send (%fn "SEND-TEXT" "SEAL.WEBSOCKET"))
         (recv (%fn "RECEIVE-TEXT" "SEAL.WEBSOCKET"))
         (close (%fn "CLOSE-SOCKET" "SEAL.WEBSOCKET"))
         (ws (funcall connect url :verify t)))
    (unwind-protect
         (progn
           (funcall send ws (concatenate 'string "[\"EVENT\"," wrap-json "]"))
           (loop repeat 20
                 for text = (funcall recv ws)
                 while text
                 when (and (search "\"OK\"" text) (search event-id text))
                   do (return (if (search "true" text) :sent (list :rejected text)))
                 finally (return :no-answer)))
      (ignore-errors (funcall close ws)))))

(defun report (&key (owners (%bootarg-list "OWNER")) (relays (%bootarg-list "RELAYS" "RELAY")))
  "Gift-wrap REPORT-TEXT to each of OWNERS on each of RELAYS.  The results, per relay."
  (cond
    ((null owners) (%note "report" "no OWNER on the card: nobody to tell") nil)
    ((null relays) (%note "report" "no RELAYS on the card: nowhere to send") nil)
    (t
     (let ((text (report-text)) (results '()))
       (dolist (owner owners)
         (let* ((hex (funcall (%fn "PUBKEY-HEX" "CL-NOSTR.BECH32") owner))
                (wrap (funcall (%fn "BUILD-GIFTWRAP" "CL-NOSTR.NIP59") *nostr-secret* hex text))
                (json (funcall (%fn "EVENT->JSON" "CL-NOSTR.EVENT") wrap))
                (id (funcall (%fn "EVENT-ID" "CL-NOSTR.EVENT") wrap)))
           (dolist (url relays)
             (let ((r (handler-case (%send-one url json id)
                        (error (e) (list :error (princ-to-string e))))))
               (push (cons url r) results)
               (%note "report" "~a to ~a: ~s" url (subseq owner 0 (min 12 (length owner))) r)
               (%kmsg (if (eq r :sent) 1 2) "RPRT" (if (eq r :sent) 1 0) (length results) 0)))))
       (setf *report-results* (nreverse results))))))

(defun %report-job ()
  "The report, on the MAIN thread (a job: the REPL's idle, or the desk's SERVE-JOBS, runs it)."
  (handler-case
      (if (%clock-set-p)
          (report)
          (%note "report" "the clock was never set (SNTP), and a relay drops an event dated 1900"))
    (error (e) (%note "report" "failed: ~a" e))))

(defun %report-waiter ()
  "The function for a thread of its own: wait for SNTP, then hand the report to the main thread.
   A thread may not store its own objects into shared memory (modus's shared-store guard:
   *LOG*, the results, nostr's and seal's state, and the symbol table INTERN adds to are all
   shared), so everything it needs is resolved HERE, on the main thread, and it does nothing
   but wait and send the main thread one message through the jobs channel, as SSH does."
  (let ((wait (%kernel "%NS-WAIT")) (send (%kernel "%NS-SEND"))
        (jobs (symbol-value (%kernel-var "*NS-MAIN-JOBS*")))
        (msg (list -1 "(kiln-zero-boot::%report-job)")))
    (lambda ()
      (loop repeat 300 until (> (get-universal-time) 3970000000) do (funcall wait 0 0 1000))
      (funcall send jobs msg))))

;;; ---- the CA bundle: parsed when the core is made, used from memory ------------------------------
(defun set-ca-pem (bytes)
  "Parse the build machine's CA bundle (BYTES, PEM) into seal's trust store, at core build time."
  (setf *trust-store* (funcall (%fn "MAKE-TRUST-STORE-FROM-PEM" "SEAL") (map 'string #'code-char bytes)))
  (length (funcall (%fn "TRUST-STORE-CERTIFICATES" "SEAL") *trust-store*)))

(defun %install-trust-store ()
  ;; seal looks for /etc/ssl/certs/... with FILE-WRITE-DATE; on the board a file call halts the
  ;; core.  Its :SYSTEM store is this one instead.
  (when *trust-store*
    (let ((s (%sym "LOAD-SYSTEM-TRUST-STORE" "SEAL")) (store *trust-store*))
      (when s (setf (symbol-function s) (lambda () store))))
    t))

;;; ---- the hook ----------------------------------------------------------------------------------
(defmacro %step (name &body body)
  `(handler-case (progn ,@body)
     (error (e) (%note ,name "failed: ~a" e) nil)))

(defun status ()
  (list :net *net-mode* :address (address) :npub (npub) :host-key (host-key-fingerprint)
        :report *report-results* :log (reverse *log*)))

(defun boot-main (&key (desk (not (equalp (%bootarg "DESK") "off"))))
  "The card's restart hook: network, SSH, the owner's message (on a thread), then the desk
   (DESK NIL: back to the caller instead, for a test)."
  (%step "trust" (%install-trust-store))
  (multiple-value-bind (nostr host-seed how) (%step "identity" (%identity))
    (setf *nostr-secret* nostr)
    (when how (%note "identity" "~a (~(~a~))" (npub) how))
    (when (and (%step "net" (net-start)) (not (eq *net-mode* :off)))
      (when host-seed (%step "ssh" (ssh-start host-seed)))
      (when nostr
        (setf *report-thread*
              (%step "report" (sb-thread:make-thread (%report-waiter) :name "boot report"))))))
  (when desk (funcall (intern "KILN-ZERO-MAIN" "COMMON-LISP-USER"))))
