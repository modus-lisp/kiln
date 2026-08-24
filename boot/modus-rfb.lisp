;;;; modus-rfb.lisp — glass's RFB server, ON MODUS, on a port the caller named.
;;;;
;;;;   kiln modus-rfb 5999
;;;;
;;;; NOT the desktop.  This loads the ASDF system :glass and nothing above it —
;;;; packages, record, framebuffer, clipboard, perf, socket, rfb, zrle, over
;;;; cram's five — and hands GLASS:SERVE a framebuffer.  mcclim-glass is a much
;;;; larger system and modus has none of what it needs.
;;;;
;;;; LOADED BY PATH AND NOT BY QUICKLOAD, deliberately: modus's ASDF interface is
;;;; a naming layer over its own loader, and the point of an entry point is to be
;;;; explicit about exactly which thirteen files are being asked for.  The list is
;;;; checked against the .asd files by test/run-glass-load.sh in the modus tree,
;;;; which reads them with a real reader; if a component is added to :glass and
;;;; not added here, that test says so.
;;;;
;;;; NOTHING LISTENS UNTIL THE LAST FORM.  Loading these files opens no socket;
;;;; the bind happens once, in GLASS:SERVE, on the port the environment names, on
;;;; 127.0.0.1.
;;;;
;;;; WHAT IT NEEDS FROM MODUS, so a failure here is legible: sb-bsd-sockets and
;;;; sb-thread (glass is thread-per-client in each direction), which the hosted
;;;; x86-64 image has and no other modus target does.

(defvar *root* (or (sb-ext:posix-getenv "MODUS_ROOT") "/opt/modus-lisp"))

(defun kiln-load (system file)
  (load (format nil "~A/~A/src/~A.lisp" *root* system file)))

(dolist (f '("packages" "deflate" "inflate" "prefix" "lzw"))
  (kiln-load "cram" f))
(dolist (f '("packages" "record" "framebuffer" "clipboard" "perf" "socket"
             "rfb" "zrle"))
  (kiln-load "glass" f))

(let* ((s (sb-ext:posix-getenv "MODUS_RFB_PORT"))
       (port (and s (parse-integer s :junk-allowed t)))
       (w (or (and (sb-ext:posix-getenv "MODUS_RFB_W")
                   (parse-integer (sb-ext:posix-getenv "MODUS_RFB_W")
                                  :junk-allowed t))
              1024))
       (h (or (and (sb-ext:posix-getenv "MODUS_RFB_H")
                   (parse-integer (sb-ext:posix-getenv "MODUS_RFB_H")
                                  :junk-allowed t))
              768)))
  (unless (and port (> port 0) (< port 65536))
    (format *error-output* "~&modus-rfb: MODUS_RFB_PORT is not a port.~%")
    (sb-ext:exit :code 2))
  (let ((fb (funcall (find-symbol "MAKE-FRAMEBUFFER" "GLASS") w h)))
    (format t "~&modus-rfb: glass:serve on 127.0.0.1:~D (~Dx~D)~%" port w h)
    (finish-output)
    ;; :ADDRESS "127.0.0.1" IS NOT OPTIONAL AND IS NOT THE DEFAULT.  glass's
    ;; SERVE defaults to "0.0.0.0" — every interface — which is glass's call to
    ;; make and not this entry point's to inherit.  kiln publishes a port with
    ;; its own plumbing, one layer up, where it already is.
    (funcall (find-symbol "SERVE" "GLASS") fb port :address "127.0.0.1")))
