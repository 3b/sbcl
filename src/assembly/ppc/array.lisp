;;;; various array operations that are too expensive (in space) to do
;;;; inline

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(define-assembly-routine (allocate-vector
			  (:policy :fast-safe)
			  (:translate allocate-vector)
			  (:arg-types positive-fixnum
				      positive-fixnum
				      positive-fixnum))
			 ((:arg type any-reg a0-offset)
			  (:arg length any-reg a1-offset)
			  (:arg words any-reg a2-offset)
			  (:res result descriptor-reg a0-offset)

			  (:temp ndescr non-descriptor-reg nl0-offset)
			  (:temp gc-temp non-descriptor-reg nl1-offset)
			  (:temp pa-flag non-descriptor-reg nl3-offset)
			  (:temp vector descriptor-reg a3-offset))
  (pseudo-atomic (pa-flag)
    (inst addi ndescr words (* (1+ sb!vm:vector-data-offset) sb!vm:n-word-bytes))
    (inst clrrwi ndescr ndescr n-lowtag-bits)
    (allocation vector ndescr sb!vm:other-pointer-lowtag :temp-tn gc-temp)
    (inst srwi ndescr type sb!vm:word-shift)
    (storew ndescr vector 0 sb!vm:other-pointer-lowtag)
    (storew length vector sb!vm:vector-length-slot sb!vm:other-pointer-lowtag))
  (move result vector))
