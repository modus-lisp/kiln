;;;; bundle.lisp -- kiln and its git, cairn, appended to a modus executable, for --kiln.
;;;;
;;;;   modus --script kiln/boot/bundle.lisp IN OUT      (or sbcl --script ... IN OUT)
;;;;
;;;; OUT is IN with two segments after it (modus/scripts/ape-segments.lisp, the trailer
;;;; modus's toplevel reads):
;;;;
;;;;   kiln/main.lisp   boot/main.lisp: what `modus --kiln ...' runs
;;;;   kiln/src.pack    every file kiln needs, read from this workspace: boot/kiln.lisp,
;;;;                    repos.lock, and cairn's closure -- cairn, seal, conch, cram,
;;;;                    natrium (each repo's .asd files, LICENSE and src/)
;;;;
;;;; A pack is a run of entries, each a u32 path length, the path (ASCII, /-separated,
;;;; REPO/PATH), a u32 data length and the data (u32s little-endian).  The files go in
;;;; sorted by path, so the same workspace gives the same bytes on SBCL and on modus.
;;;;
;;;; IN should be a builder (MODUS_BUILDER=1): `--kiln windows' builds modus with the
;;;; executable it runs in, and only a builder carries the cross tooling for that.

(defvar *kiln-dir*
  (merge-pathnames "../" (make-pathname :name nil :type nil :defaults *load-truename*)))
(defvar *workspace* (merge-pathnames "../" *kiln-dir*))

(load (merge-pathnames "modus/scripts/ape-segments.lisp" *workspace*))

(defparameter *closure* '("cairn" "seal" "conch" "cram" "natrium")
  "cairn and what it loads: no third-party dependency anywhere in it.")

(defun bundle-args ()
  (let ((argv (or (and (find-package "SB-EXT")
                       (let ((s (find-symbol "*POSIX-ARGV*" "SB-EXT"))) (and s (symbol-value s))))
                  (error "bundle: no argv"))))
    (let ((args (member-if (lambda (a) (search "bundle.lisp" a)) argv)))
      (if args (cdr args) (last argv 2)))))

(defun read-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((b (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence b s)
      b)))

(defun rel-path (path root)
  (substitute #\/ #\\ (enough-namestring (truename path) (truename root))))

(defun repo-files (repo)
  "REPO's .asd files, LICENSE and everything under src/, as (RELPATH . PATHNAME)."
  (let* ((root (merge-pathnames (concatenate 'string repo "/") *workspace*))
         (files (append (directory (merge-pathnames "*.asd" root))
                        (directory (merge-pathnames "LICENSE" root))
                        (directory (merge-pathnames "src/**/*.*" root)))))
    (unless files (error "bundle: no ~a in ~a" repo *workspace*))
    (loop for f in files
          when (pathname-name f)
            collect (cons (concatenate 'string repo "/" (rel-path f root)) f))))

(defun lf-only (path octets)
  "OCTETS with CR LF as LF when PATH is Lisp source or a lock file: a CRLF checkout (git's
   core.autocrlf on Windows) puts a CR in every FORMAT string's ~<newline>, and the
   unpacked tree must be the repository's bytes.  A Unix checkout is unchanged."
  (if (member (pathname-type path) '("lisp" "asd" "lock") :test #'equal)
      (let ((out (make-array (length octets) :element-type '(unsigned-byte 8) :fill-pointer 0)))
        (dotimes (i (length octets) (coerce out '(simple-array (unsigned-byte 8) (*))))
          (unless (and (= (aref octets i) 13) (< (1+ i) (length octets)) (= (aref octets (1+ i)) 10))
            (vector-push (aref octets i) out))))
      octets))

(defun pack-files (entries)
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (flet ((u32 (n) (dotimes (k 4) (vector-push-extend (ldb (byte 8 (* 8 k)) n) out)))
           (bytes (v) (loop for b across v do (vector-push-extend b out))))
      (dolist (e (sort (copy-list entries) #'string< :key #'car))
        (let ((path (map '(vector (unsigned-byte 8)) #'char-code (car e)))
              (data (lf-only (car e) (read-octets (cdr e)))))
          (u32 (length path)) (bytes path)
          (u32 (length data)) (bytes data))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(let* ((args (bundle-args))
       (in (or (first args) (error "bundle: IN OUT")))
       (out (or (second args) (error "bundle: IN OUT")))
       (entries (append
                 (list (cons "kiln/boot/kiln.lisp" (merge-pathnames "boot/kiln.lisp" *kiln-dir*))
                       (cons "kiln/repos.lock" (merge-pathnames "repos.lock" *kiln-dir*)))
                 (loop for r in *closure* append (repo-files r))))
       (pack (pack-files entries))
       (exe (read-octets in))
       (result (ape-trailer exe (list (cons "kiln/main.lisp"
                                            (read-octets (merge-pathnames "boot/main.lisp" *kiln-dir*)))
                                      (cons "kiln/src.pack" pack)))))
  (with-open-file (s out :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
    (write-sequence result s))
  (format t "bundle: ~a, ~d files (~d KB) after ~a's ~d KB~%"
          out (length entries) (round (length pack) 1024) in (round (length exe) 1024)))
