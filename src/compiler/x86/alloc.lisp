;;;; allocation VOPs for the x86

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; LIST and LIST*
(defoptimizer (list stack-allocate-result) ((&rest args))
  (not (null args)))
(defoptimizer (list* stack-allocate-result) ((&rest args))
  (not (null (rest args))))

(define-vop (list-or-list*)
  (:args (things :more t))
  (:temporary (:sc unsigned-reg) ptr temp)
  (:temporary (:sc unsigned-reg :to (:result 0) :target result) res)
  (:info num)
  (:results (result :scs (descriptor-reg)))
  (:variant-vars star)
  (:policy :safe)
  (:node-var node)
  (:generator 0
    (cond ((zerop num)
	   ;; (move result nil-value)
	   (inst mov result nil-value))
	  ((and star (= num 1))
	   (move result (tn-ref-tn things)))
	  (t
	   (macrolet
	       ((store-car (tn list &optional (slot cons-car-slot))
		  `(let ((reg
			  (sc-case ,tn
			    ((any-reg descriptor-reg) ,tn)
			    ((control-stack)
			     (move temp ,tn)
			     temp))))
		     (storew reg ,list ,slot list-pointer-lowtag))))
	     (let ((cons-cells (if star (1- num) num)))
	       (pseudo-atomic
		(allocation res (* (pad-data-block cons-size) cons-cells) node
                            (awhen (sb!c::node-lvar node) (sb!c::lvar-dynamic-extent it)))
		(inst lea res
		      (make-ea :byte :base res :disp list-pointer-lowtag))
		(move ptr res)
		(dotimes (i (1- cons-cells))
		  (store-car (tn-ref-tn things) ptr)
		  (setf things (tn-ref-across things))
		  (inst add ptr (pad-data-block cons-size))
		  (storew ptr ptr (- cons-cdr-slot cons-size)
			  list-pointer-lowtag))
		(store-car (tn-ref-tn things) ptr)
		(cond (star
		       (setf things (tn-ref-across things))
		       (store-car (tn-ref-tn things) ptr cons-cdr-slot))
		      (t
		       (storew nil-value ptr cons-cdr-slot
			       list-pointer-lowtag)))
		(aver (null (tn-ref-across things)))))
	     (move result res))))))

(define-vop (list list-or-list*)
  (:variant nil))

(define-vop (list* list-or-list*)
  (:variant t))

;;;; special-purpose inline allocators

(define-vop (allocate-code-object)
  (:args (boxed-arg :scs (any-reg) :target boxed)
	 (unboxed-arg :scs (any-reg) :target unboxed))
  (:results (result :scs (descriptor-reg) :from :eval))
  (:temporary (:sc unsigned-reg :from (:argument 0)) boxed)
  (:temporary (:sc unsigned-reg :from (:argument 1)) unboxed)
  (:node-var node)
  (:generator 100
    (move boxed boxed-arg)
    (inst add boxed (fixnumize (1+ code-trace-table-offset-slot)))
    (inst and boxed (lognot lowtag-mask))
    (move unboxed unboxed-arg)
    (inst shr unboxed word-shift)
    (inst add unboxed lowtag-mask)
    (inst and unboxed (lognot lowtag-mask))
    (inst mov result boxed)
    (inst add result unboxed)
    (pseudo-atomic
     (allocation result result node)
     (inst lea result (make-ea :byte :base result :disp other-pointer-lowtag))
     (inst shl boxed (- n-widetag-bits word-shift))
     (inst or boxed code-header-widetag)
     (storew boxed result 0 other-pointer-lowtag)
     (storew unboxed result code-code-size-slot other-pointer-lowtag)
     (storew nil-value result code-entry-points-slot other-pointer-lowtag))
    (storew nil-value result code-debug-info-slot other-pointer-lowtag)))

(define-vop (make-fdefn)
  (:policy :fast-safe)
  (:translate make-fdefn)
  (:args (name :scs (descriptor-reg) :to :eval))
  (:results (result :scs (descriptor-reg) :from :argument))
  (:node-var node)
  (:generator 37
    (with-fixed-allocation (result fdefn-widetag fdefn-size node)
      (storew name result fdefn-name-slot other-pointer-lowtag)
      (storew nil-value result fdefn-fun-slot other-pointer-lowtag)
      (storew (make-fixup (extern-alien-name "undefined_tramp") :foreign)
	      result fdefn-raw-addr-slot other-pointer-lowtag))))

(define-vop (make-closure)
  (:args (function :to :save :scs (descriptor-reg)))
  (:info length)
  (:temporary (:sc any-reg) temp)
  (:results (result :scs (descriptor-reg)))
  (:node-var node)
  (:generator 10
   (pseudo-atomic
    (let ((size (+ length closure-info-offset)))
      (allocation result (pad-data-block size) node)
      (inst lea result
	    (make-ea :byte :base result :disp fun-pointer-lowtag))
      (storew (logior (ash (1- size) n-widetag-bits) closure-header-widetag)
	      result 0 fun-pointer-lowtag))
    (loadw temp function closure-fun-slot fun-pointer-lowtag)
    (storew temp result closure-fun-slot fun-pointer-lowtag))))

;;; The compiler likes to be able to directly make value cells.
(define-vop (make-value-cell)
  (:args (value :scs (descriptor-reg any-reg) :to :result))
  (:results (result :scs (descriptor-reg) :from :eval))
  (:node-var node)
  (:generator 10
    (with-fixed-allocation
	(result value-cell-header-widetag value-cell-size node))
    (storew value result value-cell-value-slot other-pointer-lowtag)))

;;;; automatic allocators for primitive objects

(define-vop (make-unbound-marker)
  (:args)
  (:results (result :scs (any-reg)))
  (:generator 1
    (inst mov result unbound-marker-widetag)))

(define-vop (fixed-alloc)
  (:args)
  (:info name words type lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg)))
  (:node-var node)
  (:generator 50
    (pseudo-atomic
     (allocation result (pad-data-block words) node)
     (inst lea result (make-ea :byte :base result :disp lowtag))
     (when type
       (storew (logior (ash (1- words) n-widetag-bits) type)
	       result
	       0
	       lowtag)))))

(define-vop (var-alloc)
  (:args (extra :scs (any-reg)))
  (:arg-types positive-fixnum)
  (:info name words type lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg) :from (:eval 1)))
  (:temporary (:sc any-reg :from :eval :to (:eval 1)) bytes)
  (:temporary (:sc any-reg :from :eval :to :result) header)
  (:node-var node)
  (:generator 50
    (inst lea bytes
	  (make-ea :dword :base extra :disp (* (1+ words) n-word-bytes)))
    (inst mov header bytes)
    (inst shl header (- n-widetag-bits 2)) ; w+1 to length field
    (inst lea header			; (w-1 << 8) | type
	  (make-ea :dword :base header :disp (+ (ash -2 n-widetag-bits) type)))
    (inst and bytes (lognot lowtag-mask))
    (pseudo-atomic
     (allocation result bytes node)
     (inst lea result (make-ea :byte :base result :disp lowtag))
     (storew header result 0 lowtag))))


