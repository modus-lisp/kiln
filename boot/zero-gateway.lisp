;;;; zero-gateway.lisp — the nostr gateway ON the board: boot, DM the owner a login link, and let
;;;; a phone open this board's desk over WebRTC with no other machine in the path.
;;;;
;;;; The gateway (glass-webrtc/nostr-lean) and the desk's identity and admission (glass/nostr,
;;;; here as kiln's zero-glass-nostr) were written for a host: they read their configuration from
;;;; the ENVIRONMENT -- SB-EXT:POSIX-GETENV in glass, UIOP:GETENV in the gateway -- and reach the
;;;; desktop, and the admission service beside it, over TCP to 127.0.0.1.  A board has no
;;;; environment and its TCP is modus's own: so this gives the board an environment (a table both
;;;; readers consult before the real one, which on modus is empty), and modus's bare TCP carries
;;;; 127.0.0.1 to the image's own listeners (net/tcp-conns.lisp LOOPBACK).
;;;;
;;;; (zero-gateway:start :secret "<64 hex>" :owner "npub1..." [:turn "turn:host:port user pass"])
;;;;
;;;; SECRET is the box's identity: keep it on the card, never in a core (a key in a core is every
;;;; board's key).  OWNER may connect and is sent the link.  The desk must be serving RFB
;;;; (kiln-zero-rfb) on RFB-PORT.

