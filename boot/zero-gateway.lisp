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
  (:export #:start #:setenv #:getenv #:*env* #:mount-ram-cabinet #:net-up-qemu))
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
  ;; a KERNEL function (CL-USER) has no symbol until somebody types its name: INTERN it there,
  ;; and the symbol names the image's function (kiln-zero-ssh's %KERNEL)
  (let ((s (if (string= pkg "COMMON-LISP-USER")
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
  (let ((cab (find-symbol "*CABFS*" "COMMON-LISP-USER")))
    (cond ((null cab) nil)
          ((symbol-value cab) t)
          (t (%call "COMMON-LISP-USER" "CABINET-MOUNT-DEVICE"
                    (%call "COMMON-LISP-USER" "CABINET-RAW-DISK" base bytes) :format t)
             (dolist (d '("/glass" "/tmp"))
               (%call "CABINET" "MAKE-DIRECTORIES" (symbol-value cab) d))
             t))))

;;; THE NETWORK UNDER QEMU.  NET-UP (kiln-zero-ssh) finds the hub's RTL8153 behind the Zero's hub;
;;; QEMU raspi3b's usb-net is a plain CDC-ECM device on the root hub, which the kernel's own probe
;;; binds.  The HID scan is switched off first: it re-addresses ports, and QEMU aborts on a transfer
;;; to an address with no device behind it.  Slirp: -netdev user,net=10.0.0.0/24,host=10.0.0.1,dns=10.0.0.3
(defun net-up-qemu (&key (ip #x0200000A) (gateway #x0100000A) (dns #x0A000003))
  (%call "COMMON-LISP-USER" "HID-PUT" 0 0)
  (dotimes (p 8) (%call "COMMON-LISP-USER" "HID-RESERVE-PORT" p))
  (unless (eql 1 (%call "COMMON-LISP-USER" "E1000-PROBE"))
    (error "zero-gateway: no USB NIC"))
  (let ((s (%call "COMMON-LISP-USER" "E1000-STATE-BASE")))
    (%call "COMMON-LISP-USER" "CDC-READ-MAC" s)
    (setf (cl-user::mem-ref (+ s #x18) :u32) ip
          (cl-user::mem-ref (+ s #x1C) :u32) gateway))
  (unless (dotimes (i 50)
            (when (eql 1 (%call "COMMON-LISP-USER" "ARP-RESOLVE")) (return t))
            (%call "COMMON-LISP-USER" "DWC2-DELAY-MS" 100))
    (error "zero-gateway: no ARP reply from the gateway"))
  (%set-by-name "KILN-ZERO-SSH" "*NET-UP*" t)
  (%set-by-name "COMMON-LISP-USER" "*BARE-DNS-SERVERS*" (list dns))
  t)

(defun start (&key secret owner relays turn (rfb-port 5900) (admission-port 5915)
                   login-url-base)
  "Serve this board's desk to OWNER's phone: identity and admission (glass/nostr, which DMs OWNER
   the login link), then the gateway on a thread of its own.  Returns the gateway thread."
  (unless (and (stringp secret) (= (length secret) 64))
    (error "zero-gateway: SECRET must be the box's 64-hex nostr secret"))
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
        (setenv "TURN_SERVER" (subseq turn 0 p1))
        (setenv "TURN_USER" (subseq turn (1+ p1) p2))
        (setenv "TURN_PASS" (subseq turn (1+ p2)))
        (%set-by-name "GLASS" "*TURN-ICE*" turn))))
  ;; the stores, on a cabinet: without one, glass's first OPEN halts the core
  (unless (mount-ram-cabinet)
    (error "zero-gateway: no cabinet filesystem in this image (kiln's zero-cabinet)"))
  ;; glass/nostr and the gateway read these when they LOADED, which for a core was build time
  (%set-by-name "GLASS" "*BOX-SECRET*" secret)
  (%set-by-name "GLASS" "*ENROLMENT-FILE*" "/glass/devices")
  (%set-by-name "GLASS" "*SEAT-KEY-FILE*" "/glass/seats")
  (%set-by-name "GLASS" "*LOGIN-CODE-FILE*" nil)
  (%set-by-name "WEBRTC-DATA" "*STATS-FILE*" "/tmp/glass-stats.sexp")
  (when relays
    (%set-by-name "GLASS" "*NOSTR-RELAYS*" relays)
    (%set-by-name "WEBRTC-DATA" "*RELAYS*" relays))
  (%set-by-name "WEBRTC-DATA" "*BOX-SECRET*" secret)
  (%set-by-name "WEBRTC-DATA" "*GLASS-HOST*" "127.0.0.1")
  (%set-by-name "WEBRTC-DATA" "*GLASS-PORT*" rfb-port)
  (%set-by-name "WEBRTC-DATA" "*ADMISSION-PORT*" admission-port)
  (when login-url-base (%set-by-name "GLASS" "*LOGIN-URL-BASE*" login-url-base))
  ;; identity, enrolments, admission on ADMISSION-PORT, the DM bot -- and the link to OWNER
  (%call "GLASS" "START-SESSION-NOSTR" :port admission-port)
  (bt:make-thread (lambda () (%call "WEBRTC-DATA" "START-NOSTR-GATEWAY"))
                  :name "nostr-gateway"))
