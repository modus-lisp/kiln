;;;; app.lisp — the phone app kiln builds: a glass desk on the phone's own screen.
;;;;
;;;; Shared by `kiln ios' (boot/ios.lisp) and `kiln android' (boot/android.lisp),
;;;; which each define %KILN-SYS -- the platform's way to the screen, touch,
;;;; keyboard and speaker -- and an entry point that calls KILN-APP-MAIN.  Loaded
;;;; into the world the build snapshots (boot/ios-world.lisp), so it is native code
;;;; by the time the phone runs it.  The calls, by number (iOS: modus's
;;;; host/ios/modus-ui.m; Android: modus's host/android/modus-launcher.c):
;;;;   1001 size/scale  1002 fill  1003 present  1004 touch/key  1005 blit
;;;;   1006 keyboard  1010 speaker open  1011 speaker write  1012 samples queued
;;;;
;;;; In CL-USER on purpose: it calls modus internals (%GC-SAFE-BLOCK-6,
;;;; %GC-WORD-OF, %CLI-COLLECT-ARGV), which a script names unqualified.

(defvar *kiln-bundle-dir* nil
  "Overrides %KILN-BUNDLE-DIR: a platform with no --core argument says where its bundle is
   (the Zero: \"/\", the root of the cabinet it mounts).")

(defun %kiln-bundle-dir ()
  "The app bundle: the directory of the file after --core (the shim resolved
   @kiln.core to a path beside the executable)."
  (when *kiln-bundle-dir* (return-from %kiln-bundle-dir *kiln-bundle-dir*))
  (let ((args (and (fboundp 'modus-int::%cli-collect-argv) (modus-int::%cli-collect-argv))))
    (loop for (a b) on args
          when (and (stringp a) (string= a "--core") (stringp b))
            do (return (directory-namestring b)))))

(defun %kiln-px-bytes (px)
  "Bytes a pixel in glass pixel vector PX: 4 where (unsigned-byte 32) vectors are packed
   (subtag #x17), else 8, a tagged word."
  (if (eql (modus-int::obj-subtag px) #x17) 4 8))

(defun %kiln-blit (fb x y)
  "Copy glass framebuffer FB to the screen at (X, Y): pseudo-syscall 1005
   reads its pixel vector in place (element 0 is the vector's word + 7)."
  (let* ((px (glass::fb-pixels fb))
         (addr (+ (modus-int::%gc-word-of px (modus-int::%conv-addr #x100050A0)) 7)))
    (%kiln-sys 1005 addr (+ (glass::fb-width fb) (* (glass::fb-height fb) 65536))
               (+ x (* y 65536)) 0 (%kiln-px-bytes px))))

;;; THE SPEAKER.  glass's mixer normally runs its own 20 ms clock thread, and on modus that
;;; thread's frames cannot be stored into the shared mix (the store guard).  So here the MAIN
;;; loop is the clock: after each paint it tops the device's queue up to a cushion, one
;;; MIXER-TICK and one sink frame at a time.  The device -- an AudioQueue in the shim,
;;; pseudo-syscalls 1010-1012 -- keeps the real time and plays silence if the loop is late.
(defconstant +kiln-rate+ 48000)
(defparameter *kiln-cushion* 7200 "Samples to keep queued: 150 ms.")

(defun %kiln-audio-write (frame)
  (%kiln-sys 1011 (+ (modus-int::%gc-word-of frame (modus-int::%conv-addr #x100050A0)) 7) (length frame) 0))

(defun %kiln-pump-audio (mixer sink)
  "Mix and queue until the device holds *KILN-CUSHION* samples; at most a few ticks a call,
   so a long pause costs one cushion's catching-up and not a stall of the picture."
  (dotimes (i 12)
    (when (>= (%kiln-sys 1012 0 0 0) *kiln-cushion*) (return))
    (glass:mixer-tick mixer)
    (let ((f (glass:sink-next-frame sink)))
      (when f (%kiln-audio-write f)))))

(defun %kiln-clock-app (fb)
  "A second window for the desk: the time, redrawn once a second."
  (let ((last -1))
    (values nil nil
            (lambda ()
              (let ((now (get-universal-time)))
                (when (/= now last)
                  (setf last now)
                  (multiple-value-bind (s m h) (decode-universal-time now)
                    (glass:fb-fill fb #x10141a)
                    (glass:fb-text fb 16 20 (format nil "~2,'0d:~2,'0d:~2,'0d" h m s)
                                   :size 40 :color #xe6ebf2)
                    (glass:fb-text fb 16 80 "modus on the phone" :size 13 :color #x8b949e))
                  t))))))

(defun %kiln-keysym-char (ks)
  "The character an X11 KEYSYM types, or NIL."
  (cond ((= ks #xff0d) #\Newline)
        ((= ks #xff09) #\Space)
        ((<= #x20 ks #xff) (code-char ks))
        ((<= #x1000000 ks #x110ffff) (code-char (- ks #x1000000)))))

(defun %kiln-wrap (line width size font)
  "LINE broken into rows no wider than WIDTH at SIZE in FONT: at spaces, and inside a word only
   when the word alone is wider than a row."
  (let ((rows '()) (row ""))
    (flet ((fits (s) (<= (glass:text-width s :size size :font font) width)))
      (dolist (word (let ((acc '()) (start 0))          ; split, keeping each word's trailing space
                      (loop for k from 0 below (length line)
                            when (char= (char line k) #\Space)
                              do (push (subseq line start (1+ k)) acc) (setf start (1+ k)))
                      (push (subseq line start) acc)
                      (nreverse acc)))
        (cond ((fits (concatenate 'string row (string-right-trim " " word)))
               (setf row (concatenate 'string row word)))
              (t
               (when (plusp (length row)) (push row rows))
               (setf row "")
               ;; a word longer than a row: as many characters as fit, then the rest
               (loop for ch across word
                     do (if (fits (concatenate 'string row (string ch)))
                            (setf row (concatenate 'string row (string ch)))
                            (progn (push row rows) (setf row (string ch))))))))
      (push row rows)
      (nreverse rows))))

(defun %kiln-notes-app (fb)
  "Somewhere to type, looking like the phone's own notes: 17-point text on white, the first line
   a bold title, words wrapped whole, a thin gold caret.  The caret goes where you tap (and follows
   a drag), typing and Backspace work at it, a hardware keyboard's arrows move it, and the view
   scrolls to keep it in sight."
  (let ((lines (vector "")) (cl 0) (cc 0) (top-row 0) (dirty t)
        (body (glass:default-font)) (bold (glass:default-font t))
        (size 17) (lh 23) (tsize 22) (tlh 30) (margin 16) (top 14)
        (ink #x1c1c1e) (paper #xffffff) (caret #xe0a800)
        (layout nil))                     ; the visual rows, rebuilt when the text changes
    (labels ((style (li) (if (zerop li) (values bold tsize tlh) (values body size lh)))
             (rows ()
               ;; #((line start text font size height) ...): every visual row in order; a line's
               ;; rows partition it exactly, so START is the column its first character is at
               (or layout
                   (setf layout
                         (let ((w (- (glass:fb-width fb) (* 2 margin))) (out '()))
                           (dotimes (li (length lines) (coerce (nreverse out) 'vector))
                             (multiple-value-bind (font sz h) (style li)
                               (let ((start 0))
                                 (dolist (r (%kiln-wrap (aref lines li) w sz font))
                                   (push (list li start r font sz h) out)
                                   (incf start (length r))))))))))
             (changed () (setf layout nil dirty t))
             (caret-row ()
               ;; the row holding the caret: the last row of its line that starts at or before it
               (let ((rs (rows)) (best 0))
                 (dotimes (k (length rs) best)
                   (destructuring-bind (li start &rest _) (aref rs k)
                     (declare (ignore _))
                     (when (and (= li cl) (<= start cc)) (setf best k))))))
             (row-x (row col)
               ;; the x of column COL of ROW (COL relative to the line)
               (destructuring-bind (li start text font sz h) row
                 (declare (ignore li h))
                 (+ margin (glass:text-width (subseq text 0 (max 0 (min (length text) (- col start))))
                                             :size sz :font font))))
             (col-at (row x)
               ;; the column of ROW nearest the x coordinate X: the closest character boundary
               (destructuring-bind (li start text font sz h) row
                 (declare (ignore li h))
                 (let ((best 0) (bestd most-positive-fixnum) (w 0)
                       ;; a wrapped row's trailing space belongs before the next row, not after
                       (n (if (and (plusp (length text)) (char= (char text (1- (length text))) #\Space))
                              (1- (length text)) (length text))))
                   (loop for k from 0 to n
                         do (let ((d (abs (- (+ margin w) x))))
                              (when (< d bestd) (setf best k bestd d)))
                            (when (< k n)
                              (incf w (glass:text-width (string (char text k)) :size sz :font font))))
                   (+ start best))))
             (place (k x)
               ;; the caret onto visual row K at x X
               (let ((r (aref (rows) k))) (setf cl (first r) cc (col-at r x) dirty t)))
             (visible-count (from)
               (let ((room (- (glass:fb-height fb) top margin)) (used 0) (n 0) (rs (rows)))
                 (loop for k from from below (length rs)
                       do (incf used (sixth (aref rs k)))
                          (when (> used room) (return))
                          (incf n))
                 (max 1 n)))
             (scroll-to-caret ()
               (let ((k (caret-row)))
                 (when (< k top-row) (setf top-row k))
                 (loop while (>= k (+ top-row (visible-count top-row))) do (incf top-row))))
             (redraw ()
               (scroll-to-caret)
               (glass:fb-fill fb paper)
               (let ((rs (rows)) (ck (caret-row)) (y top))
                 (loop for k from top-row below (min (length rs) (+ top-row (visible-count top-row)))
                       do (destructuring-bind (li start text font sz h) (aref rs k)
                            (declare (ignore li start))
                            (glass:fb-text fb margin (+ y (floor (- h (* 1.2 sz)) 2)) text
                                           :size sz :color ink :font font)
                            (when (= k ck)
                              (glass:fb-rect fb (1+ (row-x (aref rs k) cc))
                                             (+ y (floor (- h (* 1.25 sz)) 2)) 2 (round (* 1.25 sz)) caret))
                            (incf y h)))))
             (row-at-y (py)
               ;; the visual row at local y PY, counting from the first shown; past the end, the last
               (let ((rs (rows)) (y top))
                 (loop for k from top-row below (length rs)
                       do (incf y (sixth (aref rs k)))
                          (when (< py y) (return-from row-at-y k)))
                 (1- (length rs))))
             (edit (ks)
               (let* ((line (aref lines cl)) (ch (%kiln-keysym-char ks)))
                 (cond
                   ((= ks #xff08)                                  ; BackSpace
                    (cond ((plusp cc)
                           (setf (aref lines cl) (concatenate 'string (subseq line 0 (1- cc)) (subseq line cc)))
                           (decf cc))
                          ((plusp cl)                              ; join with the line above
                           (let ((prev (aref lines (1- cl))))
                             (setf (aref lines (1- cl)) (concatenate 'string prev line)
                                   lines (concatenate 'vector (subseq lines 0 cl) (subseq lines (1+ cl))))
                             (decf cl) (setf cc (length prev))))))
                   ((= ks #xff51)                                  ; Left
                    (cond ((plusp cc) (decf cc))
                          ((plusp cl) (decf cl) (setf cc (length (aref lines cl))))))
                   ((= ks #xff53)                                  ; Right
                    (cond ((< cc (length line)) (incf cc))
                          ((< cl (1- (length lines))) (incf cl) (setf cc 0))))
                   ((or (= ks #xff52) (= ks #xff54))               ; Up, Down: the row above or below
                    (let* ((k (caret-row)) (x (row-x (aref (rows) k) cc))
                           (k2 (+ k (if (= ks #xff52) -1 1))))
                      (when (< -1 k2 (length (rows))) (place k2 x))))
                   ((eql ch #\Newline)                            ; split the line at the caret
                    (setf lines (concatenate 'vector (subseq lines 0 cl)
                                             (vector (subseq line 0 cc) (subseq line cc))
                                             (subseq lines (1+ cl))))
                    (incf cl) (setf cc 0))
                   (ch
                    (setf (aref lines cl) (concatenate 'string (subseq line 0 cc) (string ch) (subseq line cc)))
                    (incf cc))))
               (changed)))
      (values (lambda (down ks) (when down (edit ks)))
              ;; a press puts the caret where it lands, and a drag carries it along
              (lambda (mask x y)
                (when (logbitp 0 mask) (place (row-at-y y) x)))
              (lambda () (when dirty (setf dirty nil) (redraw) t))
              nil nil
              t))))                       ; it takes typing: focusing it brings up the keyboard

;;; THE TERMINAL: a Lisp listener in a window.  Enter evaluates what was typed once its
;;; parentheses balance (otherwise the input goes on, on the next line); what it printed and its
;;; values are added below it.  Up and Down walk the history.  It evaluates HERE, on the desk's
;;; thread -- the board's main thread, where evaluation belongs -- so a long evaluation holds the
;;; desk until it ends; (detach FORM :name "x") runs one as a background job instead (modus
;;; net/main-jobs.lisp: (jobs), (attach "x"), (stop-job "x")).
(defun %kiln-balanced-p (text)
  "TEXT holds at least one complete form: its parentheses close, outside strings and comments."
  (let ((depth 0) (in-string nil) (esc nil) (in-comment nil) (any nil))
    (loop for ch across text
          do (cond (in-comment (when (char= ch #\Newline) (setf in-comment nil)))
                   (esc (setf esc nil))
                   (in-string (cond ((char= ch #\\) (setf esc t))
                                    ((char= ch #\") (setf in-string nil))))
                   ((char= ch #\;) (setf in-comment t))
                   ((char= ch #\") (setf in-string t any t))
                   ((char= ch #\() (incf depth) (setf any t))
                   ((char= ch #\)) (decf depth))
                   ((not (member ch '(#\Space #\Tab #\Newline))) (setf any t))))
    (and any (not in-string) (<= depth 0))))

(defun %kiln-terminal-eval (text)
  "Evaluate every form in TEXT: the lines it printed, then `= value' for each value of the last."
  (let ((so (make-string-output-stream)) (vals nil) (out '()))
    (handler-case
        (let ((*standard-output* so) (pos 0) (eof (list nil)))
          (loop (multiple-value-bind (form next) (read-from-string text nil eof :start pos)
                  (when (eq form eof) (return))
                  (setf pos next
                        vals (multiple-value-list (eval form))))))
      (error (c) (setf vals (list (list :error (handler-case (princ-to-string c)
                                                  (error () "unprintable")))))))
    (let ((printed (get-output-stream-string so)))
      (with-input-from-string (in printed)
        (loop for l = (read-line in nil) while l do (push l out))))
    (if vals
        (dolist (v vals) (push (concatenate 'string "= " (handler-case (prin1-to-string v)
                                                          (error () "#<unprintable>")))
                               out))
        (push "; no values" out))
    (nreverse out)))

;;; SSH FROM THE TERMINAL: (ssh "host" :user "modus") typed into a Terminal takes that window
;;; over -- what you type goes to the remote shell a line at a time, what it prints comes back --
;;; until the remote end closes, or you type ~. on a line of its own.  conch is the client (kiln
;;; zero --with=conch puts it in the desk); the board's key and host-key checks are
;;; kiln-zero-ssh's.  Without a pty the remote shell prompts and echoes nothing, so the terminal
;;; shows what you typed itself.  conch reads block, so a core-0 thread reads the session and
;;; hands text to the window, which takes it each frame.
(defvar *kiln-terminal-takeover* nil
  "Bound while a Terminal evaluates: a function of (conn chan host) that turns it into a session.")
(defvar *kiln-terminal-pty* nil
  "Bound while a terminal-emulating Terminal (zero-term.lisp) evaluates: (COLS ROWS), the size of
   the pseudo-terminal SSH asks for before the shell.")

(defun %kiln-c (name)
  (let ((sym (and (find-package "CONCH") (find-symbol name "CONCH"))))
    (unless (and sym (fboundp sym))
      (error "no SSH client in this desk (kiln zero --with=conch installs conch)"))
    (symbol-function sym)))

(defun %kiln-ssh-shell (conn chan)
  "Ask for a shell on CHAN (the request carries no argument, which conch's CHAN-REQUEST-1 adds)."
  (let ((w (funcall (%kiln-c "MAKE-WRITER"))))
    (funcall (%kiln-c "W-BYTE") w 98)                                  ; CHANNEL_REQUEST
    (funcall (%kiln-c "W-U32") w (funcall (%kiln-c "CHAN-REMOTE-ID") chan))
    (funcall (%kiln-c "W-STRING") w "shell")
    (funcall (%kiln-c "W-BOOL") w t)
    (funcall (%kiln-c "WRITE-PACKET") conn (funcall (%kiln-c "WRITER-BYTES") w)))
  (loop for pl = (funcall (%kiln-c "READ-PAYLOAD") conn) for msg = (aref pl 0)
        do (cond ((= msg 99) (return t))                               ; SUCCESS
                 ((= msg 100) (error "the server refused a shell"))  ; FAILURE
                 (t (funcall (%kiln-c "CHAN-PROCESS") chan pl)))))

(defun %kiln-ssh-target (target user port)
  "TARGET as [user@]host[:port]: (values host user port), the parts it names overriding USER
   and PORT."
  (let* ((at (position #\@ target))
         (u (if at (subseq target 0 at) user))
         (rest (if at (subseq target (1+ at)) target))
         (colon (position #\: rest))
         (h (if colon (subseq rest 0 colon) rest))
         (p (if colon (parse-integer rest :start (1+ colon)) port)))
    (values h u p)))

(defun ssh (target &optional port-arg &key (user "modus") (port 22))
  "In a Terminal: an SSH session in this window.  TARGET is [user@]host[:port]; a port may also
   be given after it, (ssh \"10.0.0.1\" 2222), or as :PORT."
  (unless *kiln-terminal-takeover* (error "SSH runs in a Terminal window"))
  (multiple-value-bind (host u p) (%kiln-ssh-target target user (or port-arg port))
    (%kiln-ssh-session host u p)))

(defun %kiln-ssh-session (host user port)
  (%kiln-c "CONNECT")                   ; no conch: say so, before anything else complains
  (let ((zs (find-package "KILN-ZERO-SSH")))
    (unless zs (error "no kiln-zero-ssh in this desk"))
    (funcall (find-symbol "SSH-INSTALL" zs))
    (let* ((conn (funcall (%kiln-c "CONNECT") host :port port :user user
                          :identity (funcall (find-symbol "%IDENTITY" zs))
                          :host-key-verifier (funcall (find-symbol "%VERIFIER" zs) host)))
           (chan (funcall (%kiln-c "OPEN-SESSION") conn)))
      (when (and *kiln-terminal-pty* (fboundp '%kiln-ssh-pty))
        (funcall '%kiln-ssh-pty conn chan (first *kiln-terminal-pty*) (second *kiln-terminal-pty*)))
      (%kiln-ssh-shell conn chan)
      (funcall *kiln-terminal-takeover* conn chan host)
      (intern (format nil "CONNECTED-TO-~:@(~A~)" host) "KEYWORD"))))

;; The Terminal's typeface: Liberation Mono when the image carries it (kiln zero's core build
;; loads it beside the desk's two faces), else the desk's own.
(defvar *kiln-mono-font* nil)

(defun %kiln-terminal-app (fb)
  "A Lisp listener: see %KILN-TERMINAL-EVAL."
  (let ((lines (list "Lisp.  Enter evaluates; (detach FORM :name \"x\") runs it in the background."
                     "(ssh \"user@host:port\") connects this window to a remote shell."))
        (input "") (pending "") (history '()) (hpos -1) (dirty t)
        ;; an SSH session in this window: (conn chan host), its reader's inbox (strings, newest
        ;; first, :EOF at the end), and the unfinished last line of what it printed
        (remote nil) (inbox (list nil)) (partial "")
        (font (or *kiln-mono-font* (glass:default-font))) (size 14) (lh 18) (margin 8)
        (ink #xe8e8e8) (dim #x9aa0a6) (paper #x16181c) (caret #xe0a800))
    (labels ((add (l) (setf lines (append lines (list l)))
                     (when (> (length lines) 400) (setf lines (last lines 400))))
             (prompt () (cond (remote "$ ") ((string= pending "") "> ") (t ". ")))
             (take-over (conn chan host)
               (setf remote (list conn chan host) inbox (list nil) partial "")
               (add (format nil "[connected to ~A -- ~~. on a line of its own ends it]" host))
               (let ((box inbox) (c chan))
                 ;; ON CORE 0, the default for a thread nothing pinned: the inbox is the desk's
                 ;; (main's) object, and a thread on cores 1..3 may not store into it
                 (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (loop
                          (when (or (funcall (%kiln-c "CHAN-EOF") c) (funcall (%kiln-c "CHAN-CLOSED") c))
                            (return))
                          (funcall (%kiln-c "CHAN-PUMP") c)
                          (let ((n (funcall (%kiln-c "CHAN-AVAIL") c)))
                            (when (plusp n)
                              (let ((b (funcall (%kiln-c "CHAN-READ-EXACT") c n)))
                                (push (map 'string #'code-char b) (car box))))))
                      (error () nil))
                    (push :eof (car box)))
                  :name "ssh reader")))
             (take-remote ()
               ;; what the reader brought, oldest first, into lines
               (let ((got (nreverse (shiftf (car inbox) nil))))
                 (dolist (x got)
                   (setf dirty t)
                   (if (eq x :eof)
                       (progn (when (plusp (length partial)) (add partial))
                              (add (format nil "[~A closed the connection]" (third remote)))
                              (ignore-errors (funcall (%kiln-c "DISCONNECT") (first remote)))
                              (setf remote nil partial ""))
                       (loop for ch across x
                             do (cond ((char= ch #\Newline) (add partial) (setf partial ""))
                                      ((char= ch #\Return))
                                      (t (setf partial (concatenate 'string partial (string ch))))))))))
             (send-remote (text)
               (let ((bytes (map '(vector (unsigned-byte 8)) (lambda (ch) (logand (char-code ch) 255))
                                 (concatenate 'string text (string #\Newline)))))
                 (funcall (%kiln-c "CHAN-WRITE") (second remote) bytes)))
             (redraw ()
               (glass:fb-fill fb paper)
               (let* ((w (- (glass:fb-width fb) (* 2 margin)))
                      (rows (loop for l in lines append (or (%kiln-wrap l w size font) (list ""))))
                      (in-rows (or (%kiln-wrap (concatenate 'string (prompt) input) w size font) (list "")))
                      (fit (max 1 (floor (- (glass:fb-height fb) (* 2 margin)) lh)))
                      (shown (last (append rows in-rows) fit))
                      (y margin) (nshown (length shown)) (ninput (length in-rows)))
                 (loop for r in shown for k from 0
                       do (glass:fb-text fb margin y r :size size :color (if (>= k (- nshown ninput)) ink dim)
                                         :font font)
                          (incf y lh))
                 ;; the caret after the input's last row
                 (let ((last-row (car (last in-rows))))
                   (glass:fb-rect fb (+ margin 1 (glass:text-width last-row :size size :font font))
                                  (- y lh -2) 2 (- lh 3) caret))))
             (enter ()
               (when remote
                 (add (concatenate 'string "$ " input))
                 (if (string= input "~.")
                     (progn (ignore-errors (funcall (%kiln-c "DISCONNECT") (first remote)))
                            (add "[disconnected]") (setf remote nil))
                     (handler-case (send-remote input)
                       (error (c) (add (format nil "[~A]" c)) (setf remote nil))))
                 (setf input "")
                 (return-from enter))
               (let ((all (concatenate 'string pending input)))
                 (add (concatenate 'string (prompt) input))
                 (if (%kiln-balanced-p all)
                     (progn
                       (push all history) (setf hpos -1 pending "" input "")
                       (dolist (l (let ((*kiln-terminal-takeover* #'take-over))
                                    (%kiln-terminal-eval all)))
                         (add l)))
                     (setf pending (concatenate 'string all (string #\Newline)) input ""))))
             (key (ks)
               (let ((ch (%kiln-keysym-char ks)))
                 (cond ((= ks #xff08)                       ; BackSpace
                        (when (plusp (length input)) (setf input (subseq input 0 (1- (length input))))))
                       ((= ks #xff52)                       ; Up: the previous entry
                        (when (< (1+ hpos) (length history))
                          (incf hpos) (setf input (nth hpos history))))
                       ((= ks #xff54)                       ; Down
                        (if (plusp hpos)
                            (progn (decf hpos) (setf input (nth hpos history)))
                            (setf hpos -1 input "")))
                       ((eql ch #\Newline) (enter))
                       (ch (setf input (concatenate 'string input (string ch))))))
               (setf dirty t)))
      (values (lambda (down ks) (when down (key ks)))
              nil
              (lambda () (when remote (take-remote)) (when dirty (setf dirty nil) (redraw) t))
              nil
              (lambda () (when remote (ignore-errors (funcall (%kiln-c "DISCONNECT") (first remote)))))
              t))))                       ; it takes typing

(defun %kiln-blit-region (big k x0 y0 x y w h)
  "Show desk rectangle (X,Y,W,H), already magnified by K into BIG, at screen offset (X0,Y0):
   pseudo-syscall 1005 reads the block in place, BIG's row length as its stride."
  (let* ((bw (glass:fb-width big))
         (px (glass:fb-pixels big)) (bpp (%kiln-px-bytes px))
         (base (+ (modus-int::%gc-word-of px (modus-int::%conv-addr #x100050A0)) 7))
         (addr (+ base (* bpp (+ (* y k bw) (* x k))))))
    (%kiln-sys 1005 addr (+ (* w k) (* (* h k) 65536))
               (+ (+ x0 (* x k)) (* (+ y0 (* y k)) 65536)) bw bpp)))

(defun kiln-app-main (&key autoplay (top 60) (media t))
  "The app: a glass desk (glass/desk) on the phone's screen -- windows dragged by their title
   bars, a root menu on the background -- with the media player open.  AUTOPLAY, a file name in
   the bundle's media folder, starts playing once the first picture is up (kiln ios
   --autoplay=FILE) -- for trying a build without touching it.  MEDIA NIL leaves out the
   player and its codecs (warp, reel, reed, cassette) and opens the Clock instead: the
   Zero's bare-metal image has no files to play and installs the desk over the network.
   Pointer events of type 5 move the pointer with no button down -- a mouse hovers, a
   finger cannot."
  (let* ((sw (%kiln-sys 1001 0 0 0))
         (sh (%kiln-sys 1001 1 0 0))
         (dir (or (%kiln-bundle-dir) "./"))
         ;; THE SCREEN IS IN DEVICE PIXELS and the desk is laid out in desktop pixels, so glass
         ;; magnifies it, at the screen's own scale (3 on this phone): ONE DESK PIXEL IS ONE
         ;; POINT, and 16-pixel text is iOS's 16-point text.  At 2x it was two-thirds of that
         ;; and read as tiny.  Touches divide by the same K.
         (k (max 1 (%kiln-sys 1001 2 0 0)))
         (y0 (* top (%kiln-sys 1001 2 0 0)))         ; TOP points: iOS's status bar
         (dw (floor sw k))
         (dh (floor (- sh y0 (* 20 k)) k))
         (x0 (floor (- sw (* dw k)) 2))
         (big (if (= k 1) nil (glass:make-framebuffer (* dw k) (* dh k))))
         ;; SOUND: a mixer whose clock is this loop (see %KILN-PUMP-AUDIO), and a
         ;; speaker at its rate.  No speaker, no mixer -- the player then paces the
         ;; picture by the wall clock, as it did before there was sound.
         (speaker (zerop (%kiln-sys 1010 +kiln-rate+ 0 0)))
         (mixer (and speaker (glass:make-mixer :rate +kiln-rate+)))
         (sink (and mixer (glass:mixer-subscribe mixer :name "speaker" :rate +kiln-rate+)))
         (lib (and media (warp-media:make-library :root (concatenate 'string dir "media/")
                                                  :mixer mixer)))
         (desk (glass.desk:make-desk (glass:make-framebuffer dw dh))))
    (format t "~&kiln: ~Dx~D screen, desk ~Dx~D at ~Dx, media from ~A~%" sw sh dw dh k dir)
    (%kiln-sys 1002 0 (+ sw (* sh 65536)) #x1E2530)
    ;; TOUCH-SIZED CHROME: a 34-point title bar to drag by, 44-point menu rows (iOS's
    ;; minimum touch target), 16-point labels
    (setf glass.desk:*title-h* 34 glass.desk:*menu-item-h* 44 glass.desk:*menu-w* 220
          glass.desk:*font-size* 16)
    ;; the media and notes windows take the width of the phone
    ;; FIVE values, then NIL: warp's MAKE-MEDIA-WINDOW answers the WM surface contract, whose
    ;; sixth value is its CONSUMER -- and the desk reads an app's sixth value as TEXT-P, so the
    ;; player counted as a text window and raised the keyboard at launch.
    (when media
      (glass.desk:desk-register-app desk "Media"
                                    (lambda (fb)
                                      (multiple-value-bind (on-key on-pointer dirty-p copy-p close-fn)
                                          (warp-media-glass:make-media-window fb lib)
                                        (values on-key on-pointer dirty-p copy-p close-fn nil)))
                                    :width dw :height 440))
    (glass.desk:desk-register-app desk "Clock" #'%kiln-clock-app :width 260 :height 110)
    (glass.desk:desk-register-app desk "Notes" #'%kiln-notes-app
                                  :width (if media dw (min dw 420)) :height 300)
    ;; the terminal-emulating Terminal (zero-term.lisp: glass/term + quill) where the image has it
    (glass.desk:desk-register-app desk "Terminal"
                                  (if (fboundp '%kiln-vt-terminal-app)
                                      (symbol-function '%kiln-vt-terminal-app)
                                      #'%kiln-terminal-app)
                                  :width (min dw 600) :height 320)
    ;; THE KEYBOARD follows the focus: the desk raises the phone's keyboard (pseudo-syscall 1006)
    ;; when a window that takes text is opened or tapped into, and puts it away when you tap
    ;; elsewhere; what is typed arrives as key events below
    (setf (glass.desk:desk-keyboard-fn desk)
          (lambda (on) (%kiln-sys 1006 (if on 1 0) 0 0)))
    (glass.desk:desk-open desk (if media "Media" "Clock"))
    (format t "~&kiln: ~:[no speaker~;speaker at ~D Hz~]~%" speaker +kiln-rate+)
    (when (and media autoplay)
      (let ((path (concatenate 'string dir "media/" autoplay)))
        (if (probe-file path)
            (progn (format t "~&kiln: autoplay ~A~%" autoplay)
                   (warp-media:play-path (warp-media:library-player lib) path))
            (format t "~&kiln: autoplay ~A: no such file~%" autoplay))))
    (when media
      (format t "~&kiln: ~D track~:P~%"
              (length (warp-media:folder-tracks (concatenate 'string dir "media/")))))
    ;; A tap or a repaint that signals is logged and dropped: one bad gesture
    ;; must not take the app down (an error out of here ends the process).
    (loop
     (handler-case
      (let ((e (%kiln-sys 1004 0 0 0)))
        (if (zerop e)
            (let ((t0 (get-internal-real-time)))
              (when mixer (%kiln-pump-audio mixer sink))
              ;; ONLY WHAT CHANGED is magnified and shown: a video window is a fifth of the
              ;; screen, and the whole of it 2x was most of a frame
              (multiple-value-bind (changed x y w h) (glass.desk:desk-tick desk)
                (when changed
                  (if (eq (glass:fb-format (glass.desk:desk-fb desk)) :xrgb)
                      (progn
                        ;; at 1x the magnified copy IS the desk: show it straight from there
                        ;; (the copy was a tenth of a Pi Zero's drag frame)
                        (if (= k 1)
                            (%kiln-blit-region (glass.desk:desk-fb desk) 1 x0 y0 x y w h)
                            (progn
                              (glass:fb-blit-scaled-region big (glass.desk:desk-fb desk) k x y w h)
                              (%kiln-blit-region big k x0 y0 x y w h)))
                        (%kiln-sys 1003 0 0 0))
                      ;; A Y'CbCr desk (glass :I420) is shown as it is: the platform scans
                      ;; the planes out (pseudo-syscall 1007, the Zero's HVS)
                      (%kiln-sys 1007 (glass.desk:desk-fb desk) 0 0))))
              ;; a frame is 16 ms; sleep only what is left of it, not 16 ms on top of the work
              (let ((left (- 16 (floor (- (get-internal-real-time) t0) 1000))))
                (when (> left 1) (modus-int::%sleep-ms left))))
            (let ((type (floor e 1099511627776))
                  (y (logand (floor e 1048576) #xFFFFF))
                  (x (logand e #xFFFFF)))
              (if (= type 4)
                  ;; a key: the keysym is the low 40 bits; a press and its release
                  (let ((ks (logand e #xFFFFFFFFFF)) (focus (glass.desk::desk-focus desk)))
                    ;; ~ or / with no text window focused opens a Terminal (typed into one,
                    ;; they are just characters)
                    (if (and (or (= ks #x7e) (= ks #x2f))
                             (not (and focus (glass.desk::win-text-p focus))))
                        (glass.desk:desk-open desk "Terminal")
                        (progn (glass.desk:desk-key desk t ks)
                               (glass.desk:desk-key desk nil ks))))
                  (glass.desk:desk-pointer desk (if (or (= type 3) (= type 5)) 0 1)
                                           (floor (- x x0) k) (floor (- y y0) k))))))
       (error (c) (format t "~&kiln: ~A~%"
                          (if (fboundp 'modus-int::%escape-describe) (modus-int::%escape-describe c) c)))))))
