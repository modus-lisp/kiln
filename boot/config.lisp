;;;; config.lisp — kiln's configuration, as a menuconfig.
;;;;
;;;; The kernel's shape, because it fits: a tree of menus, [*] for booleans,
;;;; (value) for the rest, help on every item, and a .config of KEY=value lines
;;;; with "# KEY is not set" for the ones turned off.  That file is the thing
;;;; that survives — mounted from the host, so a rebuilt image keeps its
;;;; identity and its settings.
;;;;
;;;; It draws over an SSH session channel rather than a terminal: conch records
;;;; the client's pty-req, so PTY-COLS/PTY-ROWS say how big the window is and
;;;; PTY-ON-RESIZE says when it changed.  Everything below writes ANSI to the
;;;; channel and reads keystrokes back from it.

(defpackage #:kiln-config
  (:use #:cl)
  (:export #:run-tui #:load-config #:save-config #:config-value
           #:*config-path* #:*resolve-nip05*))

(in-package #:kiln-config)

(defvar *resolve-nip05* nil
  "Function of an address, returning (VALUES PUBKEY-HEX ERROR-STRING).  Installed
   by whoever runs the TUI, so this file needs no HTTP client of its own.")

(defparameter *config-path* "/etc/kiln/config"
  "The .config, on the volume the host mounts — this is what persists.")

;;; ---- the schema -------------------------------------------------------------
;;;
;;; (:menu  label (children...))
;;; (:bool  key label default help)
;;; (:int   key label default help)
;;; (:string key label default help)

(defparameter *schema*
  '((:menu "Access"
     ((:bool "KILN_WEB" "Web gateway (WebRTC)" t
       "Serve the browser client and the WebRTC data channel that carries the
desktop.  This is the surface kiln expects you to use: it carries screen, sound,
microphone and structured payloads over one encrypted connection.

Published to the host's loopback, where http://localhost is a secure context, so
no certificate and no signalling relay are needed.")
      (:int "GW_PORT" "Gateway port" 8765
       "TCP port for the web gateway, published to 127.0.0.1 on the host.")
      (:bool "KILN_VNC" "VNC / RFB" nil
       "Publish the raw RFB port as well.

Off by default, and not out of tidiness: RFB's own authentication is a DES
challenge/response over a password truncated to EIGHT characters.  The desktop
always listens on RFB inside the container -- that is how the gateway reaches it
-- but nothing outside can unless you turn this on.")
      (:bool "KILN_SSH" "SSH control plane" t
       "conch, the pure-Lisp SSH server, answering on KILN_SSH_PORT and
authenticating against the authorized_keys the host installed.

This is how you reached this screen.  Turning it off means the next boot has no
control plane, so leave it on unless the box is configured for good.")
      (:int "KILN_SSH_PORT" "SSH port" 2222
       "TCP port for the SSH control plane.")))

    (:menu "Desktop"
     ((:int "GLASS_DISPLAY" "Display number" 1
       "X-style display number.  EVERY port the desktop owns is derived from it
-- RFB is 5900+N, session audio 5910+N, the control socket 4008+N -- so a second
desktop is one number, not a forked config.")
      (:int "KILN_WIDTH" "Screen width" 1280 "Framebuffer width in pixels.")
      (:int "KILN_HEIGHT" "Screen height" 800 "Framebuffer height in pixels.")
      (:string "GLASS_APPS" "Startup windows" ""
       "Comma-separated windows opened at startup: \"terminal\", or a McCLIM
frame-class name.

Empty by default.  Everything is one right-click away on the root menu, and a
shell opened before anyone asked for one is a shell sitting there for whoever
connects first.")))

    (:menu "Audio"
     ((:bool "KILN_AUDIO" "Session audio" t
       "The session mixer: one mix on its own 20ms clock, which every listener
subscribes to with a private cursor and resampler.")
      (:bool "KILN_MIC" "Microphone" nil
       "Accept a peer's microphone.  Deliberately NOT on the session mixer -- a
microphone in the mix would be played back out of the desktop's own audio and
down the outbound stream to the peer that spoke.")
      (:string "GLASS_VOICE" "Voice model (chord)" ""
       "Path to a chord .graph to speak with; its .bin and config sit beside it.
Empty means the desktop is mute, which is a working desktop.")
      (:string "GLASS_EARS" "Recognizer models (stave)" ""
       "Directory holding stave's three .graph files and tokens.txt.  Empty means
the desktop cannot hear, which is also a working desktop.")))

    (:menu "Remote access"
     ((:bool "KILN_NOSTR" "Nostr signalling" nil
       "For a box that is NOT the machine you are sitting at.  Signalling rides
NIP-59 gift wrap over relays, so nothing needs a forwarded port, a DNS record or
a certificate.

Pointless on a laptop -- localhost already works -- and the reason it exists is
the hardware this is eventually meant to run on.")
      (:identity "NOSTR_ALLOW" "Allowed identity" ""
       "The identity permitted to open a session: an npub, a 64-hex pubkey, or a
NIP-05 name@domain.

A NIP-05 is resolved HERE, once, while you watch -- not at every boot.  That
matters twice over.  A boot-time lookup fails silently: the gateway wraps it in
ignore-errors and drops the entry, so one DNS hiccup leaves an empty allowlist,
and an empty allowlist refuses everyone.  You would get a box that starts
perfectly and rejects you with no reason given.

And a NIP-05 is a NAME, resolved over DNS and HTTPS by whoever runs that domain.
An npub is self-certifying.  Resolving once and storing the key keeps the
convenience of typing a name while what is actually trusted stays a key.")
      (:string "NOSTR_RELAYS" "Relays" "wss://relay.damus.io,wss://nos.lol"
       "Comma-separated relay URLs used for signalling.")
      (:string "TURN_SERVER" "TURN relay" ""
       "host:port of a TURN server, for when the two ends cannot reach each other
directly.

They often cannot.  Two peers behind carrier NAT, or on a VPN that hands both
ends addresses on networks neither can route to, gather plenty of candidates and
pair with none of them -- the session authenticates, the screen never arrives,
and nothing in the log says why.  A relay is the route that always exists,
because both ends dial OUT to it.

Empty means direct-only: fine on a LAN, and the first thing to suspect when a
phone connects from outside and hangs.")
      (:string "TURN_USER" "TURN username" ""
       "Long-term credential for the TURN server.  Empty when it needs none.")
      (:string "TURN_PASS" "TURN password" ""
       "Its password.  Stored in this file, so the file's mode is what protects it
-- which is why /etc/kiln is 0700 and not a mount anyone can read.")))))

;;; ---- item accessors ---------------------------------------------------------

(defun item-kind (i) (first i))
(defun menu-p (i) (eq (item-kind i) :menu))
(defun menu-label (i) (second i))
(defun menu-children (i) (third i))
(defun item-key (i) (second i))
(defun item-label (i) (third i))
(defun item-default (i) (fourth i))
(defun item-help (i) (fifth i))

(defun source-key (item)
  "Where an :identity records the NIP-05 it was resolved FROM, so the display can
   show the name and the config can be re-resolved later."
  (concatenate 'string (item-key item) "_NIP05"))

(defun nip05-address-p (s)
  "An email-shaped identifier rather than an npub or hex: text, @, text, and a dot
   in the domain."
  (and (stringp s)
       (let ((at (position #\@ s)))
         (and at (plusp at) (< (1+ at) (length s)) (find #\. s :start at)))))

(defun abbrev-key (s)
  (if (and s (> (length s) 14)) (concatenate 'string (subseq s 0 10) "…") (or s "")))

(defun walk-items (nodes fn)
  (dolist (n nodes)
    (if (menu-p n) (walk-items (menu-children n) fn) (funcall fn n))))

;;; ---- the .config ------------------------------------------------------------

(defvar *values* (make-hash-table :test 'equal))

(defun config-value (key) (gethash key *values*))

(defun defaults ()
  (let ((h (make-hash-table :test 'equal)))
    (walk-items *schema*
                (lambda (i)
                  (setf (gethash (item-key i) h) (item-default i))
                  (when (eq (item-kind i) :identity)
                    (setf (gethash (source-key i) h) ""))))
    h))

(defun parse-line (line h)
  (let ((line (string-trim '(#\Space #\Tab #\Return) line)))
    (cond
      ((zerop (length line)) nil)
      ;; "# KEY is not set" is how the kernel spells a disabled bool, and it
      ;; round-trips: a plain comment is skipped, this one carries meaning.
      ((and (char= (char line 0) #\#) (search " is not set" line))
       (let* ((start 2) (end (search " is not set" line)))
         (when (> end start) (setf (gethash (subseq line start end) h) nil))))
      ((char= (char line 0) #\#) nil)
      (t (let ((eq (position #\= line)))
           (when eq
             (let ((k (subseq line 0 eq)) (v (subseq line (1+ eq))))
               (setf (gethash k h)
                     (cond ((string= v "y") t)
                           ((string= v "n") nil)
                           ((and (plusp (length v)) (every #'digit-char-p v))
                            (parse-integer v))
                           ((and (>= (length v) 2) (char= (char v 0) #\"))
                            (subseq v 1 (1- (length v))))
                           (t v))))))))))

(defun load-config (&optional (path *config-path*))
  (let ((h (defaults)))
    (when (probe-file path)
      (with-open-file (in path)
        (loop for line = (read-line in nil) while line do (parse-line line h))))
    (setf *values* h)))

(defun save-config (&optional (path *config-path*))
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (format out "# kiln configuration~%#~%~
                 # Written by `kiln config'.  KEY=value; a disabled boolean is~%~
                 # recorded as a comment, the way the kernel's .config does it,~%~
                 # so \"off\" and \"never mentioned\" stay distinguishable.~%")
    (labels ((emit (nodes depth)
               (dolist (n nodes)
                 (if (menu-p n)
                     (progn (format out "~%#~%# ~a~%#~%" (menu-label n))
                            (emit (menu-children n) (1+ depth)))
                     (let ((v (gethash (item-key n) *values*)))
                       (case (item-kind n)
                         (:bool (if v
                                    (format out "~a=y~%" (item-key n))
                                    (format out "# ~a is not set~%" (item-key n))))
                         (:int (format out "~a=~d~%" (item-key n) (or v 0)))
                         (:string (format out "~a=\"~a\"~%" (item-key n) (or v "")))
                         (:identity
                          (format out "~a=\"~a\"~%" (item-key n) (or v ""))
                          (format out "~a=\"~a\"~%" (source-key n)
                                  (or (gethash (source-key n) *values*) "")))))))))
      (emit *schema* 0)))
  path)

;;; ---- terminal ---------------------------------------------------------------

(defvar *out* nil)          ; a function of one string: write it to the client
(defvar *cols* 80)
(defvar *rows* 24)

(defun emit (fmt &rest args) (funcall *out* (apply #'format nil fmt args)))

(defun clear () (emit "~c[2J~c[H" #\Escape #\Escape))
(defun at (row col) (emit "~c[~d;~dH" #\Escape row col))
(defun reverse-on () (emit "~c[7m" #\Escape))
(defun reverse-off () (emit "~c[0m" #\Escape))
(defun dim-on () (emit "~c[2m" #\Escape))
(defun hide-cursor () (emit "~c[?25l" #\Escape))
(defun show-cursor () (emit "~c[?25h" #\Escape))

(defun fit (s width)
  (let ((s (or s "")))
    (if (> (length s) width) (subseq s 0 (max 0 width)) s)))

(defun value-tag (item)
  (let ((v (gethash (item-key item) *values*)))
    (case (item-kind item)
      (:bool (if v "[*]" "[ ]"))
      (:int (format nil "(~d)" (or v 0)))
      (:string (format nil "(~a)" (if (and v (plusp (length v))) v "")))
      (:identity
       (let ((src (gethash (source-key item) *values*)))
         (cond ((and src (plusp (length src)))
                (format nil "(~a -> ~a)" src (abbrev-key v)))
               ((and v (plusp (length v))) (format nil "(~a)" (abbrev-key v)))
               (t "()"))))
      (t "   "))))

;;; ---- drawing ----------------------------------------------------------------

(defun draw (path cursor status)
  "PATH is the menu stack (innermost last); CURSOR indexes the current menu."
  (let* ((nodes (if path (menu-children (car (last path))) *schema*))
         (title (if path
                    (format nil "kiln configuration -> ~{~a~^ -> ~}"
                            (mapcar #'menu-label path))
                    "kiln configuration"))
         (body-rows (max 3 (- *rows* 6))))
    (clear)
    (hide-cursor)
    (at 1 1) (reverse-on)
    (emit " ~a" (fit title (- *cols* 2)))
    (emit "~v@{ ~}" (max 0 (- *cols* 1 (length (fit title (- *cols* 2))))) t)
    (reverse-off)
    (at 2 1) (dim-on)
    (emit " arrows move  enter select  space toggle  ? help  s save  q quit")
    (reverse-off)

    (let ((first (max 0 (min (- cursor (floor body-rows 2))
                             (max 0 (- (length nodes) body-rows))))))
      (loop for idx from first below (min (length nodes) (+ first body-rows))
            for row from 4
            for n = (nth idx nodes)
            do (at row 1)
               (when (= idx cursor) (reverse-on))
               (emit " ~a ~a"
                     (if (menu-p n) "   " (value-tag n))
                     (fit (if (menu-p n)
                              (format nil "~a  --->" (menu-label n))
                              (item-label n))
                          (- *cols* 8)))
               (when (= idx cursor) (reverse-off)))
      (at (- *rows* 1) 1)
      (dim-on)
      (emit " ~a" (fit (or status "") (- *cols* 2)))
      (reverse-off))
    (at *rows* 1)))

(defun split-lines (s)
  (let ((out '()) (start 0))
    (dotimes (i (1+ (length s)))
      (when (or (= i (length s)) (char= (char s i) #\Newline))
        (push (subseq s start i) out)
        (setf start (1+ i))))
    (nreverse out)))

(defun draw-help (item)
  (clear)
  (at 1 1) (reverse-on)
  (emit " ~a" (fit (if (menu-p item) (menu-label item) (item-label item)) (- *cols* 2)))
  (reverse-off)
  (at 3 1)
  (unless (menu-p item)
    (emit "  symbol: ~a~%~%" (item-key item)))
  (let ((row 5))
    (dolist (line (split-lines (or (if (menu-p item) "A submenu." (item-help item)) "")))
      (when (< row (- *rows* 2))
        (at row 3) (emit "~a" (fit line (- *cols* 4))) (incf row))))
  (at (- *rows* 1) 1) (dim-on) (emit " any key to go back") (reverse-off))

;;; ---- input ------------------------------------------------------------------
;;;
;;; Raw bytes: ssh -t puts the CLIENT's terminal in raw mode, so keystrokes
;;; arrive unbuffered and unechoed.  Arrows come as ESC [ A..D; a lone ESC is
;;; only a lone ESC when nothing follows it, which we can tell because the whole
;;; sequence arrives in one packet.

(defun read-key (read-byte more-p)
  (let ((b (funcall read-byte)))
    (cond
      ((null b) :eof)
      ((= b 27)
       (if (not (funcall more-p))
           :escape
           (let ((b2 (funcall read-byte)))
             (if (or (= b2 91) (= b2 79))          ; CSI or SS3
                 (case (funcall read-byte)
                   (65 :up) (66 :down) (67 :right) (68 :left) (t :other))
                 :escape))))
      ((or (= b 13) (= b 10)) :enter)
      ((= b 32) :space)
      ((or (= b 127) (= b 8)) :backspace)
      (t (code-char b)))))

(defun status-line (fmt &rest args)
  (at (- *rows* 1) 1)
  (emit "~c[2K " #\Escape)
  (emit "~?" fmt args))

(defun prompt-identity (item read-byte more-p)
  "Edit an identity, resolving a NIP-05 on the spot.

   The resolution is the whole point of the type, so its outcome is reported
   rather than swallowed: a name that does not resolve leaves the stored key
   ALONE instead of blanking it, because a config that silently forgets who is
   allowed is how you lock yourself out of your own box."
  (let ((typed (prompt-string item read-byte more-p
                              (or (gethash (source-key item) *values*)
                                  (gethash (item-key item) *values*)))))
    (when (null typed) (return-from prompt-identity nil))
    (cond
      ((zerop (length typed))
       (setf (gethash (item-key item) *values*) ""
             (gethash (source-key item) *values*) "")
       t)
      ((not (nip05-address-p typed))
       ;; An npub or hex is already self-certifying; nothing to look up.
       (setf (gethash (item-key item) *values*) typed
             (gethash (source-key item) *values*) "")
       t)
      ((null *resolve-nip05*)
       (status-line "no resolver available — stored ~a as typed" typed)
       (setf (gethash (item-key item) *values*) typed
             (gethash (source-key item) *values*) "")
       (read-key read-byte more-p)
       t)
      (t
       (status-line "resolving ~a …" typed)
       (multiple-value-bind (hex err) (funcall *resolve-nip05* typed)
         (cond
           (hex (setf (gethash (item-key item) *values*) hex
                      (gethash (source-key item) *values*) typed)
                (status-line "~a -> ~a" typed hex))
           (t (status-line "could not resolve ~a: ~a (keeping previous)" typed
                           (or err "no key listed"))))
         (read-key read-byte more-p)
         t)))))

(defun prompt-string (item read-byte more-p &optional initial)
  "Line-edit a value at the bottom of the screen.  Returns the string, or NIL if
   the edit was abandoned."
  (let ((buf (format nil "~a" (or initial ""))))
    (loop
      (status-line "~a = ~a" (item-key item) buf)
      (show-cursor)
      (let ((k (read-key read-byte more-p)))
        (cond
          ((eq k :enter) (hide-cursor) (return buf))
          ((or (eq k :escape) (eq k :eof)) (hide-cursor) (return nil))
          ((eq k :backspace)
           (when (plusp (length buf)) (setf buf (subseq buf 0 (1- (length buf))))))
          ((characterp k) (setf buf (concatenate 'string buf (string k)))))))))

(defun prompt-value (item read-byte more-p)
  "Edit an int/string at the bottom of the screen."
  (let* ((cur (gethash (item-key item) *values*))
         (buf (format nil "~a" (or cur ""))))
    (loop
      (at (- *rows* 1) 1)
      (emit "~c[2K" #\Escape)
      (emit " ~a = ~a" (item-key item) buf)
      (show-cursor)
      (let ((k (read-key read-byte more-p)))
        (cond
          ((eq k :enter)
           (hide-cursor)
           (setf (gethash (item-key item) *values*)
                 (if (eq (item-kind item) :int)
                     (or (ignore-errors (parse-integer buf)) 0)
                     buf))
           (return t))
          ((or (eq k :escape) (eq k :eof)) (hide-cursor) (return nil))
          ((eq k :backspace)
           (when (plusp (length buf)) (setf buf (subseq buf 0 (1- (length buf))))))
          ((characterp k)
           (when (or (not (eq (item-kind item) :int)) (digit-char-p k))
             (setf buf (concatenate 'string buf (string k))))))))))

;;; ---- the loop ---------------------------------------------------------------

(defun run-tui (&key out read-byte more-p (cols 80) (rows 24) size-fn on-quit)
  "Drive the menuconfig.  OUT writes a string to the client, READ-BYTE returns the
   next keystroke byte (or NIL at EOF), MORE-P says whether more input is already
   buffered — which is how an arrow key is told from a bare ESC.

   SIZE-FN, if given, is consulted before every redraw and returns (VALUES COLS
   ROWS).  A window-change arrives on the server's read loop, i.e. a DIFFERENT
   thread, and *COLS* is bound per-thread — so the hook cannot poke this thread's
   binding and we have to come and ask."
  (let ((*out* out) (*cols* cols) (*rows* rows)
        (path '()) (cursor 0) (status "")
        (stack '()))
    (load-config)
    (loop
      (let ((nodes (if path (menu-children (car (last path))) *schema*)))
        (when size-fn
          (multiple-value-bind (c r) (funcall size-fn)
            (when (and c r (plusp c) (plusp r)) (setf *cols* c *rows* r))))
        (setf cursor (max 0 (min cursor (1- (max 1 (length nodes))))))
        (draw path cursor status)
        (setf status "")
        (let ((k (read-key read-byte more-p))
              (item (nth cursor nodes)))
          (case k
            (:eof (return))
            (:up (setf cursor (mod (1- cursor) (max 1 (length nodes)))))
            (:down (setf cursor (mod (1+ cursor) (max 1 (length nodes)))))
            ((:enter :right)
             (cond ((and item (menu-p item))
                    (push cursor stack)
                    (setf path (append path (list item)) cursor 0))
                   ((and item (eq (item-kind item) :bool))
                    (setf (gethash (item-key item) *values*)
                          (not (gethash (item-key item) *values*))))
                   ((and item (eq (item-kind item) :identity))
                    (prompt-identity item read-byte more-p))
                   (item (prompt-value item read-byte more-p))))
            (:space
             (when (and item (not (menu-p item)))
               (case (item-kind item)
                 (:bool (setf (gethash (item-key item) *values*)
                              (not (gethash (item-key item) *values*))))
                 (:identity (prompt-identity item read-byte more-p))
                 (t (prompt-value item read-byte more-p)))))
            ((:left :escape)
             (if path
                 (setf path (butlast path) cursor (or (pop stack) 0))
                 (setf status "top level — q to quit")))
            (t
             (when (characterp k)
               (case (char-downcase k)
                 (#\? (when item (draw-help item) (read-key read-byte more-p)))
                 (#\s (save-config)
                      (setf status (format nil "saved ~a" *config-path*)))
                 (#\q (clear) (show-cursor)
                      (when on-quit (funcall on-quit))
                      (return))
                 (t nil))))))))))