(defpackage #:zero-gateway
  (:use #:cl)
  (:export #:start #:boot-main #:setenv #:getenv #:*env* #:mount-ram-cabinet #:net-up-qemu))
(in-package #:zero-gateway)

(defvar *env* (make-hash-table :test 'equal)
  "The board's environment: NAME -> value.  Consulted before the real one.")

(defun getenv (name) (values (gethash name *env*)))
(defun setenv (name value) (setf (gethash name *env*) value))

;;; Both readers ask the table first.  The originals are kept and asked second, so a hosted test
;;; of this file still sees its real environment.
(defvar *posix-getenv* (symbol-function 'sb-ext:posix-getenv))
(defun sb-ext:posix-getenv (name)
  (or (gethash name *env*) (funcall *posix-getenv* name)))
(let ((u (and (find-package "UIOP") (find-symbol "GETENV" "UIOP"))))
  (when (and u (fboundp u))
    (let ((old (symbol-function u)))
      (setf (symbol-function u)
            (lambda (name) (or (gethash name *env*) (funcall old name)))))))

(defun %set-by-name (pkg name value)
  "Set special PKG::NAME when it exists (by name: a symbol named in source here would be a reader
   error on a board built without that package)."
  (let ((s (and (find-package pkg) (find-symbol name pkg))))
    (when (and s (boundp s)) (setf (symbol-value s) value))
    (and s t)))

(defun %call (pkg name &rest args)
  ;; a KERNEL function (MODUS-INT) has no symbol until somebody types its name: INTERN it
  ;; there, and the symbol names the image's function (kiln-zero-ssh's %KERNEL).  CL-USER
  ;; likewise, for kiln's own boot functions.
  (let ((s (if (or (string= pkg "MODUS-INT") (string= pkg "COMMON-LISP-USER"))
               (intern name pkg)
               (and (find-package pkg) (find-symbol name pkg)))))
    (unless (and s (fboundp s)) (error "zero-gateway: ~a::~a is not in this image" pkg name))
    (apply (symbol-function s) args)))

;;; SOMEWHERE TO KEEP THE STORES.  glass/nostr keeps the seat keys, the enrolments and the codes it
;;; has minted in files, and the board's OPEN is a Linux syscall with nothing behind it: the core
;;; halts.  kiln's zero-cabinet (pagetree + cabinet + modus lib/cabinet-fs.lisp) routes OPEN to a
;;; cabinet filesystem; this one is on a RAM disk, so the stores last as long as the power does.
;;; The disk is the region --media puts its clips on: past the core, inside the RAM the image maps.
(defun mount-ram-cabinet (&key (base #x1B000000) (bytes 33554432))
  "Mount a fresh cabinet on BASE..BASE+BYTES, with /glass and /tmp.  T, or NIL with no cabinet."
  (let ((cab (find-symbol "*CABFS*" "MODUS-INT")))
    (cond ((null cab) nil)
          ((symbol-value cab) t)
          (t (%call "MODUS-INT" "CABINET-MOUNT-DEVICE"
                    (%call "MODUS-INT" "CABINET-RAW-DISK" base bytes) :format t)
             (dolist (d '("/glass" "/tmp" "/etc/ssl/certs"))
               (%call "CABINET" "MAKE-DIRECTORIES" (symbol-value cab) d))
             t))))

;;; THE CA BUNDLE.  seal verifies a relay's certificate against the system's roots, and a board
;;; has no /etc/ssl: kiln puts the build machine's bundle in the core (ca-bundle.lisp, generated)
;;; and START writes it where seal looks first.
(defvar *ca-bundle* nil "PEM text of the roots TLS trusts, or NIL.")

(defun %install-ca-bundle ()
  (let ((path (first (symbol-value (or (find-symbol "*SYSTEM-CA-BUNDLES*" "SEAL")
                                       (error "zero-gateway: no seal in this image"))))))
    (when (and *ca-bundle* (not (probe-file path)))
      (with-open-file (s path :direction :output :if-does-not-exist :create)
        (write-string *ca-bundle* s)))
    (probe-file path)))

;;; THE CLIENT.  The published shell asks the box for the rest of itself on data channel 104;
;;; kiln puts the built payload (and its gzip) in the core as base64 (payload.lisp, generated) and
;;; START writes them to the cabinet and points the gateway's payload channel at them.
(defvar *payload-js-b64* nil)
(defvar *payload-gz-b64* nil)

(defun %write-bytes (path bytes)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8)
                          :if-exists :supersede :if-does-not-exist :create)
    (write-sequence bytes s)))

(defun %install-payload ()
  "T when the client payload is on the cabinet and the gateway will serve it."
  (when *payload-js-b64*
    (flet ((bytes (b64) (%call "CL-BASE64" "BASE64-STRING-TO-USB8-ARRAY" b64)))
      (%write-bytes "/glass/payload.js" (bytes *payload-js-b64*))
      (when *payload-gz-b64* (%write-bytes "/glass/payload.js.gz" (bytes *payload-gz-b64*))))
    (%set-by-name "WEBRTC-DATA" "*PAYLOAD-FILE*" "/glass/payload.js")
    (%set-by-name "WEBRTC-DATA" "*PAYLOAD-CHANNEL-ENABLED*" t)))

;;; THE NETWORK UNDER QEMU.  NET-UP (kiln-zero-ssh) finds the hub's RTL8153 behind the Zero's hub;
;;; QEMU raspi3b's usb-net is a plain CDC-ECM device on the root hub, which the kernel's own probe
;;; binds.  The HID scan is switched off first: it re-addresses ports, and QEMU aborts on a transfer
;;; to an address with no device behind it.  Slirp: -netdev user,net=10.0.0.0/24,host=10.0.0.1,dns=10.0.0.3
(defun net-up-qemu (&key (ip #x0200000A) (gateway #x0100000A) (dns #x0A000003))
  (%call "MODUS-INT" "HID-PUT" 0 0)
  (dotimes (p 8) (%call "MODUS-INT" "HID-RESERVE-PORT" p))
  (unless (eql 1 (%call "MODUS.NET" "NIC-PROBE"))
    (error "zero-gateway: no USB NIC"))
  (let ((s (%call "MODUS-INT" "E1000-STATE-BASE")))
    (%call "MODUS.NET.CDC" "CDC-READ-MAC" s)
    (setf (cl-user::mem-ref (+ s #x18) :u32) ip
          (cl-user::mem-ref (+ s #x1C) :u32) gateway))
  (unless (dotimes (i 50)
            (when (eql 1 (%call "MODUS-INT" "ARP-RESOLVE")) (return t))
            (%call "MODUS-INT" "DWC2-DELAY-MS" 100))
    (error "zero-gateway: no ARP reply from the gateway"))
  (%set-by-name "KILN-ZERO-SSH" "*NET-UP*" t)
  (%set-by-name "MODUS-INT" "*BARE-DNS-SERVERS*" (list dns))
  ;; THE USB THREAD, as on the board: core 1 drains the NIC into a ring all the time.  Without it
  ;; every reader is on core 0, and while a sender there encrypts, QEMU drops what arrives -- a
  ;; WebRTC session saw 1 SACK of the hundreds sent, and stalled at the congestion window.
  (when (%call "COMMON-LISP-USER" "KZ-USB-START")
    (%set-by-name "COMMON-LISP-USER" "*KZ-NET-SERVICE*"
                  (symbol-function (find-symbol "%NET-SERVICE" "KILN-ZERO-SSH"))))
  t)

;;; Where a link sends the phone: the published client kiln's gateway serves too (bin/kiln
;;; local --nostr), on nsite.lol under its npub.
(defparameter *client-npub* "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc")

(defun start (&key secret owner relays turn (rfb-port 5900) (admission-port 5915) (rfb t)
                   (login-url-base (format nil "https://~a.nsite.lol/" *client-npub*)))
  "Serve this board's desk to OWNER's phone: identity and admission (glass/nostr, which DMs OWNER
   the login link), then the gateway on a thread of its own.  Returns the gateway thread."
  (unless (and (stringp secret) (= (length secret) 64))
    (error "zero-gateway: SECRET must be the box's 64-hex nostr secret"))
  ;; THE DATE: no RTC, so the board's clock starts at 1900 -- a login code would expire as it
  ;; was minted and a relay drops an event dated 1900.  SNTP over the board's UDP.
  (when (< (get-universal-time) 3786825600)          ; before 2020: never set
    (unless (%call "MODUS-INT" "BARE-SET-CLOCK")
      (error "zero-gateway: the board does not know the date and SNTP did not answer")))
  (setenv "NOSTR_SEC" secret)
  (setenv "GLASS_NOSTR_SEC" secret)
  (when owner
    (setenv "GLASS_NOSTR_ALLOW" owner)
    (setenv "GLASS_LINK_TO" owner))
  (when relays (setenv "NOSTR_RELAYS" (format nil "~{~a~^,~}" relays)))
  ;; the desk and the admission service are in THIS image: loopback TCP
  (setenv "GLASS_HOST" "127.0.0.1")
  (setenv "GLASS_PORT" (princ-to-string rfb-port))
  (setenv "GLASS_ADMISSION_HOST" "127.0.0.1")
  (setenv "GLASS_ADMISSION_PORT" (princ-to-string admission-port))
  (when turn
    ;; "turn:host:port user pass" -- the gateway's own TURN, and the one the link carries
    (let* ((p1 (position #\Space turn)) (p2 (and p1 (position #\Space turn :start (1+ p1)))))
      (when p2
        (setenv "TURN_ICE" turn)
        ;; host:port, no scheme -- what the gateway's TURN client parses (kiln: ${_t[0]#turn:})
        (setenv "TURN_SERVER" (let ((srv (subseq turn 0 p1)))
                                (if (and (> (length srv) 5) (string-equal "turn:" srv :end2 5))
                                    (subseq srv 5) srv)))
        (setenv "TURN_USER" (subseq turn (1+ p1) p2))
        (setenv "TURN_PASS" (subseq turn (1+ p2)))
        ;; glass's link carries (SERVER USER PASS), the server with its turn: scheme -- the
        ;; browser uses it as the ICE server's URL, as kiln local sets it
        (%set-by-name "GLASS" "*TURN-ICE*"
                      (list (subseq turn 0 p1) (subseq turn (1+ p1) p2) (subseq turn (1+ p2)))))))
  ;; the stores, on a cabinet: without one, glass's first OPEN halts the core
  (unless (mount-ram-cabinet)
    (error "zero-gateway: no cabinet filesystem in this image (kiln's zero-cabinet)"))
  (unless (%install-ca-bundle)
    (error "zero-gateway: no CA bundle, so no relay's TLS certificate can be checked"))
  (%install-payload)
  ;; glass/nostr and the gateway read these when they LOADED, which for a core was build time
  (%set-by-name "GLASS" "*BOX-SECRET*" secret)
  (%set-by-name "GLASS" "*ENROLMENT-FILE*" "/glass/devices")
  (%set-by-name "GLASS" "*SEAT-KEY-FILE*" "/glass/seats")
  (%set-by-name "GLASS" "*LOGIN-CODE-FILE*" nil)
  (%set-by-name "WEBRTC-DATA" "*STATS-FILE*" "/tmp/glass-stats.sexp")
  ;; every stored offer is unwrapped before a fresh one is seen, at seconds each on a Zero
  (%set-by-name "WEBRTC-DATA" "*OFFER-BACKLOG*" 3)
  (when relays
    (%set-by-name "GLASS" "*NOSTR-RELAYS*" relays)
    (%set-by-name "WEBRTC-DATA" "*RELAYS*" relays))
  (%set-by-name "WEBRTC-DATA" "*BOX-SECRET*" secret)
  (%set-by-name "WEBRTC-DATA" "*GLASS-HOST*" "127.0.0.1")
  (%set-by-name "WEBRTC-DATA" "*GLASS-PORT*" rfb-port)
  (%set-by-name "WEBRTC-DATA" "*ADMISSION-PORT*" admission-port)
  (when login-url-base (%set-by-name "GLASS" "*LOGIN-URL-BASE*" login-url-base))
  ;; THE DESK, on loopback: kiln-zero's sockets RFB server (zero-rfbs.lisp), unless the caller
  ;; serves RFB-PORT some other way.  And the desk's idle time is the gateway's: the desk owns
  ;; the main thread, which is core 0's scheduler (modus net/bare-threads.lisp, CORE 0), so its
  ;; idle hook yields to the gateway's threads.
  (when (and rfb (find-package "KILN-ZERO-RFBS"))
    (%call "KILN-ZERO-RFBS" "RFBS-START" :port rfb-port))
  (%set-by-name "COMMON-LISP-USER" "*KZ-MAIN-NET*"
                (let ((y (symbol-function (intern "BT-YIELD" "MODUS-INT"))))
                  (lambda () (funcall y))))
  ;; identity, enrolments, admission on ADMISSION-PORT, the DM bot -- and the link to OWNER
  (%call "GLASS" "START-SESSION-NOSTR" :port admission-port)
  (bt:make-thread (lambda () (%call "WEBRTC-DATA" "START-NOSTR-GATEWAY"))
                  :name "nostr-gateway"))

;;; ---- a card that boots into it -------------------------------------------------------------
;;; `kiln zero --sd-image --nsec-file F --owner NPUB' writes the card's cmdline.txt -- bootargs, which
;;; modus reads with %CLI-GETENV -- and makes BOOT-MAIN the core's restart hook:
;;;   NSEC=nsec1...    the board's identity: its SSH key and the box's nostr key
;;;   OWNER=npub1...   who is sent the link, and may connect
;;;   TURN=turn:host:port,user,pass   (commas: a bootarg cannot hold a space)
;;;   RELAYS=wss://a,wss://b          optional
;;;   NET=qemu                        QEMU's usb-net instead of the hub's RTL8153

(defun %bootarg (name)
  (let ((v (ignore-errors (%call "MODUS-INT" "%CLI-GETENV" name))))
    (and (stringp v) (plusp (length v)) v)))

(defun %split-commas (s)
  (let ((out '()) (start 0))
    (loop for i = (position #\, s :start start)
          do (push (subseq s start i) out)
             (if i (setf start (1+ i)) (return)))
    (nreverse out)))

(defun boot-main ()
  "The card's restart hook: the network, the gateway (which DMs OWNER the link), then the desk --
   whose idle time is the gateway's.  Without NSEC and OWNER on the card it is the plain desk."
  (let ((nsec (%bootarg "NSEC")) (owner (%bootarg "OWNER")))
    (handler-case
        (when (and nsec owner)
          (if (equal (%bootarg "NET") "qemu")
              (net-up-qemu)
              (%call "KILN-ZERO-SSH" "NET-UP"))
          (let ((turn (%bootarg "TURN")) (relays (%bootarg "RELAYS")))
            (start :secret (%call "CL-NOSTR.UTIL" "BYTES->HEX"
                                  (%call "CL-NOSTR.BECH32" "NSEC-DECODE" nsec))
                   :owner owner
                   :turn (and turn (substitute #\Space #\, turn))
                   :relays (and relays (%split-commas relays)))))
      (error (e)
        (ignore-errors (format t "~&zero-gateway: not started: ~a~%" e) (finish-output)))))
  (%call "COMMON-LISP-USER" "KILN-ZERO-MAIN"))
