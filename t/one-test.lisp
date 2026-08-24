;;;; one-test.lisp — the decisions boot/one.lisp makes before anything starts.
;;;;
;;;; These are small functions guarding expensive failures.  A flag misread means a
;;;; service that was asked for does not start (or one that was not, does).  A payload
;;;; that is not bundled means a phone connects, authenticates, gets a screen and then
;;;; cannot run the client — and NOTHING on the box looks wrong, which is what makes
;;;; the check worth having and worth testing.
;;;;
;;;; The definitions are read out of boot/one.lisp itself.  Loading that file is not an
;;;; option (it starts a desktop), and copying the functions here would leave a test
;;;; that passes forever against code nobody runs.
;;;;
;;;;   sbcl --script t/one-test.lisp

(require :sb-posix)

(defparameter *wanted*
  '(kiln-env kiln-flag kiln-flag-default kiln-file-line kiln-file-has-relative-import-p))

(defparameter *here*
  (merge-pathnames "../boot/one.lisp"
                   (make-pathname :name nil :type nil :defaults *load-truename*)))

(let ((found '()))
  (with-open-file (in *here*)
    (loop for form = (read in nil :eof)
          until (eq form :eof)
          do (when (and (consp form) (eq (first form) 'defun)
                        (member (second form) *wanted*))
               (push (second form) found)
               (eval form))))
  (let ((missing (set-difference *wanted* found)))
    (when missing
      (format *error-output* "~&one-test: not found in one.lisp: ~a~%" missing)
      (sb-ext:exit :code 1))))

(defvar *fails* 0)
(defun ok (name got want)
  (if (equal got want)
      (format t "  ok   ~a~%" name)
      (progn (incf *fails*)
             (format t "  FAIL ~a~%     want [~s] got [~s]~%" name want got))))

;;; ---- flags -------------------------------------------------------------------
;;; `y' is what the .config writes and `1' is what a shell writes; both mean on.
(sb-posix:setenv "T_Y" "y" 1) (sb-posix:setenv "T_1" "1" 1)
(sb-posix:setenv "T_0" "0" 1) (sb-posix:setenv "T_E" "" 1)
(sb-posix:setenv "T_N" "n" 1)
(ok "kiln-flag: y is on"        (kiln-flag "T_Y") t)
(ok "kiln-flag: 1 is on"        (kiln-flag "T_1") t)
(ok "kiln-flag: 0 is off"       (kiln-flag "T_0") nil)
(ok "kiln-flag: empty is off"   (kiln-flag "T_E") nil)
(ok "kiln-flag: n is off"       (kiln-flag "T_N") nil)
(ok "kiln-flag: unset is off"   (kiln-flag "T_UNSET_XYZ") nil)

;;; ...and the same question for a setting whose default is ON, where "absent" and
;;; "explicitly off" must not collapse into each other.
(ok "kiln-flag-default: absent takes the default" (kiln-flag-default "T_UNSET_XYZ" t) t)
(ok "kiln-flag-default: absent takes the default (nil)" (kiln-flag-default "T_UNSET_XYZ" nil) nil)
(ok "kiln-flag-default: 0 overrides an ON default"  (kiln-flag-default "T_0" t) nil)
(ok "kiln-flag-default: n overrides an ON default"  (kiln-flag-default "T_N" t) nil)
(ok "kiln-flag-default: y overrides an OFF default" (kiln-flag-default "T_Y" nil) t)

;;; ---- the identity file -------------------------------------------------------
;;; A secret arrives as a file with a mode on it.  Leading blank lines and a trailing
;;; newline are what a shell redirect leaves behind, so they must not become the key.
(let ((p (merge-pathnames "one-test-sec.tmp" (or *load-truename* *default-pathname-defaults*))))
  (with-open-file (o p :direction :output :if-exists :supersede)
    (format o "~%   ~%  deadbeef  ~%ignored~%"))
  (ok "kiln-file-line: first non-blank, trimmed" (kiln-file-line p) "deadbeef")
  (delete-file p))
(ok "kiln-file-line: a missing file is NIL, not an error"
    (kiln-file-line "/nonexistent/xyzzy/nope") nil)

;;; ---- is the client bundled? --------------------------------------------------
;;; The failure this prevents: the payload runs from a blob URL in the browser, where
;;; a relative specifier has nothing to resolve against.  Serving the source gets
;;; "Module name, './novnc/core/rfb.js' does not resolve to a valid URL" on the phone
;;; and a Retry button that can never work.
(flet ((probe (text)
         (let ((p (merge-pathnames "one-test-payload.tmp"
                                   (or *load-truename* *default-pathname-defaults*))))
           (with-open-file (o p :direction :output :if-exists :supersede)
             (write-string text o))
           (prog1 (kiln-file-has-relative-import-p p) (delete-file p)))))
  (ok "unbundled: single-quoted relative import is caught"
      (probe "// header
import RFB from './novnc/core/rfb.js';
export const x = 1;") t)
  (ok "unbundled: double-quoted relative import is caught"
      (probe "import RFB from \"./novnc/core/rfb.js\";") t)
  (ok "bundled: no relative import, no complaint"
      (probe "var RFB=(function(){return 1})();export{RFB};") nil)
  ;; A bundle inlines its dependencies, so the WORD import can still appear in a
  ;; string or a comment.  Flagging that would cry wolf on every correct build.
  (ok "bundled: the word import in prose is not an import"
      (probe "// this bundle used to import from './novnc'
var a=1;") nil))

(format t "~&~:[~;all ~]~d check~:p, ~d failure~:p~%" (zerop *fails*)
        (+ 17 0) *fails*)
(sb-ext:exit :code (if (zerop *fails*) 0 1))
