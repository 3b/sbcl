;;;; This file contains stuff for controlling floating point traps. It
;;;; is IEEE float specific, but should work for pretty much any FPU
;;;; where the state fits in one word and exceptions are represented
;;;; by bits being set.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(eval-when (:compile-toplevel :load-toplevel :execute)

(defparameter *float-trap-alist*
  (list (cons :underflow float-underflow-trap-bit)
	(cons :overflow float-overflow-trap-bit)
	(cons :inexact float-inexact-trap-bit)
	(cons :invalid float-invalid-trap-bit)
	(cons :divide-by-zero float-divide-by-zero-trap-bit)
	#!+(or x86 x86-64)
	(cons :denormalized-operand float-denormal-trap-bit)))

(defparameter *rounding-mode-alist*
  (list (cons :nearest float-round-to-nearest)
	(cons :zero float-round-to-zero)
	(cons :positive-infinity float-round-to-positive)
	(cons :negative-infinity float-round-to-negative)))

;;; Return a mask with all the specified float trap bits set.
(defun float-trap-mask (names)
  (reduce #'logior
	  (mapcar (lambda (x)
		    (or (cdr (assoc x *float-trap-alist*))
			(error "unknown float trap kind: ~S" x)))
		  names)))
) ; EVAL-WHEN

;;; interpreter stubs for floating point modes get/setters for the
;;; alpha have been removed to alpha-vm.lisp, as they are implemented
;;; in C rather than as VOPs.
#!-alpha
(progn
  (defun floating-point-modes () 
    (floating-point-modes))
  (defun (setf floating-point-modes) (new) 
    (setf (floating-point-modes) new)))

;;; This function sets options controlling the floating-point
;;; hardware. If a keyword is not supplied, then the current value is
;;; preserved. Possible keywords:
;;; :TRAPS
;;;    A list of the exception conditions that should cause traps.
;;;    Possible exceptions are :UNDERFLOW, :OVERFLOW, :INEXACT, :INVALID,
;;;    :DIVIDE-BY-ZERO, and on the X86 :DENORMALIZED-OPERAND.
;;;
;;;:ROUNDING-MODE
;;;    The rounding mode to use when the result is not exact. Possible
;;;    values are :NEAREST, :POSITIVE-INFINITY, :NEGATIVE-INFINITY and
;;;    :ZERO.  Setting this away from :NEAREST is liable to upset SBCL's
;;;    maths routines which depend on it.
;;;
;;;:CURRENT-EXCEPTIONS
;;;:ACCRUED-EXCEPTIONS
;;;    These arguments allow setting of the exception flags. The main
;;;    use is setting the accrued exceptions to NIL to clear them.
;;;
;;;:FAST-MODE
;;;    Set the hardware's \"fast mode\" flag, if any. When set, IEEE
;;;    conformance or debuggability may be impaired. Some machines don't
;;;    have this feature, and some SBCL ports don't implement it anyway
;;;    -- in such cases the value is always NIL.
;;;
;;; GET-FLOATING-POINT-MODES may be used to find the floating point modes
;;; currently in effect.    See cold-init.lisp for the list of initially
;;; enabled traps

