;;;; one.lisp — the desktop and its gateway in ONE Lisp image.
;;;;
;;;; They were two processes talking over loopback because that is what two
;;;; scripts are.  On bare metal there is no second process to have: modus boots
;;;; one image and everything lives in it, so the hosted arrangement should look
;;;; the same or the difference will keep being discovered the hard way.
;;;;
;;;; Neither file is forked to do it.  serve-desktop.lisp ends by blocking in
;;;; RUN-WM, and gateway.lisp ends by parking in (loop (sleep 5)) purely to keep
;;;; its own process alive — so the gateway is loaded on a thread, where its park
;;;; costs nothing, and the desktop keeps the main thread it wants.
;;;;
;;;; The gateway still dials the desktop's RFB port on 127.0.0.1.  That is a
;;;; loopback socket to ourselves now, which looks silly and is deliberate: RFB is
;;;; the seam between them, and collapsing it would mean rewriting the gateway
;;;; around glass's internals for no gain today.  One process, same protocol.

(require :asdf)


(defun kiln-env (name default) (or (sb-ext:posix-getenv name) default))

(defvar *root* (kiln-env "MODUS_ROOT" "/opt/modus-lisp"))
(defvar *display* (or (ignore-errors (parse-integer (kiln-env "GLASS_DISPLAY" "1"))) 1))

(defvar *desktop-file*
  (format nil "~a/glass/backend/inspect/serve-desktop.lisp" *root*))
(defvar *gateway-file*
  (format nil "~a/webrtc-data/demo/glass-webrtc/gateway.lisp" *root*))

(defvar *nostr-gateway-file*
  (format nil "~a/webrtc-data/demo/glass-webrtc/gateway-nostr.lisp" *root*))
(defvar *etc* (kiln-env "KILN_ETC" "/etc/kiln"))

