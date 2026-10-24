;;;; klog.lisp — kiln's event log, delivered as private nostr DMs.
;;;;
;;;; WHO RECEIVES.  *KLOG-NPUB* is the recipient.  It defaults to the npub kiln ships
;;;; (the same one one.lisp defaults NSITE_NPUB to, for login links), and KILN_LOG_NPUB
;;;; overrides it when this file loads.  A recipient is a public key, so
;;;; the default is not a secret; what is private is who can READ the log, and that
;;;; is whoever holds the matching nsec.
;;;;
;;;; WHO SENDS.  A keypair minted when the logger starts and never written anywhere.
;;;; It is deliberately NOT the session identity: a log line should not be linkable
;;;; to the desktop's npub by a relay.  Restarting the logger starts a fresh sender,
;;;; which is the point.
;;;;
;;;; HOW.  Each line is wrapped per NIP-59 (rumor -> seal -> gift wrap, kind 1059),
;;;; so a relay sees an ephemeral author talking to a recipient and nothing else, and
;;;; published to NOSTR_RELAYS.  KLOG-EVENT only ENQUEUES and returns: the caller
;;;; never waits on a relay, and an outage costs log lines, not the desktop.  The
;;;; queue is bounded; lines that do not fit are counted and reported in a line of
;;;; their own once there is room.
;;;;
;;;; WHAT IT IS NOT.  Not durable: a line still queued at exit is lost, and a line
;;;; that no relay accepted is not retried beyond the pool's own reconnects.  Anything
;;;; that must survive belongs in a file.

(require :asdf)

(defun klog-env (name default) (or (sb-ext:posix-getenv name) default))

(defparameter *klog-default-npub*
  "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc"
  "The npub kiln ships as the default recipient.  Kept in step with the NSITE_NPUB
   default in one.lisp and bin/kiln; if one of them moves, the others move with it.")

(defvar *klog-npub* (klog-env "KILN_LOG_NPUB" *klog-default-npub*))

(defvar *klog-relays*
  (klog-env "NOSTR_RELAYS" "wss://relay.damus.io,wss://nos.lol,wss://relay.primal.net"))

(defparameter *klog-capacity* 256
  "Lines the queue holds.  Past this, new lines are dropped and counted.")

(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :cl-nostr)))

(defvar *klog-lock* (sb-thread:make-mutex :name "klog"))
(defvar *klog-wake* (sb-thread:make-waitqueue))
(defvar *klog-queue* '())
(defvar *klog-queued* 0)
(defvar *klog-dropped* 0)
(defvar *klog-thread* nil)

(defun klog-unix-time ()
  (- (get-universal-time) 2208988800))

(defun klog-event (level fmt &rest args)
  "Queue one log line: LEVEL is a short tag such as INFO or WARN, FMT and ARGS are
   FORMAT's.  Returns NIL at once and never signals: a logger that can take the
   caller down is worse than no logger.  Does nothing unless KLOG-START has run."
  (when *klog-thread*
    (ignore-errors
     (let ((line (format nil "~d ~a ~?" (klog-unix-time) level fmt args)))
       (sb-thread:with-mutex (*klog-lock*)
         (cond ((>= *klog-queued* *klog-capacity*)
                (incf *klog-dropped*))
               (t
                (setf *klog-queue* (nconc *klog-queue* (list line)))
                (incf *klog-queued*)
                (sb-thread:condition-notify *klog-wake*))))))
    nil))

(defun klog--next ()
  "Block until a line is queued; return it, plus how many lines were dropped since the
   last one was taken (so the drop count reaches the recipient in order)."
  (sb-thread:with-mutex (*klog-lock*)
    (loop while (null *klog-queue*)
          do (sb-thread:condition-wait *klog-wake* *klog-lock*))
    (let ((dropped *klog-dropped*))
      (setf *klog-dropped* 0)
      (decf *klog-queued*)
      (values (pop *klog-queue*) dropped))))

(defun klog--send (pool sender recipient line)
  "Wrap LINE for RECIPIENT and publish it.  Returns T if some relay accepted it."
  (let* ((event (cl-nostr.nip59:build-giftwrap sender recipient line))
         (acks (cl-nostr.pool:pool-publish-sync pool event)))
    (and (cl-nostr.pool:acks-accepted acks) t)))

(defun klog--run (recipient sender relays)
  "The sender thread.  Owns the pool, so nothing else touches a relay socket.  Every
   iteration is guarded: one bad line or one dead relay must not end the logger."
  (let ((pool (cl-nostr.pool:make-pool relays)))
    (loop
      (multiple-value-bind (line dropped) (klog--next)
        (handler-case
            (progn
              (when (plusp dropped)
                (klog--send pool sender recipient
                            (format nil "~d WARN klog dropped ~d line~:p (queue full)"
                                    (klog-unix-time) dropped)))
              (unless (klog--send pool sender recipient line)
                (format *error-output* "~&@@ klog: no relay accepted a line~%")
                (finish-output *error-output*)))
          (error (e)
            (format *error-output* "~&@@ klog: send failed: ~a~%" e)
            (finish-output *error-output*)))))))

(defun klog-start (&key (npub *klog-npub*) (relays *klog-relays*))
  "Start the sender thread for NPUB.  Signals if NPUB is not a valid npub or hex key:
   the caller decides whether that is fatal, and a logger that starts silently
   pointed at nowhere is the one outcome not to allow."
  (unless *klog-thread*
    (let* ((recipient (cl-nostr.bech32:pubkey-hex npub))
           (sender (cl-nostr.keys:generate-keypair))
           (urls (loop with start = 0
                       for comma = (position #\, relays :start start)
                       for url = (string-trim " " (subseq relays start comma))
                       unless (string= url "") collect url
                       while comma
                       do (setf start (1+ comma)))))
      (setf *klog-thread*
            (sb-thread:make-thread (lambda () (klog--run recipient sender urls))
                                   :name "kiln-klog"))
      (klog-event "INFO" "log started; recipient ~a" (subseq recipient 0 16))
      t)))
