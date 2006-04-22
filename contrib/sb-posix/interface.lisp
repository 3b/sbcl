(cl:in-package :sb-posix)

(defmacro define-protocol-class
    (name alien-type superclasses slots &rest options)
  (let ((to-protocol (intern (format nil "ALIEN-TO-~A" name)))
        (to-alien (intern (format nil "~A-TO-ALIEN" name))))
    `(progn
      (defclass ,name ,superclasses
        ,(loop for slotd in slots
               collect (ldiff slotd (member :array-length slotd)))
        ,@options)
      (declaim (inline ,to-alien ,to-protocol))
      (defun ,to-protocol (alien &optional instance)
        (declare (type (sb-alien:alien (* ,alien-type)) alien)
                 (type (or null ,name) instance))
        (unless instance
          (setf instance (make-instance ',name)))
        ,@(loop for slotd in slots
                ;; FIXME: slotds in source are more complicated in general
                ;;
                ;; FIXME: baroque construction of intricate fragility
                for array-length = (getf (cdr slotd) :array-length)
                if array-length
                  collect `(progn
                             (let ((array (make-array ,array-length)))
                               (setf (slot-value instance ',(car slotd))
                                     array)
                               (dotimes (i ,array-length)
                                 (setf (aref array i)
                                       (sb-alien:deref
                                        (sb-alien:slot alien ',(car slotd))
                                        i)))))
                else
                  collect `(setf (slot-value instance ',(car slotd))
                                 (sb-alien:slot alien ',(car slotd))))
        instance)
      (defun ,to-alien (instance &optional alien)
        (declare (type (or null (sb-alien:alien (* ,alien-type))) alien)
                 (type ,name instance))
        (unless alien
          (setf alien (sb-alien:make-alien ,alien-type)))
        ,@(loop for slotd in slots
                for array-length = (getf (cdr slotd) :array-length)
                if array-length
                  collect `(progn
                             (let ((array (slot-value instance ',(car slotd))))
                               (dotimes (i ,array-length)
                                 (setf (sb-alien:deref
                                        (sb-alien:slot alien ',(car slotd))
                                        i)
                                       (aref array i)))))
                else
                  collect `(setf (sb-alien:slot alien ',(car slotd))
                                 (slot-value instance ',(car slotd)))))
      (find-class ',name))))

(define-condition sb-posix:syscall-error (error)
  ((errno :initarg :errno :reader sb-posix:syscall-errno))
  (:report (lambda (c s)
             (let ((errno (sb-posix:syscall-errno c)))
               (format s "System call error ~A (~A)"
                       errno (sb-int:strerror errno))))))

(defun syscall-error ()
  (error 'sb-posix:syscall-error :errno (get-errno)))

(declaim (inline never-fails))
(defun never-fails (&rest args)
  (declare (ignore args))
  nil)

;;; filesystem access
(defmacro define-call* (name &rest arguments)
  #-win32 `(define-call ,name ,@arguments)
  #+win32 `(define-call ,(concatenate 'string "_" name) ,@arguments))

(define-call* "access" int minusp (pathname filename) (mode int))
(define-call* "chdir" int minusp (pathname filename))
(define-call* "chmod" int minusp (pathname filename) (mode mode-t))
(define-call* "close" int minusp (fd file-descriptor))
(define-call* "creat" int minusp (pathname filename) (mode mode-t))
(define-call* "dup" int minusp (oldfd file-descriptor))
(define-call* "dup2" int minusp (oldfd file-descriptor)
              (newfd file-descriptor))
(define-call* "lseek" off-t minusp (fd file-descriptor) (offset off-t)
              (whence int))
(define-call* "mkdir" int minusp (pathname filename) (mode mode-t))
(macrolet ((def (x)
               `(progn
                 (define-call-internally open-with-mode ,x int minusp
                   (pathname filename) (flags int) (mode mode-t))
                 (define-call-internally open-without-mode ,x int minusp
                   (pathname filename) (flags int))
                 (define-entry-point ,x
                     (pathname flags &optional (mode nil mode-supplied))
                   (if mode-supplied
                       (open-with-mode pathname flags mode)
                       (open-without-mode pathname flags))))))
    (def #-win32 "open" #+win32 "_open"))
(define-call "rename" int minusp (oldpath filename) (newpath filename))
(define-call* "rmdir" int minusp (pathname filename))
(define-call* "unlink" int minusp (pathname filename))
(define-call "opendir" (* t) null-alien (pathname filename))
(define-call "readdir" (* dirent)
  ;; readdir() has the worst error convention in the world.  It's just
  ;; too painful to support.  (return is NULL _and_ errno "unchanged"
  ;; is not an error, it's EOF).
  not
  (dir (* t)))
(define-call "closedir" int minusp (dir (* t)))
;; need to do this here because we can't do it in the DEFPACKAGE
(define-call* "umask" mode-t never-fails (mode mode-t))
(define-call* "getpid" pid-t never-fails)

#-win32
(progn
  (define-call "chown" int minusp (pathname filename)
               (owner uid-t) (group gid-t))
  (define-call "chroot" int minusp (pathname filename))
  (define-call "fchdir" int minusp (fd file-descriptor))
  (define-call "fchmod" int minusp (fd file-descriptor) (mode mode-t))
  (define-call "fchown" int minusp (fd file-descriptor)
             (owner uid-t)  (group gid-t))
  (define-call "fdatasync" int minusp (fd file-descriptor))
  (define-call "ftruncate" int minusp (fd file-descriptor) (length off-t))
  (define-call "fsync" int minusp (fd file-descriptor))
  (define-call "lchown" int minusp (pathname filename)
               (owner uid-t)  (group gid-t))
  (define-call "link" int minusp (oldpath filename) (newpath filename))
  (define-call "mkfifo" int minusp (pathname filename) (mode mode-t))
  (define-call "symlink" int minusp (oldpath filename) (newpath filename))
  (define-call "sync" void never-fails)
  (define-call "truncate" int minusp (pathname filename) (length off-t))
  ;; FIXME: Windows does have _mktemp, which has a slightlty different
  ;; interface
  (define-call "mkstemp" int minusp (template c-string))
  (define-call-internally ioctl-without-arg "ioctl" int minusp
                          (fd file-descriptor) (cmd int))
  (define-call-internally ioctl-with-int-arg "ioctl" int minusp
                          (fd file-descriptor) (cmd int) (arg int))
  (define-call-internally ioctl-with-pointer-arg "ioctl" int minusp
                          (fd file-descriptor) (cmd int)
                          (arg alien-pointer-to-anything-or-nil))
  (define-entry-point "ioctl" (fd cmd &optional (arg nil argp))
    (if argp
        (etypecase arg
          ((alien int) (ioctl-with-int-arg fd cmd arg))
          ((or (alien (* t)) null) (ioctl-with-pointer-arg fd cmd arg)))
        (ioctl-without-arg fd cmd)))
  (define-call-internally fcntl-without-arg "fcntl" int minusp
                          (fd file-descriptor) (cmd int))
  (define-call-internally fcntl-with-int-arg "fcntl" int minusp
                          (fd file-descriptor) (cmd int) (arg int))
  (define-call-internally fcntl-with-pointer-arg "fcntl" int minusp
                          (fd file-descriptor) (cmd int)
                          (arg alien-pointer-to-anything-or-nil))
  (define-entry-point "fcntl" (fd cmd &optional (arg nil argp))
    (if argp
        (etypecase arg
          ((alien int) (fcntl-with-int-arg fd cmd arg))
          ((or (alien (* t)) null) (fcntl-with-pointer-arg fd cmd arg)))
        (fcntl-without-arg fd cmd)))

  ;; uid, gid
  (define-call "geteuid" uid-t never-fails) ; "always successful", it says
  (define-call "getresuid" uid-t never-fails)
  (define-call "getuid" uid-t never-fails)
  (define-call "seteuid" int minusp (uid uid-t))
  (define-call "setfsuid" int minusp (uid uid-t))
  (define-call "setreuid" int minusp (ruid uid-t) (euid uid-t))
  (define-call "setresuid" int minusp (ruid uid-t) (euid uid-t) (suid uid-t))
  (define-call "setuid" int minusp (uid uid-t))
  (define-call "getegid" gid-t never-fails)
  (define-call "getgid" gid-t never-fails)
  (define-call "getresgid" gid-t never-fails)
  (define-call "setegid" int minusp (gid gid-t))
  (define-call "setfsgid" int minusp (gid gid-t))
  (define-call "setgid" int minusp (gid gid-t))
  (define-call "setregid" int minusp (rgid gid-t) (egid gid-t))
  (define-call "setresgid" int minusp (rgid gid-t) (egid gid-t) (sgid gid-t))

  ;; processes, signals
  (define-call "alarm" int never-fails (seconds unsigned))
  (define-call "fork" pid-t minusp)
  (define-call "getpgid" pid-t minusp (pid pid-t))
  (define-call "getppid" pid-t never-fails)
  (define-call "getpgrp" pid-t never-fails)
  (define-call "getsid" pid-t minusp  (pid pid-t))
  (define-call "kill" int minusp (pid pid-t) (signal int))
  (define-call "killpg" int minusp (pgrp int) (signal int))
  (define-call "pause" int minusp)
  (define-call "setpgid" int minusp (pid pid-t) (pgid pid-t))
  (define-call "setpgrp" int minusp))

;;(define-call "readlink" int minusp (path filename) (buf (* t)) (len int))

#-win32
(progn
 (export 'wait :sb-posix)
 (declaim (inline wait))
 (defun wait (&optional statusptr)
   (declare (type (or null (simple-array (signed-byte 32) (1))) statusptr))
   (let* ((ptr (or statusptr (make-array 1 :element-type '(signed-byte 32))))
          (pid (alien-funcall
                (extern-alien "wait" (function pid-t (* int)))
                (sb-sys:vector-sap ptr))))
     (if (minusp pid)
         (syscall-error)
         (values pid (aref ptr 0))))))

#-win32
(progn
 (export 'waitpid :sb-posix)
 (declaim (inline waitpid))
 (defun waitpid (pid options &optional statusptr)
   (declare (type (sb-alien:alien pid-t) pid)
            (type (sb-alien:alien int) options)
            (type (or null (simple-array (signed-byte 32) (1))) statusptr))
   (let* ((ptr (or statusptr (make-array 1 :element-type '(signed-byte 32))))
          (pid (alien-funcall
                (extern-alien "waitpid" (function pid-t
                                                  pid-t (* int) int))
                pid (sb-sys:vector-sap ptr) options)))
     (if (minusp pid)
         (syscall-error)
         (values pid (aref ptr 0)))))
 ;; waitpid macros
 (define-call "wifexited" boolean never-fails (status int))
 (define-call "wexitstatus" int never-fails (status int))
 (define-call "wifsignaled" boolean never-fails (status int))
 (define-call "wtermsig" int never-fails (status int))
 (define-call "wifstopped" boolean never-fails (status int))
 (define-call "wstopsig" int never-fails (status int))
 #+nil ; see alien/waitpid-macros.c
 (define-call "wifcontinued" boolean never-fails (status int)))

;;; mmap, msync
#-win32
(progn
 (define-call "mmap" sb-sys:system-area-pointer
   (lambda (res)
     (= (sb-sys:sap-int res) #.(1- (expt 2 sb-vm::n-machine-word-bits))))
   (addr sap-or-nil) (length unsigned) (prot unsigned)
   (flags unsigned) (fd file-descriptor) (offset off-t))

 (define-call "munmap" int minusp
   (start sb-sys:system-area-pointer) (length unsigned))

(define-call "msync" int minusp
  (addr sb-sys:system-area-pointer) (length unsigned) (flags int)))

#-win32
(define-call "getpagesize" int minusp)
#+win32
;;; KLUDGE: This could be taken from GetSystemInfo
(export (defun getpagesize () 4096))

;;; passwd database
#-win32
(define-protocol-class passwd alien-passwd ()
  ((name :initarg :name :accessor passwd-name)
   (passwd :initarg :passwd :accessor passwd-passwd)
   (uid :initarg :uid :accessor passwd-uid)
   (gid :initarg :gid :accessor passwd-gid)
   (gecos :initarg :gecos :accessor passwd-gecos)
   (dir :initarg :dir :accessor passwd-dir)
   (shell :initarg :shell :accessor passwd-shell)))

(defmacro define-pw-call (name arg type)
  #-win32
  ;; FIXME: this isn't the documented way of doing this, surely?
  (let ((lisp-name (intern (string-upcase name) :sb-posix)))
    `(progn
      (export ',lisp-name :sb-posix)
      (declaim (inline ,lisp-name))
      (defun ,lisp-name (,arg)
        (let ((r (alien-funcall (extern-alien ,name ,type) ,arg)))
          (if (null r)
              r
              (alien-to-passwd r)))))))

(define-pw-call "getpwnam" login-name (function (* alien-passwd) c-string))
(define-pw-call "getpwuid" uid (function (* alien-passwd) uid-t))

(define-protocol-class stat alien-stat ()
  ((mode :initarg :mode :accessor stat-mode)
   (ino :initarg :ino :accessor stat-ino)
   (dev :initarg :dev :accessor stat-dev)
   (nlink :initarg :nlink :accessor stat-nlink)
   (uid :initarg :uid :accessor stat-uid)
   (gid :initarg :gid :accessor stat-gid)
   (size :initarg :size :accessor stat-size)
   (atime :initarg :atime :accessor stat-atime)
   (mtime :initarg :mtime :accessor stat-mtime)
   (ctime :initarg :ctime :accessor stat-ctime)))

(defmacro define-stat-call (name arg designator-fun type)
  ;; FIXME: this isn't the documented way of doing this, surely?
  (let ((lisp-name (lisp-for-c-symbol name)))
    `(progn
      (export ',lisp-name :sb-posix)
      (declaim (inline ,lisp-name))
      (defun ,lisp-name (,arg &optional stat)
        (declare (type (or null (sb-alien:alien (* alien-stat))) stat))
        (with-alien-stat a-stat ()
          (let ((r (alien-funcall
                    (extern-alien ,name ,type)
                    (,designator-fun ,arg)
                    a-stat)))
            (when (minusp r)
              (syscall-error))
            (alien-to-stat a-stat stat)))))))

(define-stat-call #-win32 "stat" #+win32 "_stat" pathname filename
                  (function int c-string (* alien-stat)))

#-win32
(define-stat-call "lstat" pathname filename
                  (function int c-string (* alien-stat)))
;;; No symbolic links on Windows, so use stat
#+win32
(progn
  (declaim (inline lstat))
  (export (defun lstat (filename &optional stat)
            (if stat (stat filename stat) (stat filename)))))

(define-stat-call #-win32 "fstat" #+win32 "_fstat" fd file-descriptor
                  (function int int (* alien-stat)))


;;; mode flags
(define-call "s_isreg" boolean never-fails (mode mode-t))
(define-call "s_isdir" boolean never-fails (mode mode-t))
(define-call "s_ischr" boolean never-fails (mode mode-t))
(define-call "s_isblk" boolean never-fails (mode mode-t))
(define-call "s_isfifo" boolean never-fails (mode mode-t))
(define-call "s_islnk" boolean never-fails (mode mode-t))
(define-call "s_issock" boolean never-fails (mode mode-t))

#-win32
(progn
 (export 'pipe :sb-posix)
 (declaim (inline pipe))
 (defun pipe (&optional filedes2)
   (declare (type (or null (simple-array (signed-byte 32) (2))) filedes2))
   (unless filedes2
     (setq filedes2 (make-array 2 :element-type '(signed-byte 32))))
   (let ((r (alien-funcall
             ;; FIXME: (* INT)?  (ARRAY INT 2) would be better
             (extern-alien "pipe" (function int (* int)))
             (sb-sys:vector-sap filedes2))))
     (when (minusp r)
       (syscall-error)))
   (values (aref filedes2 0) (aref filedes2 1))))

#-win32
(define-protocol-class termios alien-termios ()
  ((iflag :initarg :iflag :accessor sb-posix:termios-iflag)
   (oflag :initarg :oflag :accessor sb-posix:termios-oflag)
   (cflag :initarg :cflag :accessor sb-posix:termios-cflag)
   (lflag :initarg :lflag :accessor sb-posix:termios-lflag)
   (cc :initarg :cc :accessor sb-posix:termios-cc :array-length nccs)))

#-win32
(progn
 (export 'tcsetattr :sb-posix)
 (declaim (inline tcsetattr))
 (defun tcsetattr (fd actions termios)
   (with-alien-termios a-termios ()
     (termios-to-alien termios a-termios)
     (let ((fd (file-descriptor fd)))
       (let* ((r (alien-funcall
                  (extern-alien
                   "tcsetattr"
                   (function int int int (* alien-termios)))
                  fd actions a-termios)))
         (when (minusp r)
           (syscall-error)))
       (values))))
 (export 'tcgetattr :sb-posix)
 (declaim (inline tcgetattr))
 (defun tcgetattr (fd &optional termios)
   (with-alien-termios a-termios ()
     (let ((r (alien-funcall
               (extern-alien "tcgetattr"
                             (function int int (* alien-termios)))
               (file-descriptor fd)
               a-termios)))
       (when (minusp r)
         (syscall-error))
       (setf termios (alien-to-termios a-termios termios))))
   termios))

;;; environment

(export 'getenv :sb-posix)
(defun getenv (name)
  (let ((r (alien-funcall
            (extern-alien "getenv" (function (* char) c-string))
            name)))
    (declare (type (alien (* char)) r))
    (unless (null-alien r)
      (cast r c-string))))
(define-call "putenv" int minusp (string c-string))
