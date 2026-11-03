;;;; zero-shell.lisp — the Zero's SSH shell, edited with quill.
;;;;
;;;; modus runs an SSH session's shell itself (net/ssh-inetd.lisp): it reads a line, evaluates
;;;; it on the main thread, prints the value, and asks for the next.  Reading the line is a seam,
;;;; MODUS-INT::*SSH-READ-LINE*, and this fills it with quill: Emacs keys and a kill ring, history
;;;; (per session, in memory) with C-r search, multi-line forms (C-j, or Enter on open
;;;; parentheses), paren matching and bracketed paste -- over the SSH channel, through quill's
;;;; :INPUT, since the board has no terminal of its own.  Without a terminal (`echo FORM | ssh`)
;;;; modus keeps its plain path.

(defpackage #:kiln-zero-shell
  (:use #:cl)
  (:export #:install))
(in-package #:kiln-zero-shell)

(defun %open-parens-p (text)
  "TEXT has a parenthesis still open (outside strings, comments and #\\ characters)."
  (let ((depth 0) (str nil) (esc nil) (comment nil) (i 0) (n (length text)))
    (loop
      (when (>= i n) (return (or (> depth 0) str)))
      (let ((c (char text i)))
        (cond (comment (when (char= c #\Newline) (setq comment nil)))
              (str (cond (esc (setq esc nil)) ((char= c #\\) (setq esc t)) ((char= c #\") (setq str nil))))
              ((char= c #\") (setq str t))
              ((char= c #\;) (setq comment t))
              ((and (char= c #\#) (< (+ i 1) n) (char= (char text (+ i 1)) #\\)) (incf i 2))
              ((char= c #\() (incf depth))
              ((char= c #\)) (decf depth))))
      (incf i))))

(defun %enter (session)
  "Enter: a newline while a parenthesis is open, as a Lisp listener should; else submit."
  (let ((ed (quill:session-buffer session)))
    (if (%open-parens-p (quill:editor-text ed))
        (quill:insert ed (string #\Newline))
        (quill::accept-line session))))

;; Made here, on the main thread, so a session's thread only ever reads it.
(defvar *keymap*
  (let ((k (quill:make-keymap quill:*default-keymap*)))
    (quill:bind k :enter #'%enter)
    k))

(defun read-line-for-ssh (input output prompt width state)
  "modus's *SSH-READ-LINE*: one form, edited.  STATE's car is the session's history."
  (quill:read-line-edited :prompt prompt :continuation "  " :keymap *keymap*
                          :history (or (car state) (setf (car state) (quill:make-history)))
                          :input input :output output :width width))

(defun install ()
  (setf (symbol-value (intern "*SSH-READ-LINE*" "MODUS-INT")) #'read-line-for-ssh)
  t)

(install)
