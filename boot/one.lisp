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

;;; The gateway reads these at load time.
(sb-posix:setenv "GLASS_HOST" "127.0.0.1" 1)
(sb-posix:setenv "GLASS_PORT" (princ-to-string (+ 5900 *display*)) 1)

(defvar *gateway-thread*
  (when (probe-file *gateway-file*)
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
