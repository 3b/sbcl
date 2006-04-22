;;;; code for handling UNIX signals

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!UNIX")

(defun invoke-interruption (function)
  (without-interrupts
    (sb!unix::reset-signal-mask)
    (funcall function)))

(defmacro in-interruption ((&rest args) &body body)
  #!+sb-doc
  "Convenience macro on top of INVOKE-INTERRUPTION."
  `(invoke-interruption (lambda () ,@body) ,@args))

;;; These should probably be somewhere, but I don't know where.
(defconstant sig_dfl 0)
(defconstant sig_ign 1)

;;;; system calls that deal with signals

;;; Send the signal SIGNAL to the process with process id PID. SIGNAL
;;; should be a valid signal number
#!-sb-fluid (declaim (inline real-unix-kill))
(sb!alien:define-alien-routine ("kill" unix-kill) sb!alien:int
  (pid sb!alien:int)
  (signal sb!alien:int))

;;; Send the signal SIGNAL to the all the process in process group
;;; PGRP. SIGNAL should be a valid signal number
#!-sb-fluid (declaim (inline real-unix-killpg))
(sb!alien:define-alien-routine ("killpg" unix-killpg) sb!alien:int
  (pgrp sb!alien:int)
  (signal sb!alien:int))

;;; Reset the current set of masked signals (those being blocked from
;;; delivery).
;;;
;;; (Note: CMU CL had a more general SIGSETMASK call and a SIGMASK
;;; operator to create masks, but since we only ever reset to 0, we no
;;; longer support it. If you need it, you can pull it out of the CMU
;;; CL sources, or the old SBCL sources; but you might also consider
;;; doing things the SBCL way and moving this kind of C-level work
;;; down to C wrapper functions.)

;;; When inappropriate build options are used, this also prints messages
;;; listing the signals that were masked
(sb!alien:define-alien-routine "reset_signal_mask" sb!alien:void)


;;;; C routines that actually do all the work of establishing signal handlers
(sb!alien:define-alien-routine ("install_handler" install-handler)
                               sb!alien:unsigned-long
  (signal sb!alien:int)
  (handler sb!alien:unsigned-long))

;;;; interface to enabling and disabling signal handlers

(defun enable-interrupt (signal handler)
  (declare (type (or function fixnum (member :default :ignore)) handler))
  (/show0 "enable-interrupt")
  (flet ((run-handler (&rest args)
           (in-interruption ()
             (apply handler args))))
    (without-gcing
      (let ((result (install-handler signal
                                     (case handler
                                       (:default sig_dfl)
                                       (:ignore sig_ign)
                                       (t
                                        (sb!kernel:get-lisp-obj-address
                                         #'run-handler))))))
        (cond ((= result sig_dfl) :default)
              ((= result sig_ign) :ignore)
              (t (the (or function fixnum)
                   (sb!kernel:make-lisp-obj result))))))))

(defun default-interrupt (signal)
  (enable-interrupt signal :default))

(defun ignore-interrupt (signal)
  (enable-interrupt signal :ignore))

;;;; default LISP signal handlers
;;;;
;;;; Most of these just call ERROR to report the presence of the signal.

;;; SIGINT is handled like BREAK, except that ANSI BREAK ignores
;;; *DEBUGGER-HOOK*, but we want SIGINT's BREAK to respect it, so that
;;; SIGINT in --disable-debugger mode will cleanly terminate the system
;;; (by respecting the *DEBUGGER-HOOK* established in that mode).
(defun sigint-%break (format-string &rest format-arguments)
  (flet ((break-it ()
           (apply #'%break 'sigint format-string format-arguments)))
    (sb!thread:interrupt-thread (sb!thread::foreground-thread) #'break-it)))

(eval-when (:compile-toplevel :execute)
  (sb!xc:defmacro define-signal-handler (name
                                         what
                                         &optional (function 'error))
    `(defun ,name (signal info context)
       (declare (ignore signal info))
       (declare (type system-area-pointer context))
       (/show "in Lisp-level signal handler" ,(symbol-name name)
              (sap-int context))
       (with-interrupts
         (,function ,(concatenate 'simple-string what " at #X~X")
                    (with-alien ((context (* os-context-t) context))
                      (sap-int (sb!vm:context-pc context))))))))

(define-signal-handler sigint-handler "interrupted" sigint-%break)
(define-signal-handler sigill-handler "illegal instruction")
(define-signal-handler sigtrap-handler "breakpoint/trap")
#!-linux
(define-signal-handler sigemt-handler "SIGEMT")
(define-signal-handler sigbus-handler "bus error")
(define-signal-handler sigsegv-handler "segmentation violation")
#!-linux
(define-signal-handler sigsys-handler "bad argument to a system call")

(defun sigalrm-handler (signal info context)
  (declare (ignore signal info context))
  (declare (type system-area-pointer context))
  (sb!impl::run-expired-timers))

(defun sigterm-handler (signal code context)
  (declare (ignore signal code context))
  (sb!thread::terminate-session)
  (sb!ext:quit))

;; Also known as SIGABRT.
(defun sigiot-handler (signal code context)
  (declare (ignore signal code context))
  (sb!impl::%halt))

(defun sb!kernel:signal-cold-init-or-reinit ()
  #!+sb-doc
  "Enable all the default signals that Lisp knows how to deal with."
  (enable-interrupt sigint #'sigint-handler)
  (enable-interrupt sigterm #'sigterm-handler)
  (enable-interrupt sigill #'sigill-handler)
  (enable-interrupt sigtrap #'sigtrap-handler)
  (enable-interrupt sigiot #'sigiot-handler)
  #!-linux
  (enable-interrupt sigemt #'sigemt-handler)
  (enable-interrupt sigfpe #'sb!vm:sigfpe-handler)
  (enable-interrupt sigbus #'sigbus-handler)
  (enable-interrupt sigsegv #'sigsegv-handler)
  #!-linux
  (enable-interrupt sigsys #'sigsys-handler)
  (ignore-interrupt sigpipe)
  (enable-interrupt sigalrm #'sigalrm-handler)
  (sb!unix::reset-signal-mask)
  (values))

;;;; etc.

;;; CMU CL comment:
;;;   Magically converted by the compiler into a break instruction.
(defun receive-pending-interrupt ()
  (receive-pending-interrupt))

;;; stale code which I'm insufficiently motivated to test -- WHN 19990714
#|
;;;; WITH-ENABLED-INTERRUPTS

(defmacro with-enabled-interrupts (interrupt-list &body body)
  #!+sb-doc
  "With-enabled-interrupts ({(interrupt function)}*) {form}*
   Establish function as a handler for the Unix signal interrupt which
   should be a number between 1 and 31 inclusive."
  (let ((il (gensym))
        (it (gensym)))
    `(let ((,il NIL))
       (unwind-protect
           (progn
             ,@(do* ((item interrupt-list (cdr item))
                     (intr (caar item) (caar item))
                     (ifcn (cadar item) (cadar item))
                     (forms NIL))
                    ((null item) (nreverse forms))
                 (when (symbolp intr)
                   (setq intr (symbol-value intr)))
                 (push `(push `(,,intr ,(enable-interrupt ,intr ,ifcn)) ,il)
                       forms))
             ,@body)
         (dolist (,it (nreverse ,il))
           (enable-interrupt (car ,it) (cadr ,it)))))))
|#
