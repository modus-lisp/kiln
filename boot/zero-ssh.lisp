;;;; zero-ssh.lisp — an SSH client on the bare-metal Pi Zero: conch over modus's own TCP.
;;;;
;;;; conch (the pure-CL SSH-2 client) talks through sb-bsd-sockets, and the board has no OS to
;;;; give it a socket.  It needs three things from a transport -- open a TCP connection, send
;;;; bytes, read exactly N bytes -- and the board image already has a TCP client for them:
;;;; net/ip.lisp's TCP-CONNECT / TCP-SEND / TCP-RECEIVE (one connection at a time, which is
;;;; what an SSH session is).  So this file replaces conch's three transport functions with
;;;; ones over that client, at run time: conch is not loaded yet when kiln-zero is (it comes
;;;; with --with=conch, after), and its own calls reach the replacements by name.
;;;;
;;;; There is no filesystem for ~/.ssh either: the identity is an Ed25519 keypair generated
;;;; here from the board's hardware RNG (natrium's DRBG), held in memory, and handed to conch
;;;; as bytes; the host key is trusted on first use and remembered for the session.
;;;;
;;;;   (kiln-zero-ssh:ssh-pubkey)                       ; the line for authorized_keys
;;;;   (kiln-zero-ssh:ssh-run "10.0.0.1" "uname -a" :user "modus")

