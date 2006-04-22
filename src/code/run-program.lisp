;;;; RUN-PROGRAM and friends, a facility for running Unix programs
;;;; from inside SBCL

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-IMPL") ;(SB-IMPL, not SB!IMPL, since we're built in warm load.)

;;;; hacking the Unix environment
;;;;
;;;; In the original CMU CL code that LOAD-FOREIGN is derived from, the
;;;; Unix environment (as in "man environ") was represented as an
;;;; alist from keywords to strings, so that e.g. the Unix environment
;;;;   "SHELL=/bin/bash" "HOME=/root" "PAGER=less"
;;;; was represented as
;;;;   ((:SHELL . "/bin/bash") (:HOME . "/root") (:PAGER "less"))
;;;; This had a few problems in principle: the mapping into
;;;; keyword symbols smashed the case of environment
;;;; variables, and the whole mapping depended on the presence of
;;;; #\= characters in the environment strings. In practice these
;;;; problems weren't hugely important, since conventionally environment
;;;; variables are uppercase strings followed by #\= followed by
;;;; arbitrary data. However, since it's so manifestly not The Right
;;;; Thing to make code which breaks unnecessarily on input which
;;;; doesn't follow what is, after all, only a tradition, we've switched
;;;; formats in SBCL, so that the fundamental environment list
;;;; is just a list of strings, with a one-to-one-correspondence
;;;; to the C-level representation. I.e., in the example above,
;;;; the SBCL representation is
;;;;   '("SHELL=/bin/bash" "HOME=/root" "PAGER=less")
;;;; CMU CL's implementation is currently supported to help with porting.
;;;;
;;;; It's not obvious that this code belongs here (instead of e.g. in
;;;; unix.lisp), since it has only a weak logical connection with
;;;; RUN-PROGRAM. However, physically it's convenient to put it here.
;;;; It's not needed at cold init, so we *can* put it in this
;;;; warm-loaded file. And by putting it in this warm-loaded file, we
;;;; make it easy for it to get to the C-level 'environ' variable.
;;;; which (at least in sbcl-0.6.10 on Red Hat Linux 6.2) is not
;;;; visible at GENESIS time.

#-win32
(progn
  (define-alien-routine wrapped-environ (* c-string))
  (defun posix-environ ()
    "Return the Unix environment (\"man environ\") as a list of SIMPLE-STRINGs."
    (c-strings->string-list (wrapped-environ))))

;#+win32 (sb-alien:define-alien-routine msvcrt-environ (* c-string))