(defun set-floating-point-modes (&key (traps nil traps-p)
				      (rounding-mode nil round-p)
				      (current-exceptions nil current-x-p)
				      (accrued-exceptions nil accrued-x-p)
				      (fast-mode nil fast-mode-p))
  (let ((modes (floating-point-modes)))
    (when traps-p
      (setf (ldb float-traps-byte modes) (float-trap-mask traps)))
    (when round-p
      (setf (ldb float-rounding-mode modes)
	    (or (cdr (assoc rounding-mode *rounding-mode-alist*))
		(error "unknown rounding mode: ~S" rounding-mode))))
    (when current-x-p
      (setf (ldb float-exceptions-byte modes)
	    (float-trap-mask current-exceptions)))
    (when accrued-x-p
      (setf (ldb float-sticky-bits modes)
	    (float-trap-mask accrued-exceptions)))
    (when fast-mode-p
      (if fast-mode
	  (setq modes (logior float-fast-bit modes))
	  (setq modes (logand (lognot float-fast-bit) modes))))
    ;; FIXME: This apparently doesn't work on Darwin
    #!-darwin (setf (floating-point-modes) modes))

  (values))

;;; This function returns a list representing the state of the floating 
;;; point modes. The list is in the same format as the &KEY arguments to
;;; SET-FLOATING-POINT-MODES, i.e.
;;;    (apply #'set-floating-point-modes (get-floating-point-modes))
;;; sets the floating point modes to their current values (and thus is a
;;; no-op).
(defun get-floating-point-modes ()
  (flet ((exc-keys (bits)
	   (macrolet ((frob ()
			`(collect ((res))
			   ,@(mapcar (lambda (x)
				       `(when (logtest bits ,(cdr x))
					  (res ',(car x))))
				     *float-trap-alist*)
			   (res))))
	     (frob))))
    (let ((modes (floating-point-modes)))
      `(:traps ,(exc-keys (ldb float-traps-byte modes))
	:rounding-mode ,(car (rassoc (ldb float-rounding-mode modes)
				     *rounding-mode-alist*))
	:current-exceptions ,(exc-keys (ldb float-exceptions-byte modes))
	:accrued-exceptions ,(exc-keys (ldb float-sticky-bits modes))
	:fast-mode ,(logtest float-fast-bit modes)))))

;;; Return true if any of the named traps are currently trapped, false
;;; otherwise.
(defmacro current-float-trap (&rest traps)
  `(not (zerop (logand ,(dpb (float-trap-mask traps) float-traps-byte 0)
		       (floating-point-modes)))))

;;; Signal the appropriate condition when we get a floating-point error.
(defun sigfpe-handler (signal info context)
  (declare (ignore signal info context))
  (declare (type system-area-pointer context))
  (let* ((modes (context-floating-point-modes
		 (sb!alien:sap-alien context (* os-context-t))))
	 (traps (logand (ldb float-exceptions-byte modes)
			(ldb float-traps-byte modes))))
    (cond ((not (zerop (logand float-divide-by-zero-trap-bit traps)))
	   (error 'division-by-zero))
	  ((not (zerop (logand float-invalid-trap-bit traps)))
	   (error 'floating-point-invalid-operation))
	  ((not (zerop (logand float-overflow-trap-bit traps)))
	   (error 'floating-point-overflow))
	  ((not (zerop (logand float-underflow-trap-bit traps)))
	   (error 'floating-point-underflow))
	  ((not (zerop (logand float-inexact-trap-bit traps)))
	   (error 'floating-point-inexact))
	  #!+FreeBSD
	  ((zerop (ldb float-exceptions-byte modes))
	   ;; I can't tell what caused the exception!!
	   (error 'floating-point-exception
		  :traps (getf (get-floating-point-modes) :traps)))
	  (t
	   (error 'floating-point-exception)))))

;;; Execute BODY with the floating point exceptions listed in TRAPS
;;; masked (disabled). TRAPS should be a list of possible exceptions
;;; which includes :UNDERFLOW, :OVERFLOW, :INEXACT, :INVALID and
;;; :DIVIDE-BY-ZERO and on the X86 :DENORMALIZED-OPERAND. The
;;; respective accrued exceptions are cleared at the start of the body
;;; to support their testing within, and restored on exit.
(defmacro with-float-traps-masked (traps &body body)
  (let ((traps (dpb (float-trap-mask traps) float-traps-byte 0))
	(exceptions (dpb (float-trap-mask traps) float-sticky-bits 0))
	(trap-mask (dpb (lognot (float-trap-mask traps))
			float-traps-byte #xffffffff))
	(exception-mask (dpb (lognot (float-trap-mask traps))
			     float-sticky-bits #xffffffff))
        (orig-modes (gensym)))
    `(let ((,orig-modes (floating-point-modes)))
      (unwind-protect
	   (progn
	     (setf (floating-point-modes)
		   (logand ,orig-modes ,(logand trap-mask exception-mask)))
	     ,@body)
	;; Restore the original traps and exceptions.
	(setf (floating-point-modes)
	      (logior (logand ,orig-modes ,(logior traps exceptions))
		      (logand (floating-point-modes)
			      ,(logand trap-mask exception-mask))))))))