(defpackage #:kiln-zero-ssh
  (:use #:cl)
  (:export #:ssh-install #:ssh-run #:ssh-pubkey #:net-up #:*ssh-identity*))
(in-package #:kiln-zero-ssh)

(defvar *ssh-identity* nil "(SECRET-32 PUBLIC-32), made on first use.")
(defvar *ssh-known* nil "Host-key blobs seen this session, by host: trust on first use.")
(defvar *rx* (make-array 65536 :element-type '(unsigned-byte 8)))
(defvar *rx-start* 0)
(defvar *rx-end* 0)
(defvar *usb-executor* nil
  "With threads (kiln zero --threads), the USB thread (kz-usb-start): every USB operation here
   runs on it, through BT-CALL, because only that thread may drive the host controller.")

(defun %on-usb (fn)
  "FN (no arguments) on the USB thread when there is one, else here."
  (if *usb-executor*
      (funcall (%kernel "BT-CALL") *usb-executor* fn)
      (funcall fn)))

(defun %sym (name pkg) (or (find-symbol name pkg) (error "kiln-zero-ssh: no ~a::~a" pkg name)))
(defun %kernel (name)
  ;; INTERN, not FIND-SYMBOL: a kernel function nobody has typed has no symbol yet, and the
  ;; symbol, once made, names the image's function by its name.
  (symbol-function (intern name "COMMON-LISP-USER")))

(defun %ip (host)
  "\"10.0.0.1\" as the big-endian integer net/ip.lisp takes."
  (let ((n 0) (start 0))
    (dotimes (k 4 n)
      (let ((end (or (position #\. host :start start) (length host))))
        (setf n (+ (* n 256) (parse-integer host :start start :end end))
              start (1+ end))))))

(defun %connect (host port)
  (setf *rx-start* 0 *rx-end* 0)
  (unless (eql 1 (let ((f (%kernel "TCP-CONNECT")) (ip (%ip host)))
                   (%on-usb (lambda () (funcall f ip port)))))
    (error "kiln-zero-ssh: TCP connect to ~a:~d failed" host port))
  (values :modus-tcp :modus-tcp))

(defun %send (conn bytes)
  (declare (ignore conn))
  ;; segments of at most 1024 bytes: well inside the MSS and the peer's window
  (let ((n (length bytes)) (send (%kernel "TCP-SEND")))
    (do ((off 0 (+ off 1024))) ((>= off n))
      (let* ((len (min 1024 (- n off)))
             (chunk (make-array len)))
        (dotimes (i len) (setf (aref chunk i) (aref bytes (+ off i))))
        (%on-usb (lambda () (funcall send chunk len) 0))))))

(defun %fill ()
  "Wait for the next in-order TCP segment and append its payload to *RX*."
  (let ((t0 (get-internal-real-time)) (recv (%kernel "TCP-RECEIVE")) (rxbuf (%kernel "E1000-RX-BUF")))
    (loop
      ;; ONE receive attempt per call: between calls the USB thread polls the keyboard and
      ;; mouse.  The segment stays in the NIC's buffer until the next receive, and only a
      ;; call makes one, so it is copied here, after the call.
      (let ((n (%on-usb (lambda () (funcall recv 2000)))))
        (when (> n 0)
          (let* ((buf (funcall rxbuf))
                 (hdr (ash (logand (cl-user::mem-ref (+ buf 46) :u8) #xF0) -2))
                 (data (+ buf 34 hdr)))
            (when (> (+ *rx-end* n) (length *rx*))   ; slide what is unread to the front
              (replace *rx* *rx* :start2 *rx-start* :end2 *rx-end*)
              (setf *rx-end* (- *rx-end* *rx-start*) *rx-start* 0))
            (dotimes (i n) (setf (aref *rx* (+ *rx-end* i)) (cl-user::mem-ref (+ data i) :u8)))
            (incf *rx-end* n)
            (return n))))
      (when (> (- (get-internal-real-time) t0) (* 30 internal-time-units-per-second))
        (error "kiln-zero-ssh: no data for 30 s")))))

(defun %read-exact (conn n)
  (declare (ignore conn))
  (loop while (< (- *rx-end* *rx-start*) n) do (%fill))
  (let ((out (make-array n :element-type '(unsigned-byte 8))))
    (replace out *rx* :start2 *rx-start* :end2 (+ *rx-start* n))
    (incf *rx-start* n)
    out))

;;; ---- the identity ------------------------------------------------------------------------
;;;
;;; NSEC=nsec1... on the kernel command line (cmdline.txt; `kiln zero --sd-image --nsec-file')
;;; gives the board a key that survives reboots: its 32 bytes are the Ed25519 seed.  (An nsec
;;; is a secp256k1 secret; Ed25519 hashes its seed with SHA-512 before use, so the two keys
;;; share no algebra.)  Without one, a fresh key from the hardware RNG each boot.

(defun %bech32-polymod (values)
  (let ((chk 1) (gen '(#x3b6a57b2 #x26508e6d #x1ea119fa #x3d4233dd #x2a1462b3)))
    (dolist (v values chk)
      (let ((top (ash chk -25)))
        (setf chk (logxor (ash (logand chk #x1ffffff) 5) v))
        (loop for g in gen for i from 0 when (logbitp i top) do (setf chk (logxor chk g)))))))

(defun %bech32-bytes (str)
  "The data bytes of a bech32 string (checksum checked), and its human-readable part."
  (let* ((s (string-downcase str))
         (sep (or (position #\1 s :from-end t) (error "kiln-zero-ssh: not bech32")))
         (hrp (subseq s 0 sep))
         (abc "qpzry9x8gf2tvdw0s3jn54khce6mua7l")
         (data (loop for c across (subseq s (1+ sep))
                     collect (or (position c abc) (error "kiln-zero-ssh: bad bech32 character ~a" c)))))
    (unless (= 1 (%bech32-polymod (append (loop for c across hrp collect (ash (char-code c) -5))
                                          (list 0)
                                          (loop for c across hrp collect (logand (char-code c) 31))
                                          data)))
      (error "kiln-zero-ssh: bech32 checksum mismatch"))
    (let ((acc 0) (bits 0) (out nil))
      (dolist (v (butlast data 6))
        (setf acc (logior (ash acc 5) v) bits (+ bits 5))
        (when (>= bits 8)
          (decf bits 8)
          (push (ldb (byte 8 bits) acc) out)
          (setf acc (ldb (byte bits 0) acc))))
      (values (coerce (nreverse out) '(simple-array (unsigned-byte 8) (*))) hrp))))

(defun %bootarg (name)
  (ignore-errors (funcall (%kernel "%CLI-GETENV") name)))

(defun %identity ()
  (or *ssh-identity*
      (setf *ssh-identity*
            (let ((nsec (%bootarg "NSEC")))
              (if (and (stringp nsec) (> (length nsec) 4))
                  (multiple-value-bind (sk hrp) (%bech32-bytes nsec)
                    (unless (and (string= hrp "nsec") (= (length sk) 32))
                      (error "kiln-zero-ssh: NSEC is not a 32-byte nsec"))
                    (list sk (funcall (%sym "ED25519-PUBLIC-KEY" "NATRIUM") sk)))
                  (multiple-value-list (funcall (%sym "ED25519-KEYPAIR" "NATRIUM"))))))))

(defun ssh-install ()
  "Point conch's transport at the board's TCP client and let it take a key as bytes."
  (let ((load-key (symbol-function (%sym "LOAD-PRIVATE-KEY" "CONCH"))))
    (setf (symbol-function (%sym "TCP-CONNECT" "CONCH")) #'%connect
          (symbol-function (%sym "SEND-RAW" "CONCH")) #'%send
          (symbol-function (%sym "READ-EXACT" "CONCH")) #'%read-exact
          (symbol-function (%sym "LOAD-PRIVATE-KEY" "CONCH"))
          (lambda (id) (if (consp id) (values (first id) (second id) "zero") (funcall load-key id)))))
  t)

(defun %base64 (bytes)
  (let ((abc "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        (out (make-string-output-stream)) (n (length bytes)))
    (do ((i 0 (+ i 3))) ((>= i n))
      (let ((b (+ (ash (aref bytes i) 16)
                  (if (< (+ i 1) n) (ash (aref bytes (+ i 1)) 8) 0)
                  (if (< (+ i 2) n) (aref bytes (+ i 2)) 0))))
        (write-char (char abc (ldb (byte 6 18) b)) out)
        (write-char (char abc (ldb (byte 6 12) b)) out)
        (write-char (if (< (+ i 1) n) (char abc (ldb (byte 6 6) b)) #\=) out)
        (write-char (if (< (+ i 2) n) (char abc (ldb (byte 6 0) b)) #\=) out)))
    (get-output-stream-string out)))

(defun ssh-pubkey ()
  "The board's public key as an authorized_keys line."
  (let* ((pub (second (%identity)))
         (blob (make-array (+ 4 11 4 32) :element-type '(unsigned-byte 8)))
         (p 0))
    (flet ((u32 (v) (dotimes (k 4) (setf (aref blob p) (ldb (byte 8 (* 8 (- 3 k))) v)) (incf p)))
           (raw (s) (loop for x across s do (setf (aref blob p) (if (characterp x) (char-code x) x)) (incf p))))
      (u32 11) (raw "ssh-ed25519") (u32 32) (raw pub))
    (format nil "ssh-ed25519 ~a modus-zero" (%base64 blob))))

(defun %verifier (host)
  (lambda (blob)
    (let ((seen (cdr (assoc host *ssh-known* :test #'string=))))
      (cond ((null seen) (push (cons host (copy-seq blob)) *ssh-known*))
            ((not (equalp seen blob)) (error "kiln-zero-ssh: ~a's host key CHANGED" host))))))

;;; ---- the network: the hub's own Ethernet, as CDC-ECM ------------------------------------
;;;
;;; The Zero's one USB port carries a hub, and the hub's built-in Ethernet is an RTL8153 on one
;;; of its high-speed ports.  On a card boot nothing has touched it, so it is brought up here as
;;; a standard CDC-ECM device (its configuration 2) and net/cdc-ether.lisp drives it -- no
;;; Realtek vendor init.  Three things the hub needed, each found on the board:
;;;  - every high-speed device gets its OWN address first: enabled but never addressed, they
;;;    all answer address 0 together and every control transfer collides;
;;;  - the RTL8153 drops off the bus after a reset and comes back about a second later, so it
;;;    is reset, waited for, and reset again before it is addressed;
;;;  - the first ARP after bring-up is often lost (a stale frame takes its one poll), so ARP
;;;    is retried.
;;; Static 10.0.0.2, gateway 10.0.0.1: the cable goes to the Pi 5 the board is wired to.

(defvar *net-up* nil)

(defun %k (name &rest args) (apply (%kernel name) args))

(defun %hub ()
  "The hub's address, as the HID layer recorded it (1 after modus's own bring-up)."
  (let ((h (%k "HID-GET" 0))) (if (and (integerp h) (< 0 h 128)) h 1)))

(defun %port-status (p) (%k "HID-PORT-STATUS" (%hub) p))

(defun %port-up (p a)
  "Reset hub port P and give the device behind it address A.  T on success."
  (%k "USB-CONTROL-TRANSFER" (%hub) #x23 3 4 p 0 0)     ; SET_FEATURE(PORT_RESET)
  (%k "DWC2-DELAY-MS" 100)
  (%k "HID-CLEAR-PORT-CHANGES" (%hub) p)
  (%k "DWC2-DELAY-MS" 20)
  (and (> (%k "USB-GET-DESCRIPTOR" 0 1 0 (%k "USB-DATA-BUF") 8) 0)
       (> (%k "USB-CONTROL-TRANSFER" 0 0 5 a 0 0 0) 0)))  ; SET_ADDRESS

(defun %ids (a)
  (let ((b (%k "USB-DATA-BUF")))
    (when (> (%k "USB-GET-DESCRIPTOR" a 1 0 b 18) 0)
      (list (%k "USB-DESC-U16" b 8) (%k "USB-DESC-U16" b 10)))))

(defun %wait-connect (p ms)
  (dotimes (i (floor ms 10) nil)
    (when (logbitp 0 (%port-status p)) (return t))
    (%k "DWC2-DELAY-MS" 10)))

(defun net-up (&key (ip #x0200000A) (gateway #x0100000A))
  "Bring the hub's Ethernet up as CDC-ECM with a static address.  Returns T or signals.
   With threads, all of it runs on the USB thread."
  (%on-usb (lambda () (%net-up-1 ip gateway)))
  (setf *net-up* t))

(defun %net-up-1 (ip gateway)
  (let ((hs nil) (nic nil))
    ;; every connected high-speed port (wPortStatus bit 10), disabled, then addressed one by one
    (loop for p from 1 to 7
          for st = (%port-status p)
          when (and (logbitp 0 st) (logbitp 10 st)) do (push p hs))
    (dolist (p hs) (%k "USB-CONTROL-TRANSFER" (%hub) #x23 1 1 p 0 0))   ; CLEAR_FEATURE(PORT_ENABLE)
    ;; Everything that answers and is not the RTL8153 keeps the address it gets here.  The
    ;; RTL8153 leaves the bus as soon as it is reset, so it is the port that fails this (or,
    ;; caught before it drops, the one that names itself).
    (let ((cands nil) (a 50))
      (dolist (p hs)
        (unless (and (%port-up p (+ 40 p)) (not (equal (%ids (+ 40 p)) '(#x0BDA #x8153))))
          (push p cands)))
      ;; each candidate, at its own address: reset it, let it drop off and come back, reset
      ;; and address it, ask who it is -- a few times, since how long it takes to drop varies
      (dolist (p cands)
        (unless nic
          (setf a (+ 50 p))
          (dotimes (try 4)
            (unless nic
              (%k "USB-CONTROL-TRANSFER" (%hub) #x23 3 4 p 0 0)
              (dotimes (i 150)                     ; up to 1.5 s for it to leave
                (unless (logbitp 0 (%port-status p)) (return))
                (%k "DWC2-DELAY-MS" 10))
              (%k "HID-CLEAR-PORT-CHANGES" (%hub) p)
              (when (and (%wait-connect p 4000)
                         (progn (%k "DWC2-DELAY-MS" 150) (%port-up p a))
                         (equal (%ids a) '(#x0BDA #x8153)))
                (setf nic p))))))
      (unless nic (error "kiln-zero-ssh: no RTL8153 on the hub (high-speed ports ~a, candidates ~a)" hs cands))
      (unless (and (> (%k "USB-CONTROL-TRANSFER" a #x00 9 2 0 0 0) 0)        ; config 2: CDC-ECM
                   (> (%k "USB-CONTROL-TRANSFER" a #x01 11 1 1 0 0) 0)       ; data iface, alt 1
                   (> (%k "USB-CONTROL-TRANSFER" a #x21 #x43 #x0E 0 0 0) 0)) ; packet filter
        (error "kiln-zero-ssh: the Ethernet refused CDC-ECM"))
      (let ((s (%k "E1000-STATE-BASE")))
        (%k "USB-SET-DEV-ADDR" a)
        (%k "USB-SET-BULK-IN-EP" 1) (%k "USB-SET-BULK-OUT-EP" 2)
        (%k "USB-SET-BULK-IN-MPS" 512) (%k "USB-SET-BULK-OUT-MPS" 512)
        (%k "USB-SET-BULK-IN-TOGGLE" 0) (%k "USB-SET-BULK-OUT-TOGGLE" 0)
        (%k "CDC-READ-MAC" s)
        (dolist (off '(#x10 #x14 #x44)) (setf (cl-user::mem-ref (+ s off) :u32) 0))
        (setf (cl-user::mem-ref (+ s #x18) :u32) ip
              (cl-user::mem-ref (+ s #x1C) :u32) gateway)
        (%k "USB-NETDEV-SET" 1)
        (%k "DWC2-START-BULK-IN" 1 a 1 (%k "CDC-RX-BUF-ADDR") 2048 512)))
    ;; Up to 10 s, by the clock: resetting the RTL8153 drops the link, and a gigabit link
    ;; takes ~3 s to come back.  Five tries of ARP-RESOLVE's own wait used to cover that by
    ;; accident; with faster code they are over in milliseconds, before the link is up.
    (let ((deadline (+ (get-internal-real-time) (* 10 internal-time-units-per-second))))
      (loop until (eql 1 (%k "ARP-RESOLVE"))
            do (when (> (get-internal-real-time) deadline)
                 (error "kiln-zero-ssh: no ARP reply from the gateway"))
               (%k "DWC2-DELAY-MS" 200)))
    t))

(defun ssh-run (host command &key (user "modus") (port 22))
  "Run COMMAND on HOST over SSH.  Returns (values STDOUT EXIT-STATUS STDERR)."
  (unless *net-up* (net-up))
  (ssh-install)
  (funcall (%sym "RUN" "CONCH") host command :user user :port port :identity (%identity)
           :host-key-verifier (%verifier host)))
