;;;; klog-test.lisp — offline checks for boot/klog.lisp.
;;;;
;;;;   sbcl --non-interactive --load test/klog-test.lisp   (quicklisp at ~/quicklisp)
;;;; --script swallows the output (and the exit flush), so it is not used here.
;;;;
;;;; No relay is needed.  What is checked:
;;;;   1. the baked npub, decoded and wrapped, is readable ONLY by its own nsec —
;;;;      the npub -> hex -> gift-wrap chain is the one thing a typo would break
;;;;      silently, because a wrap to the wrong key still builds fine;
;;;;   2. KLOG-EVENT returns at once even when no relay answers, and overflow is
;;;;      counted rather than blocking or growing the queue.

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

;;; 1. the wrap chain
(let* ((recipient (cl-nostr.keys:generate-keypair))
       (npub (cl-nostr.bech32:npub-encode
              (cl-nostr.util:hex->bytes (cl-nostr.keys:public-hex recipient))))
       (other (cl-nostr.keys:generate-keypair))
       (sender (cl-nostr.keys:generate-keypair))
       (line "1700000000 INFO log started; recipient"))
  (check "baked-style npub decodes to the recipient's hex key"
         (string= (cl-nostr.bech32:pubkey-hex npub)
                  (cl-nostr.keys:public-hex recipient)))
  (let* ((wrap (cl-nostr.nip59:build-giftwrap
                sender (cl-nostr.bech32:pubkey-hex npub) line)))
    (check "recipient reads the line back exactly"
           (multiple-value-bind (text who) (cl-nostr.nip59:unwrap-giftwrap
                                            (cl-nostr.keys:keypair-secret-key recipient) wrap)
             (and (string= text line)
                  (string= who (cl-nostr.keys:public-hex sender)))))
    (check "a different key cannot read it"
           (not (ignore-errors
                 (cl-nostr.nip59:unwrap-giftwrap
                  (cl-nostr.keys:keypair-secret-key other) wrap))))
    (check "the outer wrap does not name the sender"
           (not (search (cl-nostr.keys:public-hex sender)
                        (cl-nostr.event:event->json wrap))))))

;;; 2. non-blocking, bounded queue, with no relay that answers
(setf *klog-capacity* 4)
(check "klog-start refuses a malformed npub, and starts no thread"
       (and (not (ignore-errors
                  (klog-start :npub "npub1notvalid" :relays "ws://127.0.0.1:9")))
            (null *klog-thread*)))
(check "klog-start accepts a valid npub"
       (klog-start :npub (cl-nostr.bech32:npub-encode
                          (cl-nostr.util:hex->bytes
                           (cl-nostr.keys:public-hex (cl-nostr.keys:generate-keypair))))
                   :relays "ws://127.0.0.1:9"))
(let ((t0 (get-internal-real-time)))
  (dotimes (i 50) (klog-event "INFO" "line ~d" i))
  (let ((ms (/ (- (get-internal-real-time) t0) (/ internal-time-units-per-second 1000))))
    (check (format nil "50 events enqueued in under 1s (took ~,1f ms)" ms)
           (< ms 1000))))
(check "overflow is counted, queue stays bounded"
       (and (plusp *klog-dropped*) (<= *klog-queued* *klog-capacity*)))

(format t "~&~:[ALL PASS~;~d FAILED~]~%" (plusp *fails*) *fails*)
(finish-output)
(sb-ext:exit :code (if (plusp *fails*) 1 0) :abort t)