;;; Convert as best we can from an SBCL representation of a Unix
;;; environment to a CMU CL representation.
;;;
;;; * (UNIX-ENVIRONMENT-CMUCL-FROM-SBCL '("Bletch=fub" "Noggin" "YES=No!"))
;;; WARNING:
;;;   smashing case of "Bletch=fub" in conversion to CMU-CL-style
;;;     environment alist
;;; WARNING:
;;;   no #\= in "Noggin", eliding it in CMU-CL-style environment alist
;;; ((:BLETCH . "fub") (:YES . "No!"))
(defun unix-environment-cmucl-from-sbcl (sbcl)
  (mapcan
   (lambda (string)
     (declare (type simple-base-string string))
     (let ((=-pos (position #\= string :test #'equal)))
       (if =-pos
           (list
            (let* ((key-as-string (subseq string 0 =-pos))
                   (key-as-upcase-string (string-upcase key-as-string))
                   (key (keywordicate key-as-upcase-string))
                   (val (subseq string (1+ =-pos))))
              (unless (string= key-as-string key-as-upcase-string)
                (warn "smashing case of ~S in conversion to CMU-CL-style ~
                      environment alist"
                      string))
              (cons key val)))
           (warn "no #\\= in ~S, eliding it in CMU-CL-style environment alist"
                 string))))
   sbcl))

;;; Convert from a CMU CL representation of a Unix environment to a
;;; SBCL representation.
(defun unix-environment-sbcl-from-cmucl (cmucl)
  (mapcar
   (lambda (cons)
     (destructuring-bind (key . val) cons
       (declare (type keyword key) (type simple-base-string val))
       (concatenate 'simple-base-string (symbol-name key) "=" val)))
   cmucl))

;;;; Import wait3(2) from Unix.

#-win32
(define-alien-routine ("wait3" c-wait3) sb-alien:int
  (status sb-alien:int :out)
  (options sb-alien:int)
  (rusage sb-alien:int))

#-win32
(defun wait3 (&optional do-not-hang check-for-stopped)
  #+sb-doc
  "Return any available status information on child process. "
  (multiple-value-bind (pid status)
      (c-wait3 (logior (if do-not-hang
                           sb-unix:wnohang
                           0)
                       (if check-for-stopped
                           sb-unix:wuntraced
                           0))
               0)
    (cond ((or (minusp pid)
               (zerop pid))
           nil)
          ((eql (ldb (byte 8 0) status)
                sb-unix:wstopped)
           (values pid
                   :stopped
                   (ldb (byte 8 8) status)))
          ((zerop (ldb (byte 7 0) status))
           (values pid
                   :exited
                   (ldb (byte 8 8) status)))
          (t
           (let ((signal (ldb (byte 7 0) status)))
             (values pid
                     (if (position signal
                                   #.(vector
                                      sb-unix:sigstop
                                      sb-unix:sigtstp
                                      sb-unix:sigttin
                                      sb-unix:sigttou))
                         :stopped
                         :signaled)
                     signal
                     (not (zerop (ldb (byte 1 7) status)))))))))

;;;; process control stuff
(defvar *active-processes* nil
  #+sb-doc
  "List of process structures for all active processes.")

#-win32
(defvar *active-processes-lock*
  (sb-thread:make-mutex :name "Lock for active processes."))

;;; *ACTIVE-PROCESSES* can be accessed from multiple threads so a
;;; mutex is needed. More importantly the sigchld signal handler also
;;; accesses it, that's why we need without-interrupts.
(defmacro with-active-processes-lock (() &body body)
  #-win32
  `(without-interrupts
    (sb-thread:with-mutex (*active-processes-lock*)
      ,@body))
  #+win32
  `(progn ,@body))

(defstruct (process (:copier nil))
  pid                 ; PID of child process
  %status             ; either :RUNNING, :STOPPED, :EXITED, or :SIGNALED
  exit-code           ; either exit code or signal
  core-dumped         ; T if a core image was dumped
  #-win32 pty                 ; stream to child's pty, or NIL
  input               ; stream to child's input, or NIL
  output              ; stream from child's output, or NIL
  error               ; stream from child's error output, or NIL
  status-hook         ; closure to call when PROC changes status
  plist               ; a place for clients to stash things
  cookie)             ; list of the number of pipes from the subproc

(defmethod print-object ((process process) stream)
  (print-unreadable-object (process stream :type t)
    (let ((status (process-status process)))
     (if (eq :exited status)
         (format stream "~S ~S" status (process-exit-code process))
         (format stream "~S ~S" (process-pid process) status)))
    process))

#+sb-doc
(setf (documentation 'process-p 'function)
      "T if OBJECT is a PROCESS, NIL otherwise.")

#+sb-doc
(setf (documentation 'process-pid 'function) "The pid of the child process.")

#+win32
(define-alien-routine ("GetExitCodeProcess@8" get-exit-code-process)
    int
  (handle unsigned) (exit-code unsigned :out))

(defun process-status (process)
  #+sb-doc
  "Return the current status of PROCESS.  The result is one of :RUNNING,
   :STOPPED, :EXITED, or :SIGNALED."
  (get-processes-status-changes)
  (process-%status process))

#+sb-doc
(setf (documentation 'process-exit-code 'function)
      "The exit code or the signal of a stopped process.")

#+sb-doc
(setf (documentation 'process-core-dumped 'function)
      "T if a core image was dumped by the process.")

#+sb-doc
(setf (documentation 'process-pty 'function)
      "The pty stream of the process or NIL.")

#+sb-doc
(setf (documentation 'process-input 'function)
      "The input stream of the process or NIL.")

#+sb-doc
(setf (documentation 'process-output 'function)
      "The output stream of the process or NIL.")

#+sb-doc
(setf (documentation 'process-error 'function)
      "The error stream of the process or NIL.")

#+sb-doc
(setf (documentation 'process-status-hook  'function)
      "A function that is called when PROCESS changes its status.
The function is called with PROCESS as its only argument.")

#+sb-doc
(setf (documentation 'process-plist  'function)
      "A place for clients to stash things.")

(defun process-wait (process &optional check-for-stopped)
  #+sb-doc
  "Wait for PROCESS to quit running for some reason. When
CHECK-FOR-STOPPED is T, also returns when PROCESS is stopped. Returns
PROCESS."
  (loop
      (case (process-status process)
        (:running)
        (:stopped
         (when check-for-stopped
           (return)))
        (t
         (when (zerop (car (process-cookie process)))
           (return))))
      (sb-sys:serve-all-events 1))
  process)

#-(or hpux win32)
;;; Find the current foreground process group id.
(defun find-current-foreground-process (proc)
  (with-alien ((result sb-alien:int))
    (multiple-value-bind
          (wonp error)
        (sb-unix:unix-ioctl (sb-sys:fd-stream-fd (process-pty proc))
                            sb-unix:TIOCGPGRP
                            (alien-sap (sb-alien:addr result)))
      (unless wonp
        (error "TIOCPGRP ioctl failed: ~S" (strerror error)))
      result))
  (process-pid proc))

#-win32
(defun process-kill (process signal &optional (whom :pid))
  #+sb-doc
  "Hand SIGNAL to PROCESS. If WHOM is :PID, use the kill Unix system call. If
   WHOM is :PROCESS-GROUP, use the killpg Unix system call. If WHOM is
   :PTY-PROCESS-GROUP deliver the signal to whichever process group is
   currently in the foreground."
  (let ((pid (ecase whom
               ((:pid :process-group)
                (process-pid process))
               (:pty-process-group
                #-hpux
                (find-current-foreground-process process)))))
    (multiple-value-bind
          (okay errno)
        (case whom
          #+hpux
          (:pty-process-group
           (sb-unix:unix-ioctl (sb-sys:fd-stream-fd (process-pty process))
                               sb-unix:TIOCSIGSEND
                               (sb-sys:int-sap
                                signal)))
          ((:process-group #-hpux :pty-process-group)
           (sb-unix:unix-killpg pid signal))
          (t
           (sb-unix:unix-kill pid signal)))
      (cond ((not okay)
             (values nil errno))
            ((and (eql pid (process-pid process))
                  (= signal sb-unix:sigcont))
             (setf (process-%status process) :running)
             (setf (process-exit-code process) nil)
             (when (process-status-hook process)
               (funcall (process-status-hook process) process))
             t)
            (t
             t)))))

(defun process-alive-p (process)
  #+sb-doc
  "Return T if PROCESS is still alive, NIL otherwise."
  (let ((status (process-status process)))
    (if (or (eq status :running)
            (eq status :stopped))
        t
        nil)))

(defun process-close (process)
  #+sb-doc
  "Close all streams connected to PROCESS and stop maintaining the
status slot."
  (macrolet ((frob (stream abort)
               `(when ,stream (close ,stream :abort ,abort))))
    #-win32
    (frob (process-pty process) t)   ; Don't FLUSH-OUTPUT to dead process,
    (frob (process-input process) t) ; .. 'cause it will generate SIGPIPE.
    (frob (process-output process) nil)
    (frob (process-error process) nil))
  ;; FIXME: Given that the status-slot is no longer updated,
  ;; maybe it should be set to :CLOSED, or similar?
  (with-active-processes-lock ()
   (setf *active-processes* (delete process *active-processes*)))
  process)

;;; the handler for SIGCHLD signals that RUN-PROGRAM establishes
#-win32
(defun sigchld-handler (ignore1 ignore2 ignore3)
  (declare (ignore ignore1 ignore2 ignore3))
  (get-processes-status-changes))

(defun get-processes-status-changes ()
  #-win32
  (loop
   (multiple-value-bind (pid what code core)
       (wait3 t t)
     (unless pid
       (return))
     (let ((proc (with-active-processes-lock ()
                   (find pid *active-processes* :key #'process-pid))))
       (when proc
         (setf (process-%status proc) what)
         (setf (process-exit-code proc) code)
         (setf (process-core-dumped proc) core)
         (when (process-status-hook proc)
           (funcall (process-status-hook proc) proc))
         (when (position what #(:exited :signaled))
           (with-active-processes-lock ()
             (setf *active-processes*
                   (delete proc *active-processes*))))))))
  #+win32
  (let (exited)
    (with-active-processes-lock ()
      (setf *active-processes*
            (delete-if (lambda (proc)
                         (multiple-value-bind (ok code)
                             (get-exit-code-process (process-pid proc))
                           (when (and (plusp ok) (/= code 259))
                             (setf (process-%status proc) :exited
                                   (process-exit-code proc) code)
                             (when (process-status-hook proc)
                               (push proc exited))
                             t)))
                       *active-processes*)))
    ;; Can't call the hooks before all the processes have been deal
    ;; with, as calling a hook may cause re-entry to
    ;; GET-PROCESS-STATUS-CHANGES. That may be OK when using wait3,
    ;; but in the Windows implementation is would be deeply bad.
    (dolist (proc exited)
      (let ((hook (process-status-hook proc)))
        (when hook
          (funcall hook proc))))))

;;;; RUN-PROGRAM and close friends

;;; list of file descriptors to close when RUN-PROGRAM exits due to an error
(defvar *close-on-error* nil)

;;; list of file descriptors to close when RUN-PROGRAM returns in the parent
(defvar *close-in-parent* nil)

;;; list of handlers installed by RUN-PROGRAM
#-win32
(defvar *handlers-installed* nil)

;;; Find an unused pty. Return three values: the file descriptor for
;;; the master side of the pty, the file descriptor for the slave side
;;; of the pty, and the name of the tty device for the slave side.
#-win32
(defun find-a-pty ()
  (dolist (char '(#\p #\q))
    (dotimes (digit 16)
      (let* ((master-name (coerce (format nil "/dev/pty~C~X" char digit) 'base-string))
             (master-fd (sb-unix:unix-open master-name
                                           sb-unix:o_rdwr
                                           #o666)))
        (when master-fd
          (let* ((slave-name (coerce (format nil "/dev/tty~C~X" char digit) 'base-string))
                 (slave-fd (sb-unix:unix-open slave-name
                                              sb-unix:o_rdwr
                                              #o666)))
            (when slave-fd
              (return-from find-a-pty
                (values master-fd
                        slave-fd
                        slave-name)))
            (sb-unix:unix-close master-fd))))))
  (error "could not find a pty"))

#-win32
(defun open-pty (pty cookie)
  (when pty
    (multiple-value-bind
          (master slave name)
        (find-a-pty)
      (push master *close-on-error*)
      (push slave *close-in-parent*)
      (when (streamp pty)
        (multiple-value-bind (new-fd errno) (sb-unix:unix-dup master)
          (unless new-fd
            (error "couldn't SB-UNIX:UNIX-DUP ~W: ~A" master (strerror errno)))
          (push new-fd *close-on-error*)
          (copy-descriptor-to-stream new-fd pty cookie)))
      (values name
              (sb-sys:make-fd-stream master :input t :output t
                                     :element-type :default
                                     :dual-channel-p t)))))

(defmacro round-bytes-to-words (n)
  `(logand (the fixnum (+ (the fixnum ,n) 3)) (lognot 3)))

(defun string-list-to-c-strvec (string-list)
  ;; Make a pass over STRING-LIST to calculate the amount of memory
  ;; needed to hold the strvec.
  (let ((string-bytes 0)
        ;; We need an extra for the null, and an extra 'cause exect
        ;; clobbers argv[-1].
        (vec-bytes (* #.(/ sb-vm::n-machine-word-bits sb-vm::n-byte-bits)
                      (+ (length string-list) 2))))
    (declare (fixnum string-bytes vec-bytes))
    (dolist (s string-list)
      (enforce-type s simple-string)
      (incf string-bytes (round-bytes-to-words (1+ (length s)))))
    ;; Now allocate the memory and fill it in.
    (let* ((total-bytes (+ string-bytes vec-bytes))
           (vec-sap (sb-sys:allocate-system-memory total-bytes))
           (string-sap (sap+ vec-sap vec-bytes))
           (i #.(/ sb-vm::n-machine-word-bits sb-vm::n-byte-bits)))
      (declare (type (and unsigned-byte fixnum) total-bytes i)
               (type sb-sys:system-area-pointer vec-sap string-sap))
      (dolist (s string-list)
        (declare (simple-string s))
        (let ((n (length s)))
          ;; Blast the string into place.
          (sb-kernel:copy-ub8-to-system-area (the simple-base-string
                                               ;; FIXME
                                               (coerce s 'simple-base-string))
                                             0
                                             string-sap 0
                                             (1+ n))
          ;; Blast the pointer to the string into place.
          (setf (sap-ref-sap vec-sap i) string-sap)
          (setf string-sap (sap+ string-sap (round-bytes-to-words (1+ n))))
          (incf i #.(/ sb-vm::n-machine-word-bits sb-vm::n-byte-bits))))
      ;; Blast in the last null pointer.
      (setf (sap-ref-sap vec-sap i) (int-sap 0))
      (values vec-sap (sap+ vec-sap #.(/ sb-vm::n-machine-word-bits
                                         sb-vm::n-byte-bits))
              total-bytes))))

(defmacro with-c-strvec ((var str-list) &body body)
  (with-unique-names (sap size)
    `(multiple-value-bind
      (,sap ,var ,size)
      (string-list-to-c-strvec ,str-list)
      (unwind-protect
           (progn
             ,@body)
        (sb-sys:deallocate-system-memory ,sap ,size)))))

#-win32
(sb-alien:define-alien-routine spawn sb-alien:int
  (program sb-alien:c-string)
  (argv (* sb-alien:c-string))
  (envp (* sb-alien:c-string))
  (pty-name sb-alien:c-string)
  (stdin sb-alien:int)
  (stdout sb-alien:int)
  (stderr sb-alien:int))

#+win32
(sb-alien:define-alien-routine spawn sb-win32::handle
  (program sb-alien:c-string)
  (argv (* sb-alien:c-string))
  (stdin sb-alien:int)
  (stdout sb-alien:int)
  (stderr sb-alien:int)
  (wait sb-alien:int))

;;; Is UNIX-FILENAME the name of a file that we can execute?
(defun unix-filename-is-executable-p (unix-filename)
  (let ((filename (coerce unix-filename 'base-string)))
    (values (and (eq (sb-unix:unix-file-kind filename) :file)
                 #-win32
                 (sb-unix:unix-access filename sb-unix:x_ok)))))

(defun find-executable-in-search-path (pathname &optional
                                       (search-path (posix-getenv "PATH")))
  #+sb-doc
  "Find the first executable file matching PATHNAME in any of the
colon-separated list of pathnames SEARCH-PATH"
  (let ((program #-win32 pathname
                 #+win32 (merge-pathnames pathname (make-pathname :type "exe"))))
   (loop for end =  (position #-win32 #\: #+win32 #\; search-path
                              :start (if end (1+ end) 0))
         and start = 0 then (and end (1+ end))
         while start
         ;; <Krystof> the truename of a file naming a directory is the
         ;; directory, at least until pfdietz comes along and says why
         ;; that's noncompliant  -- CSR, c. 2003-08-10
         for truename = (probe-file (subseq search-path start end))
         for fullpath = (when truename
                          (unix-namestring (merge-pathnames program truename)))
         when (and fullpath (unix-filename-is-executable-p fullpath))
         return fullpath)))

;;; FIXME: There shouldn't be two semiredundant versions of the
;;; documentation. Since this is a public extension function, the
;;; documentation should be in the doc string. So all information from
;;; this comment should be merged into the doc string, and then this
;;; comment can go away.
;;;
;;; RUN-PROGRAM uses fork() and execve() to run a different program.
;;; Strange stuff happens to keep the Unix state of the world
;;; coherent.
;;;
;;; The child process needs to get its input from somewhere, and send
;;; its output (both standard and error) to somewhere. We have to do
;;; different things depending on where these somewheres really are.
;;;
;;; For input, there are five options:
;;;  -- T: Just leave fd 0 alone. Pretty simple.
;;;  -- "file": Read from the file. We need to open the file and
;;;     pull the descriptor out of the stream. The parent should close
;;;     this stream after the child is up and running to free any
;;;     storage used in the parent.
;;;  -- NIL: Same as "file", but use "/dev/null" as the file.
;;;  -- :STREAM: Use Unix pipe() to create two descriptors. Use
;;;     SB-SYS:MAKE-FD-STREAM to create the output stream on the
;;;     writeable descriptor, and pass the readable descriptor to
;;;     the child. The parent must close the readable descriptor for
;;;     EOF to be passed up correctly.
;;;  -- a stream: If it's a fd-stream, just pull the descriptor out
;;;     of it. Otherwise make a pipe as in :STREAM, and copy
;;;     everything across.
;;;
;;; For output, there are five options:
;;;  -- T: Leave descriptor 1 alone.
;;;  -- "file": dump output to the file.
;;;  -- NIL: dump output to /dev/null.
;;;  -- :STREAM: return a stream that can be read from.
;;;  -- a stream: if it's a fd-stream, use the descriptor in it.
;;;     Otherwise, copy stuff from output to stream.
;;;
;;; For error, there are all the same options as output plus:
;;;  -- :OUTPUT: redirect to the same place as output.
;;;
;;; RUN-PROGRAM returns a PROCESS structure for the process if
;;; the fork worked, and NIL if it did not.

#-win32
(defun run-program (program args
                    &key
                    (env nil env-p)
                    (environment (if env-p
                                     (unix-environment-sbcl-from-cmucl env)
                                     (posix-environ))
                                 environment-p)
                    (wait t)
                    search
                    pty
                    input
                    if-input-does-not-exist
                    output
                    (if-output-exists :error)
                    (error :output)
                    (if-error-exists :error)
                    status-hook)
  #+sb-doc
  "RUN-PROGRAM creates a new Unix process running the Unix program
found in the file specified by the PROGRAM argument. ARGS are the
standard arguments that can be passed to a Unix program. For no
arguments, use NIL (which means that just the name of the program is
passed as arg 0).

RUN-PROGRAM will return a PROCESS structure. See the CMU Common Lisp
Users Manual for details about the PROCESS structure.

   Notes about Unix environments (as in the :ENVIRONMENT and :ENV args):

   - The SBCL implementation of RUN-PROGRAM, like Perl and many other
     programs, but unlike the original CMU CL implementation, copies
     the Unix environment by default.

   - Running Unix programs from a setuid process, or in any other
     situation where the Unix environment is under the control of someone
     else, is a mother lode of security problems. If you are contemplating
     doing this, read about it first. (The Perl community has a lot of good
     documentation about this and other security issues in script-like
     programs.)

   The &KEY arguments have the following meanings:

   :ENVIRONMENT
      a list of SIMPLE-BASE-STRINGs describing the new Unix environment
      (as in \"man environ\"). The default is to copy the environment of
      the current process.
   :ENV
      an alternative lossy representation of the new Unix environment,
      for compatibility with CMU CL
   :SEARCH
      Look for PROGRAM in each of the directories along the $PATH
      environment variable.  Otherwise an absolute pathname is required.
      (See also FIND-EXECUTABLE-IN-SEARCH-PATH)
   :WAIT
      If non-NIL (default), wait until the created process finishes.  If
      NIL, continue running Lisp until the program finishes.
   :PTY
      Either T, NIL, or a stream.  Unless NIL, the subprocess is established
      under a PTY.  If :pty is a stream, all output to this pty is sent to
      this stream, otherwise the PROCESS-PTY slot is filled in with a stream
      connected to pty that can read output and write input.
   :INPUT
      Either T, NIL, a pathname, a stream, or :STREAM.  If T, the standard
      input for the current process is inherited.  If NIL, /dev/null
      is used.  If a pathname, the file so specified is used.  If a stream,
      all the input is read from that stream and send to the subprocess.  If
      :STREAM, the PROCESS-INPUT slot is filled in with a stream that sends
      its output to the process. Defaults to NIL.
   :IF-INPUT-DOES-NOT-EXIST (when :INPUT is the name of a file)
      can be one of:
         :ERROR to generate an error
         :CREATE to create an empty file
         NIL (the default) to return NIL from RUN-PROGRAM
   :OUTPUT
      Either T, NIL, a pathname, a stream, or :STREAM.  If T, the standard
      output for the current process is inherited.  If NIL, /dev/null
      is used.  If a pathname, the file so specified is used.  If a stream,
      all the output from the process is written to this stream. If
      :STREAM, the PROCESS-OUTPUT slot is filled in with a stream that can
      be read to get the output. Defaults to NIL.
   :IF-OUTPUT-EXISTS (when :OUTPUT is the name of a file)
      can be one of:
         :ERROR (the default) to generate an error
         :SUPERSEDE to supersede the file with output from the program
         :APPEND to append output from the program to the file
         NIL to return NIL from RUN-PROGRAM, without doing anything
   :ERROR and :IF-ERROR-EXISTS
      Same as :OUTPUT and :IF-OUTPUT-EXISTS, except that :ERROR can also be
      specified as :OUTPUT in which case all error output is routed to the
      same place as normal output.
   :STATUS-HOOK
      This is a function the system calls whenever the status of the
      process changes.  The function takes the process as an argument."
  (when (and env-p environment-p)
    (error "can't specify :ENV and :ENVIRONMENT simultaneously"))
  ;; Make sure that the interrupt handler is installed.
  (sb-sys:enable-interrupt sb-unix:sigchld #'sigchld-handler)
  ;; Prepend the program to the argument list.
  (push (namestring program) args)
  (let (;; Clear various specials used by GET-DESCRIPTOR-FOR to
        ;; communicate cleanup info.
        *close-on-error*
        *close-in-parent*
        *handlers-installed*
        ;; Establish PROC at this level so that we can return it.
        proc
        ;; It's friendly to allow the caller to pass any string
        ;; designator, but internally we'd like SIMPLE-STRINGs.
        (simple-args (mapcar (lambda (x) (coerce x 'simple-string)) args)))
    (unwind-protect
         (let ((pfile
                (if search
                    (find-executable-in-search-path program)
                    (unix-namestring program)))
               (cookie (list 0)))
           (unless pfile
             (error "no such program: ~S" program))
           (unless (unix-filename-is-executable-p pfile)
             (error "not executable: ~S" program))
           (multiple-value-bind (stdin input-stream)
               (get-descriptor-for input cookie
                                   :direction :input
                                   :if-does-not-exist if-input-does-not-exist)
             (multiple-value-bind (stdout output-stream)
                 (get-descriptor-for output cookie
                                     :direction :output
                                     :if-exists if-output-exists)
               (multiple-value-bind (stderr error-stream)
                   (if (eq error :output)
                       (values stdout output-stream)
                       (get-descriptor-for error cookie
                                           :direction :output
                                           :if-exists if-error-exists))
                 (multiple-value-bind (pty-name pty-stream)
                     (open-pty pty cookie)
                   ;; Make sure we are not notified about the child
                   ;; death before we have installed the PROCESS
                   ;; structure in *ACTIVE-PROCESSES*.
                   (with-active-processes-lock ()
                    (with-c-strvec (args-vec simple-args)
                      (with-c-strvec (environment-vec environment)
                        (let ((child-pid
                               (without-gcing
                                (spawn pfile args-vec environment-vec pty-name
                                       stdin stdout stderr))))
                          (when (< child-pid 0)
                            (error "couldn't fork child process: ~A"
                                   (strerror)))
                          (setf proc (make-process :pid child-pid
                                                   :%status :running
                                                   :pty pty-stream
                                                   :input input-stream
                                                   :output output-stream
                                                   :error error-stream
                                                   :status-hook status-hook
                                                   :cookie cookie))
                          (push proc *active-processes*))))))))))
      (dolist (fd *close-in-parent*)
        (sb-unix:unix-close fd))
      (unless proc
        (dolist (fd *close-on-error*)
          (sb-unix:unix-close fd))
        (dolist (handler *handlers-installed*)
          (sb-sys:remove-fd-handler handler))))
    (when (and wait proc)
      (process-wait proc))
    proc))

#+win32
(defun run-program (program args
                    &key
                    (wait t)
                    search
                    input
                    if-input-does-not-exist
                    output
                    (if-output-exists :error)
                    (error :output)
                    (if-error-exists :error)
                    status-hook)
  "RUN-PROGRAM creates a new process specified by the PROGRAM
argument. ARGS are the standard arguments that can be passed to a
program. For no arguments, use NIL (which means that just the name of
the program is passed as arg 0).

RUN-PROGRAM will either return a PROCESS structure. See the CMU
Common Lisp Users Manual for details about the PROCESS structure.

   The &KEY arguments have the following meanings:
     :SEARCH
        Look for PROGRAM in each of the directories along the $PATH
        environment variable.  Otherwise an absolute pathname is required.
        (See also FIND-EXECUTABLE-IN-SEARCH-PATH)
     :WAIT
        If non-NIL (default), wait until the created process finishes.  If
        NIL, continue running Lisp until the program finishes.
     :INPUT
        Either T, NIL, a pathname, a stream, or :STREAM.  If T, the standard
        input for the current process is inherited.  If NIL, /dev/null
        is used.  If a pathname, the file so specified is used.  If a stream,
        all the input is read from that stream and send to the subprocess.  If
        :STREAM, the PROCESS-INPUT slot is filled in with a stream that sends
        its output to the process. Defaults to NIL.
     :IF-INPUT-DOES-NOT-EXIST (when :INPUT is the name of a file)
        can be one of:
           :ERROR to generate an error
           :CREATE to create an empty file
           NIL (the default) to return NIL from RUN-PROGRAM
     :OUTPUT
        Either T, NIL, a pathname, a stream, or :STREAM.  If T, the standard
        output for the current process is inherited.  If NIL, /dev/null
        is used.  If a pathname, the file so specified is used.  If a stream,
        all the output from the process is written to this stream. If
        :STREAM, the PROCESS-OUTPUT slot is filled in with a stream that can
        be read to get the output. Defaults to NIL.
     :IF-OUTPUT-EXISTS (when :OUTPUT is the name of a file)
        can be one of:
           :ERROR (the default) to generate an error
           :SUPERSEDE to supersede the file with output from the program
           :APPEND to append output from the program to the file
           NIL to return NIL from RUN-PROGRAM, without doing anything
     :ERROR and :IF-ERROR-EXISTS
        Same as :OUTPUT and :IF-OUTPUT-EXISTS, except that :ERROR can also be
        specified as :OUTPUT in which case all error output is routed to the
        same place as normal output.
     :STATUS-HOOK
        This is a function the system calls whenever the status of the
        process changes.  The function takes the process as an argument."
  ;; Prepend the program to the argument list.
  (push (namestring program) args)
  (let (;; Clear various specials used by GET-DESCRIPTOR-FOR to
        ;; communicate cleanup info.
        *close-on-error*
        *close-in-parent*
        ;; Establish PROC at this level so that we can return it.
        proc
        ;; It's friendly to allow the caller to pass any string
        ;; designator, but internally we'd like SIMPLE-STRINGs.
        (simple-args (mapcar (lambda (x) (coerce x 'simple-string)) args)))
    (unwind-protect
         (let ((pfile
                (if search
                    (find-executable-in-search-path program)
                    (unix-namestring program)))
               (cookie (list 0)))
           (unless pfile
             (error "No such program: ~S" program))
           (unless (unix-filename-is-executable-p pfile)
             (error "Not an executable: ~S" program))
           (multiple-value-bind (stdin input-stream)
               (get-descriptor-for input cookie
                                   :direction :input
                                   :if-does-not-exist if-input-does-not-exist)
             (multiple-value-bind (stdout output-stream)
                 (get-descriptor-for output cookie
                                     :direction :output
                                     :if-exists if-output-exists)
               (multiple-value-bind (stderr error-stream)
                   (if (eq error :output)
                       (values stdout output-stream)
                       (get-descriptor-for error cookie
                                           :direction :output
                                           :if-exists if-error-exists))
                    (with-c-strvec (args-vec simple-args)
                          (let ((handle (without-gcing
                                         (spawn pfile args-vec
                                                stdin stdout stderr
                                                (if wait 1 0)))))
                            (when (< handle 0)
                              (error "Couldn't spawn program: ~A" (strerror)))
                            (setf proc
                                  (if wait
                                      (make-process :%status :exited
                                                    :exit-code handle)
                                      (make-process :pid handle
                                                    :%status :running
                                                    :input input-stream
                                                    :output output-stream
                                                    :error error-stream
                                                    :status-hook status-hook
                                                    :cookie cookie))))))))))
    ;; FIXME: this should probably use PROCESS-WAIT instead instead
    ;; of special argument to SPAWN.
    (unless wait
      (push proc *active-processes*))
    (when (and wait status-hook)
      (funcall status-hook proc))
    proc))

;;; Install a handler for any input that shows up on the file
;;; descriptor. The handler reads the data and writes it to the
;;; stream.
(defun copy-descriptor-to-stream (descriptor stream cookie)
  (incf (car cookie))
  (let ((string (make-string 256 :element-type 'base-char))
        handler)
    (setf handler
          (sb-sys:add-fd-handler
           descriptor
           :input (lambda (fd)
                    (declare (ignore fd))
                    (loop
                     (unless handler
                       (return))
                     (multiple-value-bind
                         (result readable/errno)
                         (sb-unix:unix-select (1+ descriptor)
                                              (ash 1 descriptor)
                                              0 0 0)
                       (cond ((null result)
                              (error "~@<couldn't select on sub-process: ~
                                           ~2I~_~A~:>"
                                     (strerror readable/errno)))
                             ((zerop result)
                              (return))))
                     (sb-alien:with-alien ((buf (sb-alien:array
                                                 sb-alien:char
                                                 256)))
                       (multiple-value-bind
                           (count errno)
                           (sb-unix:unix-read descriptor
                                              (alien-sap buf)
                                              256)
                           (cond (#-win32(or (and (null count)
                                                  (eql errno sb-unix:eio))
                                             (eql count 0))
                                         #+win32(<= count 0)
                                (sb-sys:remove-fd-handler handler)
                                (setf handler nil)
                                (decf (car cookie))
                                (sb-unix:unix-close descriptor)
                                (return))
                               ((null count)
                                (sb-sys:remove-fd-handler handler)
                                (setf handler nil)
                                (decf (car cookie))
                                (error
                                 "~@<couldn't read input from sub-process: ~
                                     ~2I~_~A~:>"
                                 (strerror errno)))
                               (t
                                (sb-kernel:copy-ub8-from-system-area
                                 (alien-sap buf) 0
                                 string 0
                                 count)
                                (write-string string stream
                                              :end count)))))))))))

;;; Find a file descriptor to use for object given the direction.
;;; Returns the descriptor. If object is :STREAM, returns the created
;;; stream as the second value.
(defun get-descriptor-for (object
                           cookie
                           &rest keys
                           &key direction
                           &allow-other-keys)
  (cond ((eq object t)
         ;; No new descriptor is needed.
         (values -1 nil))
        ((eq object nil)
         ;; Use /dev/null.
         (multiple-value-bind
               (fd errno)
             (sb-unix:unix-open #-win32 #.(coerce "/dev/null" 'base-string)
                                #+win32 #.(coerce "nul" 'base-string)
                                (case direction
                                  (:input sb-unix:o_rdonly)
                                  (:output sb-unix:o_wronly)
                                  (t sb-unix:o_rdwr))
                                #o666)
           (unless fd
             (error "~@<couldn't open \"/dev/null\": ~2I~_~A~:>"
                    (strerror errno)))
           (push fd *close-in-parent*)
           (values fd nil)))
        ((eq object :stream)
         (multiple-value-bind (read-fd write-fd) (sb-unix:unix-pipe)
           (unless read-fd
             (error "couldn't create pipe: ~A" (strerror write-fd)))
           (case direction
             (:input
              (push read-fd *close-in-parent*)
              (push write-fd *close-on-error*)
              (let ((stream (sb-sys:make-fd-stream write-fd :output t
                                                   :element-type :default)))
                (values read-fd stream)))
             (:output
              (push read-fd *close-on-error*)
              (push write-fd *close-in-parent*)
              (let ((stream (sb-sys:make-fd-stream read-fd :input t
                                                   :element-type :default)))
                (values write-fd stream)))
             (t
              (sb-unix:unix-close read-fd)
              (sb-unix:unix-close write-fd)
              (error "Direction must be either :INPUT or :OUTPUT, not ~S."
                     direction)))))
        ((or (pathnamep object) (stringp object))
         (with-open-stream (file (apply #'open object keys))
           (multiple-value-bind
                 (fd errno)
               (sb-unix:unix-dup (sb-sys:fd-stream-fd file))
             (cond (fd
                    (push fd *close-in-parent*)
                    (values fd nil))
                   (t
                    (error "couldn't duplicate file descriptor: ~A"
                           (strerror errno)))))))
        ((sb-sys:fd-stream-p object)
         (values (sb-sys:fd-stream-fd object) nil))
        ((streamp object)
         (ecase direction
           (:input
            ;; FIXME: We could use a better way of setting up
            ;; temporary files, both here and in LOAD-FOREIGN.
            (dotimes (count
                       256
                      (error "could not open a temporary file in /tmp"))
              (let* ((name (coerce (format nil "/tmp/.run-program-~D" count)
                                   'base-string))
                     (fd (sb-unix:unix-open name
                                            (logior sb-unix:o_rdwr
                                                    sb-unix:o_creat
                                                    sb-unix:o_excl)
                                            #o666)))
                (sb-unix:unix-unlink name)
                (when fd
                  (let ((newline (string #\Newline)))
                    (loop
                        (multiple-value-bind
                              (line no-cr)
                            (read-line object nil nil)
                          (unless line
                            (return))
                          (sb-unix:unix-write
                           fd
                           ;; FIXME: this really should be
                           ;; (STRING-TO-OCTETS :EXTERNAL-FORMAT ...).
                           ;; RUN-PROGRAM should take an
                           ;; external-format argument, which should
                           ;; be passed down to here.  Something
                           ;; similar should happen on :OUTPUT, too.
                           (map '(vector (unsigned-byte 8)) #'char-code line)
                           0 (length line))
                          (if no-cr
                              (return)
                              (sb-unix:unix-write fd newline 0 1)))))
                  (sb-unix:unix-lseek fd 0 sb-unix:l_set)
                  (push fd *close-in-parent*)
                  (return (values fd nil))))))
           (:output
            (multiple-value-bind (read-fd write-fd)
                (sb-unix:unix-pipe)
              (unless read-fd
                (error "couldn't create pipe: ~S" (strerror write-fd)))
              (copy-descriptor-to-stream read-fd object cookie)
              (push read-fd *close-on-error*)
              (push write-fd *close-in-parent*)
              (values write-fd nil)))))
        (t
         (error "invalid option to RUN-PROGRAM: ~S" object))))
