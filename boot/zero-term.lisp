;;;; zero-term.lisp — the desk's Terminal as a real terminal: glass/term's character grid and VT
;;;; parser, with a Lisp listener edited by quill on one side and, after (ssh "host"), the remote
;;;; shell on the other.
;;;;
;;;; app.lisp's Terminal was a line listener: a string, Enter, lines of output.  Over SSH that
;;;; meant the remote got whole lines and its escape sequences arrived as text, so a shell's own
;;;; editing, colour and anything full-screen did not work.  Here the window IS a terminal:
;;;;
;;;;   LOCAL   keys go to a quill session (Emacs keys, kill ring, history, C-r, paren matching,
;;;;           multi-line forms -- Enter on an open parenthesis continues); an accepted form is
;;;;           evaluated on this thread as before (%KILN-TERMINAL-EVAL) and its output printed.
;;;;   REMOTE  keys go to the SSH channel byte for byte, the channel was opened with a pty
;;;;           (xterm-256color at the window's size), and what comes back is fed to the parser.
;;;;           ~. at the start of a line hangs up, as in ssh(1).
;;;;
;;;; quill is driven by events (START-LINE / FEED-LINE), not by its blocking reader: the window's
;;;; key handler must return, and evaluation must stay on the desk's thread.

(defvar *kiln-vt-keymap* nil "quill's keys with Enter continuing an open form (made once).")

(defun %kiln-vt-keymap ()
  (or *kiln-vt-keymap*
      (setf *kiln-vt-keymap*
            (let ((k (quill:make-keymap quill:*default-keymap*)))
              (quill:bind k :enter
                          (lambda (session)
                            (let ((ed (quill:session-buffer session)))
                              (if (%kiln-balanced-p (quill:editor-text ed))
                                  (quill::accept-line session)
                                  (quill:insert ed (string #\Newline))))))
              k))))

(defun %kiln-utf8 (string)
  (let ((out '()))
    (loop for ch across string for c = (char-code ch)
          do (cond ((< c #x80) (push c out))
                   ((< c #x800) (push (logior #xC0 (ash c -6)) out) (push (logior #x80 (logand c #x3F)) out))
                   ((< c #x10000) (push (logior #xE0 (ash c -12)) out)
                    (push (logior #x80 (logand (ash c -6) #x3F)) out) (push (logior #x80 (logand c #x3F)) out))
                   (t (push (logior #xF0 (ash c -18)) out) (push (logior #x80 (logand (ash c -12) #x3F)) out)
                      (push (logior #x80 (logand (ash c -6) #x3F)) out) (push (logior #x80 (logand c #x3F)) out))))
    (coerce (nreverse out) '(vector (unsigned-byte 8)))))

(defun %kiln-ssh-pty (conn chan cols rows)
  "Ask for a pseudo-terminal on CHAN, COLS x ROWS, xterm-256color, before the shell."
  (let ((w (funcall (%kiln-c "MAKE-WRITER"))))
    (funcall (%kiln-c "W-BYTE") w 98)                                  ; CHANNEL_REQUEST
    (funcall (%kiln-c "W-U32") w (funcall (%kiln-c "CHAN-REMOTE-ID") chan))
    (funcall (%kiln-c "W-STRING") w "pty-req")
    (funcall (%kiln-c "W-BOOL") w t)
    (funcall (%kiln-c "W-STRING") w "xterm-256color")
    (funcall (%kiln-c "W-U32") w cols) (funcall (%kiln-c "W-U32") w rows)
    (funcall (%kiln-c "W-U32") w 0) (funcall (%kiln-c "W-U32") w 0)
    (funcall (%kiln-c "W-STRING") w (string (code-char 0)))            ; modes: TTY_OP_END
    (funcall (%kiln-c "WRITE-PACKET") conn (funcall (%kiln-c "WRITER-BYTES") w)))
  (loop for pl = (funcall (%kiln-c "READ-PAYLOAD") conn) for msg = (aref pl 0)
        do (cond ((= msg 99) (return t))
                 ((= msg 100) (return nil))                            ; no pty: lines, then
                 (t (funcall (%kiln-c "CHAN-PROCESS") chan pl)))))

(defun %kiln-vt-terminal-app (fb)
  "The Terminal window (see the file's header).  The desk's app contract: (values on-key
   on-pointer tick copy-p close text-p)."
  (let* ((font (or *kiln-mono-font* (glass:default-font)))
         (tm nil) (session nil) (history (quill:make-history))
         (qo (make-string-output-stream))
         (remote nil) (inbox (list nil)) (line-start t) (tilde nil))
    (labels ((feed (string)                       ; text for the screen (LF as CR LF, as a tty)
               (loop for ch across string
                     do (when (char= ch #\Newline) (glass-term::feed-cp tm 13))
                        (glass-term::feed-cp tm (char-code ch))))
             (drain () (feed (get-output-stream-string qo)))
             (prompt ()
               (setf session (quill:start-line :prompt "> " :continuation "  " :history history
                                               :keymap (%kiln-vt-keymap) :output qo
                                               :width (glass-term::terminal-cols tm)))
               (drain))
             (take-over (conn chan host)
               (setf remote (list conn chan host) inbox (list nil) line-start t tilde nil)
               (feed (format nil "[connected to ~A -- ~~. at the start of a line ends it]~%" host))
               (let ((box inbox) (c chan))
                 ;; ON CORE 0, as app.lisp's reader: the inbox is the desk's object
                 (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (loop
                          (when (or (funcall (%kiln-c "CHAN-EOF") c) (funcall (%kiln-c "CHAN-CLOSED") c))
                            (return))
                          (funcall (%kiln-c "CHAN-PUMP") c)
                          (let ((n (funcall (%kiln-c "CHAN-AVAIL") c)))
                            (when (plusp n)
                              (push (funcall (%kiln-c "CHAN-READ-EXACT") c n) (car box)))))
                      (error () nil))
                    (push :eof (car box)))
                  :name "ssh reader")))
             (hang-up (why)
               (ignore-errors (funcall (%kiln-c "DISCONNECT") (first remote)))
               (feed (format nil "~%[~A]~%" why))
               (setf remote nil)
               (prompt))
             (take-remote ()
               (dolist (x (nreverse (shiftf (car inbox) nil)))
                 (if (eq x :eof)
                     (progn (hang-up (format nil "~A closed the connection" (third remote)))
                            (return))
                     (loop for b across x do (glass-term::feed-byte tm b)))))
             (send-remote (string)
               ;; ~. at the start of a line hangs up; ~ then anything else sends both
               (let ((out (make-string-output-stream)))
                 (loop for ch across string
                       do (cond (tilde
                                 (setf tilde nil)
                                 (when (char= ch #\.) (return-from send-remote (hang-up "disconnected")))
                                 (write-char #\~ out) (write-char ch out))
                                ((and line-start (char= ch #\~)) (setf tilde t))
                                (t (write-char ch out)))
                          (unless tilde (setf line-start (member ch '(#\Return #\Newline)))))
                 (let ((s (get-output-stream-string out)))
                   (when (plusp (length s))
                     (funcall (%kiln-c "CHAN-WRITE") (second remote) (%kiln-utf8 s))))))
             (accept (text)
               (let ((*kiln-terminal-takeover* #'take-over)
                     (*kiln-terminal-pty* (list (glass-term::terminal-cols tm) (glass-term::terminal-rows tm))))
                 (dolist (l (handler-case (%kiln-terminal-eval text)
                              (error (c) (list (format nil "(:ERROR ~S)" (princ-to-string c))))))
                   (feed l) (feed (string #\Newline))))
               (unless remote (prompt)))
             (local-keys (string)
               (multiple-value-bind (text status) (quill:feed-line session (%kiln-utf8 string))
                 (drain)
                 (case status
                   (:ok (accept text))
                   ((:interrupt :eof) (prompt)))))
             (sink (string)
               (if remote
                   (handler-case (send-remote string)
                     (error (c) (hang-up (princ-to-string c))))
                   (local-keys string))))
      (setf tm (glass-term:make-terminal :cols 20 :rows 4 :ppem 14 :font font :nerd-font nil
                                         :pty #'sink))
      ;; the grid sized to the window, drawn straight into the window's framebuffer
      (glass-term:resize-terminal-px tm (glass:fb-width fb) (glass:fb-height fb))
      (setf (glass-term:terminal-fb tm) fb
            (glass-term::terminal-drawn-chars tm) nil)
      (glass:fb-fill fb (glass-term::pal 0))
      (feed (format nil "Lisp, edited with quill: Emacs keys, Up and C-r for history.~%~
                         (ssh \"user@host\") makes this window that host's terminal.~%"))
      (prompt)
      (values (lambda (down ks) (glass-term:on-key tm down ks))
              nil
              (lambda ()
                (when remote (take-remote))
                (glass-term::render tm)
                (glass-term:terminal-take-dirty tm))
              nil
              (lambda () (when remote (ignore-errors (funcall (%kiln-c "DISCONNECT") (first remote)))))
              t))))
