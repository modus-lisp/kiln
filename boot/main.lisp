;;;; main.lisp -- what `modus --kiln COMMAND ...' runs (the kiln/main.lisp segment that
;;;; boot/bundle.lisp appends to modus.exe).
;;;;
;;;; The kiln/src.pack segment beside it holds kiln and cairn's closure as source.  This
;;;; unpacks it once per modus.exe -- into %LOCALAPPDATA%\modus\kiln\KEY\ on Windows,
;;;; ~/.cache/modus/kiln/KEY/ elsewhere, KEY naming the pack's size and the executable's
;;;; date -- loads cairn with ASDF (compiled once, then from modus's FASL cache), loads
;;;; kiln.lisp and hands it the arguments.  Runs on modus only: it reads its own file.

(require :asdf)

(defun %kiln-u32 (v i)
  (logior (aref v i) (ash (aref v (+ i 1)) 8) (ash (aref v (+ i 2)) 16) (ash (aref v (+ i 3)) 24)))

(defun %kiln-cache-root ()
  (let ((local (uiop:getenv "LOCALAPPDATA")) (home (uiop:getenv "HOME")))
    (uiop:ensure-directory-pathname
     (substitute #\/ #\\
                 (cond ((and local (plusp (length local))) (concatenate 'string local "/modus/kiln"))
                       ((and home (plusp (length home))) (concatenate 'string home "/.cache/modus/kiln"))
                       (t ".modus-kiln"))))))

(defun %kiln-unpack (pack dir)
  "Write every file in PACK under DIR, then the marker that says it is complete."
  (let ((i 0) (n 0))
    (loop while (< i (length pack))
          do (let* ((plen (%kiln-u32 pack i))
                    (path (map 'string #'code-char (subseq pack (+ i 4) (+ i 4 plen))))
                    (dlen (%kiln-u32 pack (+ i 4 plen)))
                    (start (+ i 8 plen))
                    (file (merge-pathnames path dir)))
               (ensure-directories-exist file)
               (with-open-file (s file :direction :output :element-type '(unsigned-byte 8)
                                       :if-exists :supersede)
                 (write-sequence pack s :start start :end (+ start dlen)))
               (incf n)
               (setq i (+ start dlen))))
    (with-open-file (s (merge-pathnames ".complete" dir) :direction :output :if-exists :supersede)
      (format s "~d~%" n))
    n))

(let* ((pack (or (modus-int::ape-segment "kiln/src.pack")
                 (error "kiln: this modus carries kiln/main.lisp but no kiln/src.pack")))
       (exe (modus-int::ape-file))
       (key (format nil "~d-~d" (length pack) (or (ignore-errors (file-write-date exe)) 0)))
       (dir (merge-pathnames (concatenate 'string key "/") (%kiln-cache-root))))
  (unless (probe-file (merge-pathnames ".complete" dir))
    (format t "~&kiln: unpacking into ~a~%" (namestring dir))
    (finish-output)
    (%kiln-unpack pack dir))
  (asdf:initialize-source-registry
   `(:source-registry
     ,@(loop for r in '("cairn" "seal" "conch" "cram" "natrium")
             collect (list :directory (merge-pathnames (concatenate 'string r "/") dir)))
     :ignore-inherited-configuration))
  (handler-bind ((warning #'muffle-warning))
    (let ((*standard-output* (make-broadcast-stream))
          (*error-output* (make-broadcast-stream)))
      (asdf:load-system :cairn)))
  (load (merge-pathnames "kiln/boot/kiln.lisp" dir))
  (funcall (intern "MAIN" "KILN") (cdr sb-ext:*posix-argv*)
           :lock (merge-pathnames "kiln/repos.lock" dir)))
