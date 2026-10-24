;;;; klog-live.lisp — end to end: boot/klog.lisp -> a real relay -> decrypted by the recipient.
;;;;
;;;;   sbcl --non-interactive --load test/klog-live.lisp [ws://host:port]
;;;;
;;;; Default relay is ws://127.0.0.1:7780 (a beacon started with
;;;;   ~/beacon/run.sh --port 7780 --dir /tmp/beacon-data).
;;;; The recipient key is generated here and never leaves this process, so reading the
;;;; lines back proves the relay carried the wrap and only the recipient could open it.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (ql:quickload :cl-nostr :silent t)))

(defvar *fails* 0)
(defmacro check (label form)
  `(let ((ok (handler-case ,form (error (e) (format t "   error: ~a~%" e) nil))))
     (format t "~:[FAIL~;PASS~] ~a~%" ok ,label)
     (unless ok (incf *fails*))))

(load (merge-pathnames "../boot/klog.lisp" *load-truename*))

(defvar *relay* (or (second sb-ext:*posix-argv*) "ws://127.0.0.1:7780"))
(defvar *tag* (format nil "live-~d" (random 1000000)))

(let* ((recipient (cl-nostr.keys:generate-keypair))
       (recipient-hex (cl-nostr.keys:public-hex recipient))
       (npub (cl-nostr.bech32:npub-encode (cl-nostr.util:hex->bytes recipient-hex)))
       (lines (loop for i from 1 to 3 collect (format nil "~a line ~d" *tag* i))))
  (check "klog-start connects and starts"
         (klog-start :npub npub :relays *relay*))
  (dolist (l lines) (klog-event "INFO" "~a" l))
  ;; the sender thread publishes one line at a time: wait for the queue to empty, then
  ;; allow the last publish its round trip
  (loop repeat 60 until (zerop *klog-queued*) do (sleep 0.5))
  (sleep 5)
  (let* ((pool (cl-nostr.pool:make-pool (list *relay*)))
         (wraps (cl-nostr.pool:fetch-events
                 pool (list (cl-nostr.filter:make-filter :kinds '(1059))) :timeout 8))
         (mine (remove-if-not (lambda (ev)
                                (member recipient-hex (cl-nostr.event:p-tags ev)
                                        :test #'string=))
                              wraps))
         (texts (loop for ev in mine
                      for text = (ignore-errors
                                  (cl-nostr.nip59:unwrap-giftwrap
                                   (cl-nostr.keys:keypair-secret-key recipient) ev))
                      when text collect text)))
    (format t "   relay returned ~d wrap(s) for the recipient; ~d decrypted~%"
            (length mine) (length texts))
    (check "every line arrived, decrypted by the recipient"
           (every (lambda (l) (find-if (lambda (tx) (search l tx)) texts))
                  lines))
    (check "the startup line arrived too"
           (find-if (lambda (tx) (search "log started" tx)) texts))
    (check "relay holds no plaintext: no line text in any stored event JSON"
           (notany (lambda (ev) (search *tag* (cl-nostr.event:event->json ev))) wraps))))

(format t "~&~:[ALL PASS~;~d FAILED~]~%" (plusp *fails*) *fails*)
(finish-output)
(sb-ext:exit :code (if (plusp *fails*) 1 0) :abort t)
