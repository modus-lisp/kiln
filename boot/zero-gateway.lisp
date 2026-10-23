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
  (:export #:start #:setenv #:getenv #:*env*))
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
  (let ((s (and (find-package pkg) (find-symbol name pkg))))
    (unless (and s (fboundp s)) (error "zero-gateway: ~a::~a is not in this image" pkg name))
    (apply (symbol-function s) args)))

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
  ;; the gateway read these when it LOADED, which for a core was build time
  (%set-by-name "WEBRTC-DATA" "*BOX-SECRET*" secret)
  (%set-by-name "WEBRTC-DATA" "*GLASS-HOST*" "127.0.0.1")
  (%set-by-name "WEBRTC-DATA" "*GLASS-PORT*" rfb-port)
  (%set-by-name "WEBRTC-DATA" "*ADMISSION-PORT*" admission-port)
  (when login-url-base (%set-by-name "GLASS" "*LOGIN-URL-BASE*" login-url-base))
  ;; identity, enrolments, admission on ADMISSION-PORT, the DM bot -- and the link to OWNER
  (%call "GLASS" "START-SESSION-NOSTR" :port admission-port)
  (bt:make-thread (lambda () (%call "WEBRTC-DATA" "START-NOSTR-GATEWAY"))
                  :name "nostr-gateway"))
