;;;; android.lisp — the Android app's entry point: glass on the phone's own screen.
;;;; The app itself is boot/app.lisp; this is Android's way to the screen.
;;;;
;;;; Loaded into the world `kiln android' snapshots (boot/ios-world.lisp with
;;;; KILN_APP=android).  The app's modus.args say
;;;;   --core @kiln.core --eval (kiln-android-main)
;;;; On Android the image is not alone in its process: it is the CHILD of the
;;;; app's launcher (modus's host/android/modus-launcher.c), which owns the
;;;; window, the touches, the keyboard and the speaker.  So the calls are not
;;;; syscalls but 16-byte records <op a b c> on fd 3, a socket to the launcher;
;;;; 1001, 1004, 1010 and 1012 read an 8-byte reply.  1005 and 1011 hand iOS's
;;;; shim an ADDRESS; the launcher cannot read our memory, so the data follows
;;;; the record instead -- one tagged 64-bit word per element, written straight
;;;; from the vector (a blit row by row: its rows are STRIDE apart).
;;;;
;;;; Raw syscalls go through %GC-SAFE-BLOCK-6 (aarch64 Linux: mmap 222, read
;;;; 63, write 64).  In CL-USER on purpose, as app.lisp is.

(defvar *kiln-ui-buf* nil "A raw page for the records and replies, mapped on first use.")

(defun %kiln-ui-buf ()
  ;; Mapped at RUN time, on the phone: a page from the world build's process
  ;; would not be in the snapshot.
  (or *kiln-ui-buf* (setf *kiln-ui-buf* (%gc-safe-block-6 222 0 4096 3 #x22))))

(defun %kiln-ui-send (op a b c)
  (let ((p (%kiln-ui-buf)))
    (setf (mem-ref p :u32) op
          (mem-ref (+ p 4) :u32) a
          (mem-ref (+ p 8) :u32) b
          (mem-ref (+ p 12) :u32) c)
    (%gc-safe-block-6 64 3 p 16 0)))

(defun %kiln-ui-reply ()
  ;; Two :u32 halves: a :u64 MEM-REF reads the word as a TAGGED value.
  (let ((p (%kiln-ui-buf)))
    (%gc-safe-block-6 63 3 (+ p 16) 8 0)
    (let ((v (+ (mem-ref (+ p 16) :u32) (* 4294967296 (mem-ref (+ p 20) :u32)))))
      (if (>= v 9223372036854775808) (- v 18446744073709551616) v))))

(defun %kiln-ui-write-all (addr n)
  "Write N bytes at ADDR to the launcher; a large write can come back short."
  (loop while (> n 0)
        do (let ((k (%gc-safe-block-6 64 3 addr n 0)))
             (when (<= k 0) (return))
             (incf addr k)
             (decf n k))))

(defun %kiln-sys (n a b c &optional (d 0))
  (case n
    ;; BLIT: A is the first pixel, B = w | h<<16, C = x | y<<16, D the source's
    ;; row length in pixels (0: rows are contiguous).
    (1005 (let* ((w (logand b #xFFFF)) (h (floor b 65536))
                 (stride (if (zerop d) w d)))
            (%kiln-ui-send 1005 b c (* 8 w h))
            (if (= stride w)
                (%kiln-ui-write-all a (* 8 w h))
                (dotimes (r h) (%kiln-ui-write-all (+ a (* 8 r stride)) (* 8 w))))
            0))
    ;; SPEAKER WRITE: A is the sample vector's first element, B the count.
    (1011 (%kiln-ui-send 1011 b 0 0)
          (%kiln-ui-write-all a (* 8 b))
          0)
    (t (%kiln-ui-send n a b c)
       (if (member n '(1001 1004 1010 1012)) (%kiln-ui-reply) 0))))

(defun kiln-android-main (&key autoplay)
  "The Android app (boot/app.lisp).  The window is full-screen: no status bar above it."
  (kiln-app-main :autoplay autoplay :top 0))