(defun kiln-flag (name)
  "T iff NAME is set to something that is not 0 or empty.  `y' from the .config,
   `1' from a shell, both mean the same thing."
  (let ((v (kiln-env name nil)))
    (and v (not (string= v "")) (not (string= v "0")) (not (string= v "n")))))

(defun kiln-file-line (path)
  "The first non-blank line of PATH, or NIL.  How a secret gets in here: a file with
   a mode on it, not an environment variable inherited by every child of this image."
  (ignore-errors
   (with-open-file (in path :if-does-not-exist nil)
     (when in
       (loop for line = (read-line in nil nil)
             while line
             for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
             when (plusp (length trimmed)) return trimmed)))))

;;; ---- WHERE THE SCREEN IS -----------------------------------------------------
;;;
;;; Decided once, here, because everything in this image that reaches the desktop
;;; finds it the same way: GLASS_HOST, which is either a host beside GLASS_PORT or a
;;; socket file.  Both gateways read it, and glass derives the other three endpoints
;;; (audio, microphone, admission) from it by SOCKET-SIBLING — so this one value is
;;; the whole agreement, and there is nothing to keep in step by hand.
;;;
;;; A SOCKET FILE unless a port was actually asked for.  The gateway is a thread of
;;; the desktop's own process here, so a loopback port would buy nothing and cost
;;; the boundary: every uid on the box can open a loopback port, and a socket file
;;; at 0600 is owner-only with the kernel enforcing it.  KILN_VNC is the exception —
;;; publishing the screen to a VNC client means a port, because that is what a VNC
;;; client dials.
(defvar *rfb-socket*
  (unless (kiln-flag "KILN_VNC")
    ;; glass owns the runtime directory convention; ask it rather than rebuilding the
    ;; path here, which is the drift SOCKET-SIBLING's docstring is about.  The core
    ;; already has glass in it, so this is a lookup and not a build.
    (handler-case
        (progn
          (unless (find-package :glass)
            (handler-bind ((warning #'muffle-warning))
              (let ((*standard-output* (make-broadcast-stream)))
                (funcall (read-from-string "ql:quickload") :glass))))
          (funcall (read-from-string "glass:socket-path")
                   (format nil "seat-~d.rfb" *display*)))
      (error (e)
        (format *error-output* "~&@@ no socket for the screen (~a) — using a port~%" e)
        nil))))

;;; The gateways read these at load time.
(if *rfb-socket*
    (progn (sb-posix:setenv "GLASS_RFB_SOCKET" *rfb-socket* 1)      ; the desktop binds it
           (sb-posix:setenv "GLASS_HOST" (format nil "unix:~a" *rfb-socket*) 1))
    (progn (sb-posix:setenv "GLASS_HOST" "127.0.0.1" 1)
           (sb-posix:setenv "GLASS_PORT" (princ-to-string (+ 5900 *display*)) 1)))

;;; THE GATEWAY IS OPT-IN.  It is an HTTP server, and a service that listens is a thing
;;; to ask for rather than a thing a desktop brings with it.  In the container the engine
;;; decided what was published, so starting it always was nearly free; `kiln local' has no
;;; engine, so "always" meant a socket on every interface that nobody asked for.  Removing
;;; the isolation layer is not the same as publishing the ports, and this is the line where
;;; those two got conflated.  KILN_GATEWAY=1 (or `kiln local --gateway') brings it back.
(defvar *gateway-wanted*
  (let ((v (kiln-env "KILN_GATEWAY" "0"))) (not (or (string= v "0") (string= v "")))))

(defvar *gateway-thread*
  (when (and *gateway-wanted* (probe-file *gateway-file*))
    (sb-thread:make-thread
     (lambda ()
       (handler-case (load *gateway-file*)
         (error (e)
           ;; A desktop without a browser gateway is still a desktop; say so and
           ;; let the main thread carry on rather than taking the image down.
           (format *error-output* "~&@@ gateway failed to start: ~a~%" e)
           (finish-output *error-output*))))
     :name "kiln-gateway")))

;;; Wait for the acceptor before starting the desktop, so the startup banner is
;;; in a definite order and a gateway that died is reported before the screen
;;; comes up rather than somewhere in the middle of it.
(when *gateway-thread*
  (loop repeat 600
        for sym = (find-symbol "*ACCEPTOR*" :webrtc-data)
        until (and sym (boundp sym) (symbol-value sym))
        do (sleep 0.1)
        finally (let ((sym (find-symbol "*ACCEPTOR*" :webrtc-data)))
                  (format *error-output* "~&@@ one image: gateway ~:[NOT running~;up~], desktop starting~%"
                          (and sym (boundp sym) (symbol-value sym)))
                  (finish-output *error-output*))))

;;; ---- THE NOSTR GATEWAY -------------------------------------------------------
;;;
;;; For a box that is NOT the machine you are sitting at.  Signalling rides NIP-59
;;; gift wrap over relays, so reaching this desktop needs no forwarded port, no DNS
;;; record and no certificate — which is the whole point, since the hardware this is
;;; eventually for will sit behind whatever network it is plugged into.
;;;
;;; Opt-in (KILN_NOSTR), like every other listener in this file.  It needs an identity,
;;; and the identity comes from a FILE with a mode on it rather than an environment
;;; variable that every child of this image would inherit.
;;;
;;; THE SAME KEY GOES TO THE DESKTOP, and that is not a convenience.  The desktop owns
;;; admission now — the allowlist, the enrolment store, the login tokens — and the
;;; tokens are HMACed with this key.  Two identities in one image means every login link
;;; ever issued and every device already enrolled silently stops verifying.
(defvar *nostr-wanted* (kiln-flag "KILN_NOSTR"))

(defvar *nostr-thread*
  (when *nostr-wanted*
    (let ((sec (or (kiln-env "NOSTR_SEC" nil)
                   (kiln-file-line (format nil "~a/nostr-sec" *etc*)))))
      (cond
        ((not (probe-file *nostr-gateway-file*))
         (format *error-output* "~&@@ nostr: no gateway at ~a — not starting~%"
                 *nostr-gateway-file*)
         nil)
        ((not (and sec (= (length sec) 64)))
         ;; Say what to do rather than what went wrong.  A gateway with no identity
         ;; cannot sign, cannot be found, and cannot mint a login code, so there is
         ;; nothing useful to start in a degraded mode.
         (format *error-output* "~&@@ nostr: no identity — put 64 hex in ~a/nostr-sec~%~
                                   @@   openssl rand -hex 32 > ~:*~a/nostr-sec~%~
                                   @@   Not starting.~%" *etc*)
         nil)
        (t
         (sb-posix:setenv "NOSTR_SEC" sec 1)
         (sb-posix:setenv "GLASS_NOSTR_SEC" sec 1)
         ;; The allowlist is the DESKTOP's now.  NOSTR_ALLOW is what the config file
         ;; writes; GLASS_NOSTR_ALLOW is what glass reads.  glass does fall back to the
         ;; former, but only when it is exported into this process — so set it here
         ;; rather than depending on how the image was launched.
         (let ((allow (kiln-env "NOSTR_ALLOW" "")))
           (when (plusp (length allow))
             (sb-posix:setenv "GLASS_NOSTR_ALLOW" allow 1)))
         ;; THE CLIENT ITSELF, served down the channel the phone just opened.  Without
         ;; it the phone authenticates, gets a session, gets a screen — and is told the
         ;; box does not serve a client, which is a working connection that cannot draw
         ;; anything.  The file ships beside the gateway; if it is missing, say so here
         ;; rather than letting the phone discover it twelve seconds into a black page.
         (let ((payload (format nil "~a/webrtc-data/demo/glass-webrtc/payload.js" *root*)))
           (cond ((probe-file payload)
                  (sb-posix:setenv "PAYLOAD_CHANNEL" "1" 1)
                  (sb-posix:setenv "PAYLOAD_FILE" payload 1))
                 (t (format *error-output* "~&@@ nostr: no payload.js at ~a — the phone will ~
                                              connect and have nothing to draw with~%" payload))))
         (sb-thread:make-thread
          (lambda ()
            (handler-case (load *nostr-gateway-file*)
              (error (e)
                ;; Same rule as the web gateway: a desktop that cannot be reached from
                ;; away is still a desktop for whoever is at the screen.
                (format *error-output* "~&@@ nostr gateway failed to start: ~a~%" e)
                (finish-output *error-output*))))
          :name "kiln-nostr"))))))

(when *nostr-thread*
  (format *error-output* "~&@@ one image: nostr signalling on, screen at ~a~%"
          (kiln-env "GLASS_HOST" "?"))
  (finish-output *error-output*))

;;; The control plane, in this image too when the host mounted an identity for
;;; it.  Same reasoning as the gateway: on bare metal there is no second process
;;; to put it in.  KILN_SSHD_EMBEDDED stops sshd.lisp auto-starting (and, more to
;;; the point, stops its "refusing to start" path from calling QUIT on the whole
;;; image over a missing key file).
(let ((sshd (format nil "~a/boot/sshd.lisp" (kiln-env "KILN_HOME" "/kiln"))))
  ;; Opt-in, because "start an SSH server" should never be a side effect of
  ;; starting a desktop.  The container turns it on (it is the only way in);
  ;; `kiln local' leaves it off unless asked, since there you already have a
  ;; shell and the config file is just a file you can edit.
  (when (and (kiln-env "KILN_SSHD" nil)
             (not (string= (kiln-env "KILN_SSHD" "") "0"))
             (probe-file sshd)
             (probe-file (format nil "~a/host_ed25519" (kiln-env "KILN_ETC" "/etc/kiln"))))
    (sb-posix:setenv "KILN_SSHD_EMBEDDED" "1" 1)
    (handler-case
        (progn (load sshd)
               (sb-thread:make-thread
                (lambda ()
                  (handler-case (funcall (read-from-string "start"))
                    (error (e) (format *error-output* "~&@@ control plane stopped: ~a~%" e))))
                :name "kiln-sshd"))
      (error (e) (format *error-output* "~&@@ control plane failed to load: ~a~%" e)))))

(load *desktop-file*)
