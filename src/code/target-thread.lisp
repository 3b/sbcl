(in-package "SB!THREAD")

(sb!alien::define-alien-routine ("create_thread" %create-thread)
     sb!alien:unsigned-long
  (lisp-fun-address sb!alien:unsigned-long))

(defun make-thread (function)
  (let ((real-function (coerce function 'function)))
    (%create-thread
     (sb!kernel:get-lisp-obj-address
      (lambda ()
	;; in time we'll move some of the binding presently done in C
	;; here too
	(let ((sb!kernel::*restart-clusters* nil)
	      (sb!impl::*descriptor-handlers* nil); serve-event
	      (sb!impl::*available-buffers* nil)) ;for fd-stream
	  ;; can't use handling-end-of-the-world, because that flushes
	  ;; output streams, and we don't necessarily have any (or we
	  ;; could be sharing them)
	  (sb!sys:enable-interrupt sb!unix:sigint :ignore)
	  (sb!unix:unix-exit
	   (catch 'sb!impl::%end-of-the-world 
	     (with-simple-restart 
		 (destroy-thread
		  (format nil "~~@<Destroy this thread (~A)~~@:>"
			  (current-thread-id)))
	       (funcall real-function))
	     0))))))))

;;; Really, you don't want to use these: they'll get into trouble with
;;; garbage collection.  Use a lock or a waitqueue instead
(defun suspend-thread (thread-id)
  (sb!unix:unix-kill thread-id sb!unix:sigstop))
(defun resume-thread (thread-id)
  (sb!unix:unix-kill thread-id sb!unix:sigcont))
;;; Note warning about cleanup forms
(defun destroy-thread (thread-id)
  "Destroy the thread identified by THREAD-ID abruptly, without running cleanup forms"
  (sb!unix:unix-kill thread-id sb!unix:sigterm)
  ;; may have been stopped for some reason, so now wake it up to
  ;; deliver the TERM
  (sb!unix:unix-kill thread-id sb!unix:sigcont))


;;; a moderate degree of care is expected for use of interrupt-thread,
;;; due to its nature: if you interrupt a thread that was holding
;;; important locks then do something that turns out to need those
;;; locks, you probably won't like the effect.  Used with thought
;;; though, it's a good deal gentler than the last-resort functions above

(defun interrupt-thread (thread function)
  "Interrupt THREAD and make it run FUNCTION.  "
  (sb!unix::syscall* ("interrupt_thread"
		      sb!alien:unsigned-long  sb!alien:unsigned-long)
		     thread
		     thread (sb!kernel:get-lisp-obj-address
			     (coerce function 'function))))
(defun terminate-thread (thread-id)
  "Terminate the thread identified by THREAD-ID, by causing it to run
SB-EXT:QUIT - the usual cleanup forms will be evaluated"
  (interrupt-thread thread-id 'sb!ext:quit))

(declaim (inline current-thread-id))
(defun current-thread-id ()
  (logand 
   (sb!sys:sap-int
    (sb!vm::current-thread-offset-sap sb!vm::thread-pid-slot))
   ;; KLUDGE pids are 16 bit really.  Avoid boxing the return value
   (1- (ash 1 16))))

;;;; iterate over the in-memory threads

(defun mapcar-threads (function)
  "Call FUNCTION once for each known thread, giving it the thread structure as argument"
  (let ((function (coerce function 'function)))
    (loop for thread = (alien-sap (extern-alien "all_threads" (* t)))
	  then  (sb!sys:sap-ref-sap thread (* 4 sb!vm::thread-next-slot))
	  until (sb!sys:sap= thread (sb!sys:int-sap 0))
	  collect (funcall function thread))))

;;;; queues, locks 

;; spinlocks use 0 as "free" value: higher-level locks use NIL
(declaim (inline get-spinlock release-spinlock))

(defun get-spinlock (lock offset new-value)
  (declare (optimize (speed 3) (safety 0)))
  (loop until
	(eql (sb!vm::%instance-set-conditional lock offset 0 new-value) 0)))

;; this should do nothing if we didn't own the lock, so safe to use in
;; unwind-protect cleanups when lock acquisition failed for some reason
(defun release-spinlock (lock offset our-value)
  (declare (optimize (speed 3) (safety 0)))
  (sb!vm::%instance-set-conditional lock offset our-value 0))

(defmacro with-spinlock ((queue) &body body)
  (with-unique-names (pid)
    `(let ((,pid (current-thread-id)))
       (unwind-protect
	    (progn
	      (get-spinlock ,queue 2 ,pid)
	      ,@body)
	 (release-spinlock ,queue 2 ,pid)))))


;;;; the higher-level locking operations are based on waitqueues

(defstruct waitqueue
  (name nil :type (or null simple-base-string))
  (lock 0)
  (data nil))

(defstruct (mutex (:include waitqueue))
  (value nil))

(sb!alien:define-alien-routine "block_sigcont"  void)
(sb!alien:define-alien-routine "unblock_sigcont_and_sleep"  void)


;;; this should only be called while holding the queue spinlock.
;;; it releases the spinlock before sleeping
(defun wait-on-queue (queue &optional lock)
  (let ((pid (current-thread-id)))
    (block-sigcont)
    (when lock (release-mutex lock))
    (sb!sys:without-interrupts
     (pushnew pid (waitqueue-data queue)))
    (setf (waitqueue-lock queue) 0)
    (unblock-sigcont-and-sleep)))

;;; this should only be called while holding the queue spinlock.  It doesn't
;;; release it
(defun dequeue (queue)
  (let ((pid (current-thread-id)))
    (sb!sys:without-interrupts     
     (setf (waitqueue-data queue)
	   (delete pid (waitqueue-data queue))))))

;;; this should only be called while holding the queue spinlock.
(defun signal-queue-head (queue)
  (let ((p (car (waitqueue-data queue))))
    (when p (sb!unix:unix-kill p  sb!unix::sig-dequeue))))

;;;; mutex

(defun get-mutex (lock &optional new-value (wait-p t))
  (declare (type mutex lock)
	   (optimize (speed 3)))
  (let ((pid (current-thread-id)))
    (unless new-value (setf new-value pid))
    (assert (not (eql new-value (mutex-value lock))))
    (get-spinlock lock 2 pid)
    (loop
     (unless
	 ;; args are object slot-num old-value new-value
	 (sb!vm::%instance-set-conditional lock 4 nil new-value)
       (dequeue lock)
       (setf (waitqueue-lock lock) 0)
       (return t))
     (unless wait-p
       (setf (waitqueue-lock lock) 0)
       (return nil))
     (wait-on-queue lock nil))))

(defun release-mutex (lock &optional (new-value nil))
  (declare (type mutex lock))
  ;; we assume the lock is ours to release
  (with-spinlock (lock)
    (setf (mutex-value lock) new-value)
    (signal-queue-head lock)))


(defmacro with-mutex ((mutex &key value (wait-p t))  &body body)
  (with-unique-names (got)
    `(let ((,got (get-mutex ,mutex ,value ,wait-p)))
      (when ,got
	(unwind-protect
	     (progn ,@body)
	  (release-mutex ,mutex))))))


;;;; condition variables

(defun condition-wait (queue lock)
  "Atomically release LOCK and enqueue ourselves on QUEUE.  Another
thread may subsequently notify us using CONDITION-NOTIFY, at which
time we reacquire LOCK and return to the caller."
  (assert lock)
  (let ((value (mutex-value lock)))
    (unwind-protect
	 (progn
	   (get-spinlock queue 2 (current-thread-id))
	   (wait-on-queue queue lock))
      ;; If we are interrupted while waiting, we should do these things
      ;; before returning.  Ideally, in the case of an unhandled signal,
      ;; we should do them before entering the debugger, but this is
      ;; better than nothing.
      (with-spinlock (queue)
	(dequeue queue))
      (get-mutex lock value))))

(defun condition-notify (queue)
  "Notify one of the processes waiting on QUEUE"
  (with-spinlock (queue) (signal-queue-head queue)))


;;;; multiple independent listeners

(defvar *session-lock* nil)

(defun make-listener-thread (tty-name)  
  (assert (probe-file tty-name))
  ;; FIXME probably still need to do some tty stuff to get signals
  ;; delivered correctly.
  ;; FIXME 
  (let* ((in (sb!unix:unix-open (namestring tty-name) sb!unix:o_rdwr #o666))
	 (out (sb!unix:unix-dup in))
	 (err (sb!unix:unix-dup in)))
    (labels ((thread-repl () 
	       (sb!unix::unix-setsid)
	       (let* ((*session-lock*
		       (make-mutex :name (format nil "lock for ~A" tty-name)))
		      (sb!impl::*stdin* 
		       (sb!sys:make-fd-stream in :input t :buffering :line))
		      (sb!impl::*stdout* 
		       (sb!sys:make-fd-stream out :output t :buffering :line))
		      (sb!impl::*stderr* 
		       (sb!sys:make-fd-stream err :output t :buffering :line))
		      (sb!impl::*tty* 
		       (sb!sys:make-fd-stream err :input t :output t :buffering :line))
		      (sb!impl::*descriptor-handlers* nil))
		 (get-mutex *session-lock*)
		 (sb!sys:enable-interrupt sb!unix:sigint #'sb!unix::sigint-handler)
		 (unwind-protect
		      (sb!impl::toplevel-repl nil)
		   (sb!int:flush-standard-output-streams)))))
      (make-thread #'thread-repl))))
  
;;;; job control

(defvar *background-threads-wait-for-debugger* t)
;;; may be T, NIL, or a function called with a stream and thread id 
;;; as its two arguments, returning NIl or T

;;; called from top of invoke-debugger
(defun debugger-wait-until-foreground-thread (stream)
  "Returns T if thread had been running in background, NIL if it was
already the foreground thread, or transfers control to the first applicable
restart if *BACKGROUND-THREADS-WAIT-FOR-DEBUGGER* says to do that instead"
  (let* ((wait-p *background-threads-wait-for-debugger*)
	 (*background-threads-wait-for-debugger* nil)
	 (lock *session-lock*))
    (when (not (eql (mutex-value lock)   (CURRENT-THREAD-ID)))
      (when (functionp wait-p) 
	(setf wait-p 
	      (funcall wait-p stream (CURRENT-THREAD-ID))))
      (cond (wait-p (get-foreground))
	    (t  (invoke-restart (car (compute-restarts))))))))

;;; install this with
;;; (setf SB-INT:*REPL-PROMPT-FUN* #'sb-thread::thread-repl-prompt-fun)
;;; One day it will be default
(defun thread-repl-prompt-fun (out-stream)
  (let ((lock *session-lock*))
    (get-foreground)
    (let ((stopped-threads (waitqueue-data lock)))
      (when stopped-threads
	(format out-stream "~{~&Thread ~A suspended~}~%" stopped-threads))
      (sb!impl::repl-prompt-fun out-stream))))

(defun resume-stopped-thread (id)
  (let ((lock *session-lock*)) 
    (with-spinlock (lock)
      (setf (waitqueue-data lock)
	    (cons id (delete id  (waitqueue-data lock)))))
    (release-foreground)))

(defstruct rwlock
  (name nil :type (or null simple-base-string))
  (value 0 :type fixnum)
  (max-readers nil :type (or fixnum null))
  (max-writers 1 :type fixnum))
#+nil
(macrolet
    ((make-rwlocking-function (lock-fn unlock-fn increment limit test)
       (let ((do-update '(when (eql old-value
				(sb!vm::%instance-set-conditional
				 lock 2 old-value new-value))
			  (return (values t old-value))))
	     (vars `((timeout (and timeout (+ (get-internal-real-time) timeout)))
		     old-value
		     new-value
		     (limit ,limit))))
	 (labels ((do-setfs (v) `(setf old-value (rwlock-value lock)
				  new-value (,v old-value ,increment))))
	   `(progn
	     (defun ,lock-fn (lock timeout)
	       (declare (type rwlock lock))
	       (let ,vars
		 (loop
		  ,(do-setfs '+)
		  (when ,test
		    ,do-update)
		  (when (sleep-a-bit timeout) (return nil)) ;expired
		  )))
	     ;; unlock doesn't need timeout or test-in-range
	     (defun ,unlock-fn (lock)
	       (declare (type rwlock lock))
	       (declare (ignorable limit))
	       (let ,(cdr vars)
		 (loop
		  ,(do-setfs '-)
		  ,do-update))))))))
    
  (make-rwlocking-function %lock-for-reading %unlock-for-reading 1
			   (rwlock-max-readers lock)
			   (and (>= old-value 0)
				(or (null limit) (<= new-value limit))))
  (make-rwlocking-function %lock-for-writing %unlock-for-writing -1
			   (- (rwlock-max-writers lock))
			   (and (<= old-value 0)
				(>= new-value limit))))
#+nil  
(defun get-rwlock (lock direction &optional timeout)
  (ecase direction
    (:read (%lock-for-reading lock timeout))
    (:write (%lock-for-writing lock timeout))))
#+nil
(defun free-rwlock (lock direction)
  (ecase direction
    (:read (%unlock-for-reading lock))
    (:write (%unlock-for-writing lock))))

;;;; beyond this point all is commented.

;;; Lock-Wait-With-Timeout  --  Internal
;;;
;;; Wait with a timeout for the lock to be free and acquire it for the
;;; *current-process*.
;;;
#+nil
(defun lock-wait-with-timeout (lock whostate timeout)
  (declare (type lock lock))
  (process-wait-with-timeout
   whostate timeout
   #'(lambda ()
       (declare (optimize (speed 3)))
       #-i486
       (unless (lock-process lock)
	 (setf (lock-process lock) *current-process*))
       #+i486
       (null (kernel:%instance-set-conditional
	      lock 2 nil *current-process*)))))

;;; With-Lock-Held  --  Public
;;;
#+nil
(defmacro with-lock-held ((lock &optional (whostate "Lock Wait")
				&key (wait t) timeout)
			  &body body)
  "Execute the body with the lock held. If the lock is held by another
  process then the current process waits until the lock is released or
  an optional timeout is reached. The optional wait timeout is a time in
  seconds acceptable to process-wait-with-timeout.  The results of the
  body are return upon success and NIL is return if the timeout is
  reached. When the wait key is NIL and the lock is held by another
  process then NIL is return immediately without processing the body."
  (let ((have-lock (gensym)))
    `(let ((,have-lock (eq (lock-process ,lock) *current-process*)))
      (unwind-protect
	   ,(cond ((and timeout wait)
		   `(progn
		      (when (and (error-check-lock-p ,lock) ,have-lock)
			(error "Dead lock"))
		      (when (or ,have-lock
				 #+i486 (null (kernel:%instance-set-conditional
					       ,lock 2 nil *current-process*))
				 #-i486 (seize-lock ,lock)
				 (if ,timeout
				     (lock-wait-with-timeout
				      ,lock ,whostate ,timeout)
				     (lock-wait ,lock ,whostate)))
			,@body)))
		  (wait
		   `(progn
		      (when (and (error-check-lock-p ,lock) ,have-lock)
		        (error "Dead lock"))
		      (unless (or ,have-lock
				 #+i486 (null (kernel:%instance-set-conditional
					       ,lock 2 nil *current-process*))
				 #-i486 (seize-lock ,lock))
			(lock-wait ,lock ,whostate))
		      ,@body))
		  (t
		   `(when (or (and (recursive-lock-p ,lock) ,have-lock)
			      #+i486 (null (kernel:%instance-set-conditional
					    ,lock 2 nil *current-process*))
			      #-i486 (seize-lock ,lock))
		      ,@body)))
	(unless ,have-lock
	  #+i486 (kernel:%instance-set-conditional
		  ,lock 2 *current-process* nil)
	  #-i486 (when (eq (lock-process ,lock) *current-process*)
		   (setf (lock-process ,lock) nil)))))))



