;;;; zero-card.lisp — the card the Zero booted from, read and written from the board itself.
;;;;
;;;; A kiln zero card is one FAT32 partition: firmware, kernel8.img, desk.core, config.txt and
;;;; cmdline.txt, the line the board's power-on reads (boot/zero-boot.lisp).  This mounts that
;;;; partition through modus's SD driver (net/emmc.lisp: the Arasan controller, read and write)
;;;; and fs-fat's FAT32, on a BLOCK device, so nothing but the sectors a call needs is read --
;;;; the partition is the card's files plus 48 MB, too much to hold in memory.
;;;;
;;;;   (kiln-zero-card:card-files)                          ; what is on the card
;;;;   (kiln-zero-card:card-text "cmdline.txt")             ; a file, as a string
;;;;   (kiln-zero-card:cmdline)                             ; cmdline.txt, as (NAME . VALUE)s
;;;;   (kiln-zero-card:set-bootarg "NET" "static")          ; edit one; NIL removes it
;;;;
;;;; A changed cmdline.txt takes effect at the next power-on.  The card is the one the board
;;;; boots from, so a wrong config.txt or kernel8.img here is a board that does not come up:
;;;; SET-BOOTARG and CARD-WRITE refuse those, (card-write ... :force t) does not.

(defpackage #:kiln-zero-card
  (:use #:cl)
  (:export #:mount #:card-files #:card-read #:card-text #:card-write
           #:cmdline #:bootarg #:set-bootarg))
(in-package #:kiln-zero-card)

(defvar *volume* nil "The mounted boot partition (an fs-fat volume), or NIL.")
(defvar *part-lba* 0 "The partition's first sector on the card.")
(defvar *cache* (make-hash-table) "Sector number -> 512 bytes, as last read or written.")

(defun %kernel (name)
  ;; INTERN, not FIND-SYMBOL: a kernel function nobody has typed has no symbol yet
  (symbol-function (intern name "MODUS-INT")))

(defun %u8 (n) (make-array n :element-type '(unsigned-byte 8)))

(defun %le32 (b o)
  (logior (aref b o) (ash (aref b (+ o 1)) 8) (ash (aref b (+ o 2)) 16) (ash (aref b (+ o 3)) 24)))

(defun %sector (lba)
  "Card sector LBA (absolute), 512 bytes, through the cache."
  (or (gethash lba *cache*)
      (let ((b (%u8 512)))
        (funcall (%kernel "EMMC-READ-SECTORS") lba 1 b 0)
        (when (> (hash-table-count *cache*) 512) (clrhash *cache*))
        (setf (gethash lba *cache*) b))))

(defun %read (off n)
  "N bytes at byte OFF of the partition."
  (let ((out (%u8 n)) (pos 0))
    (loop while (< pos n) do
      (let* ((at (+ off pos)) (lba (+ *part-lba* (floor at 512))) (o (mod at 512))
             (take (min (- 512 o) (- n pos))))
        (replace out (%sector lba) :start1 pos :start2 o :end2 (+ o take))
        (incf pos take)))
    out))

(defun %write (off src)
  "SRC at byte OFF of the partition: within one sector (fs-fat's promise), the rest of the
   sector read and written back with it."
  (let* ((lba (+ *part-lba* (floor off 512))) (b (copy-seq (%sector lba))))
    (replace b src :start1 (mod off 512))
    (funcall (%kernel "EMMC-WRITE-SECTORS") lba 1 b 0)
    (setf (gethash lba *cache*) b)))

(defun mount ()
  "Mount the boot partition (once): (:MOUNTED :FIRST-SECTOR S :BYTES N)."
  (%volume)
  (list :mounted :first-sector *part-lba*
        :bytes (fs-fat:device-size (car (last *volume*)))))

(defun %volume ()
  "The boot partition's fs-fat volume, mounting it the first time: the card brought up,
   the MBR's first partition opened as FAT32."
  (or *volume*
      (progn
        (funcall (%kernel "EMMC-INIT"))
        (clrhash *cache*)
        (setq *part-lba* 0)
        (let ((mbr (%sector 0)))
          (unless (and (= (aref mbr 510) #x55) (= (aref mbr 511) #xAA))
            (error "kiln-zero-card: the card has no partition table"))
          (let ((type (aref mbr #x1C2)) (start (%le32 mbr #x1C6)) (count (%le32 mbr #x1CA)))
            (unless (member type '(#x0B #x0C))
              (error "kiln-zero-card: partition 1 is type ~2,'0X, not FAT32" type))
            (setq *part-lba* start)
            (setq *volume*
                  (fs-fat:fat32-open-device
                   (fs-fat:make-fat32-block-device (* count 512) #'%read #'%write))))))))

(defun %path (name) (if (and (plusp (length name)) (char= (char name 0) #\/)) name (concatenate 'string "/" name)))

(defun card-files (&optional (dir "/"))
  "DIR's entries on the card: (NAME SIZE) for a file, (NAME :DIR) for a directory."
  (mapcar (lambda (e) (if (second e) (list (first e) :dir) (list (first e) (third e))))
          (fs-fat:fat32-directory (%volume) (%path dir))))

(defun card-read (name)
  "File NAME on the card, as bytes, or NIL."
  (fs-fat:fat32-read-file (%volume) (%path name)))

(defun card-text (name)
  "File NAME on the card, as a string, or NIL."
  (let ((b (card-read name)))
    (and b (map 'string #'code-char b))))

(defparameter *vital* '("config.txt" "kernel8.img" "desk.core" "bootcode.bin" "start.elf"
                        "fixup.dat" "start_cd.elf" "fixup_cd.dat")
  "Files a board does not boot without: CARD-WRITE leaves them alone unless forced.")

(defun card-write (name data &key force)
  "Write DATA (a string or bytes) to file NAME on the card, replacing it, and sync."
  (when (and (not force) (member (string-left-trim "/" name) *vital* :test #'string-equal))
    (error "kiln-zero-card: ~a is what the board boots from; (card-write ... :force t) to replace it" name))
  (let ((bytes (if (stringp data) (map '(vector (unsigned-byte 8)) #'char-code data) data))
        (v (%volume)))
    (fs-fat:fat32-write-file v (%path name) bytes)
    (fs-fat:fat32-sync v)
    (length bytes)))

;;; ---- cmdline.txt ----------------------------------------------------------------------------
(defun %words (s)
  (let ((out '()) (start nil))
    (dotimes (i (length s))
      (let ((blank (member (char s i) '(#\Space #\Tab #\Newline #\Return))))
        (cond ((and blank start) (push (subseq s start i) out) (setq start nil))
              ((and (not blank) (not start)) (setq start i)))))
    (when start (push (subseq s start) out))
    (nreverse out)))

(defun cmdline ()
  "The card's cmdline.txt as (NAME . VALUE) pairs, in order; a word with no = is (WORD)."
  (mapcar (lambda (w) (let ((eq (position #\= w)))
                        (if eq (cons (subseq w 0 eq) (subseq w (1+ eq))) (list w))))
          (%words (or (card-text "cmdline.txt") ""))))

(defun bootarg (name)
  "NAME's value in the card's cmdline.txt (what the NEXT power-on reads), or NIL."
  (cdr (assoc name (cmdline) :test #'string=)))

(defun set-bootarg (name value)
  "Set NAME=VALUE in the card's cmdline.txt (VALUE NIL removes it); returns the new line."
  (when (and value (find-if (lambda (c) (member c '(#\Space #\Tab #\Newline))) value))
    (error "kiln-zero-card: a bootarg value has no blanks (lists are comma-separated)"))
  (let* ((args (cmdline)) (hit (assoc name args :test #'string=)))
    (cond ((null value) (setq args (remove name args :key #'car :test #'string=)))
          (hit (setf (cdr hit) value))
          (t (setq args (append args (list (cons name value))))))
    (let ((line (format nil "~{~a~^ ~}"
                        (mapcar (lambda (a) (if (cdr a) (format nil "~a=~a" (car a) (cdr a)) (car a)))
                                args))))
      (card-write "cmdline.txt" (format nil "~a~%" line))
      line)))
