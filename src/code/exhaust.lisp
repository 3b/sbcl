;;;; detecting and handling exhaustion of fundamental system resources
;;;; (stack or heap)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")
(define-alien-routine ("protect_control_stack_guard_page"
		       %protect-control-stack-guard-page)
    sb!alien:int (thread-id sb!alien:int) (protect-p sb!alien:int))
(defun protect-control-stack-guard-page (n)
  (declare (ignore n))
  #+nil
  (%protect-control-stack-guard-page 
   (sb!thread:current-thread-id) (if n 1 0)))


