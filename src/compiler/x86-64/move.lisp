;;;; the x86 VM definition of operand loading/saving and the MOVE vop

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(define-move-fun (load-immediate 1) (vop x y)
  ((immediate)
   (any-reg descriptor-reg))
  (let ((val (tn-value x)))
    (etypecase val
      (integer
       (if (zerop val)
	   (inst xor y y)
	 (inst mov y (fixnumize val))))
      (symbol
       (load-symbol y val))
      (character
       (inst mov y (logior (ash (char-code val) n-widetag-bits)
			   base-char-widetag))))))

(define-move-fun (load-number 1) (vop x y)
  ((immediate) (signed-reg unsigned-reg))
  (inst mov y (tn-value x)))

(define-move-fun (load-base-char 1) (vop x y)
  ((immediate) (base-char-reg))
  (inst mov y (char-code (tn-value x))))

(define-move-fun (load-system-area-pointer 1) (vop x y)
  ((immediate) (sap-reg))
  (inst mov y (sap-int (tn-value x))))

(define-move-fun (load-constant 5) (vop x y)
  ((constant) (descriptor-reg any-reg))
  (inst mov y x))

(define-move-fun (load-stack 5) (vop x y)
  ((control-stack) (any-reg descriptor-reg)
   (base-char-stack) (base-char-reg)
   (sap-stack) (sap-reg)
   (signed-stack) (signed-reg)
   (unsigned-stack) (unsigned-reg))
  (inst mov y x))

(define-move-fun (store-stack 5) (vop x y)
  ((any-reg descriptor-reg) (control-stack)
   (base-char-reg) (base-char-stack)
   (sap-reg) (sap-stack)
   (signed-reg) (signed-stack)
   (unsigned-reg) (unsigned-stack))
  (inst mov y x))

;;;; the MOVE VOP
(define-vop (move)
  (:args (x :scs (any-reg descriptor-reg immediate) :target y
	    :load-if (not (location= x y))))
  (:results (y :scs (any-reg descriptor-reg)
	       :load-if
	       (not (or (location= x y)
			(and (sc-is x any-reg descriptor-reg immediate)
			     (sc-is y control-stack))))))
  (:effects)
  (:affected)
  (:generator 0
    (if (and (sc-is x immediate)
	     (sc-is y any-reg descriptor-reg control-stack))
	(let ((val (tn-value x)))
	  (etypecase val
	    (integer
	     (if (and (zerop val) (sc-is y any-reg descriptor-reg))
		 (inst xor y y)
		 (multiple-value-bind (lo hi) (dwords-for-quad (fixnumize val))
		   (cond ((zerop hi)
			  (inst mov y lo))
			 (t
			  (inst mov y hi)
			  (inst shl y 32)
			  (inst or y lo))))))
	    (symbol
	     (inst mov y (+ nil-value (static-symbol-offset val))))
	    (character
	     (inst mov y (logior (ash (char-code val) n-widetag-bits)
				 base-char-widetag)))))
      (move y x))))

(define-move-vop move :move
  (any-reg descriptor-reg immediate)
  (any-reg descriptor-reg))

;;; Make MOVE the check VOP for T so that type check generation
;;; doesn't think it is a hairy type. This also allows checking of a
;;; few of the values in a continuation to fall out.
(primitive-type-vop move (:check) t)

;;; The MOVE-ARG VOP is used for moving descriptor values into
;;; another frame for argument or known value passing.
;;;
;;; Note: It is not going to be possible to move a constant directly
;;; to another frame, except if the destination is a register and in
;;; this case the loading works out.
(define-vop (move-arg)
  (:args (x :scs (any-reg descriptor-reg immediate) :target y
	    :load-if (not (and (sc-is y any-reg descriptor-reg)
			       (sc-is x control-stack))))
	 (fp :scs (any-reg)
	     :load-if (not (sc-is y any-reg descriptor-reg))))
  (:results (y))
  (:generator 0
    (sc-case y
      ((any-reg descriptor-reg)
       (if (sc-is x immediate)
	   (let ((val (tn-value x)))
	     (etypecase val
	       ((integer 0 0)
		(inst xor y y))
	       ((or (signed-byte 29) (unsigned-byte 29))
		(inst mov y (fixnumize val)))
	       (integer
		(multiple-value-bind (lo hi)
		    (dwords-for-quad (fixnumize val))
		  (inst mov y hi)
		  (inst shl y 32)
		  (inst or y lo)))
	       (symbol
		(load-symbol y val))
	       (character
		(inst mov y (logior (ash (char-code val) n-widetag-bits)
				    base-char-widetag)))))
	   (move y x)))
      ((control-stack)
       (if (sc-is x immediate)
	   (let ((val (tn-value x)))
	     (if (= (tn-offset fp) esp-offset)
		 ;; C-call
		 (etypecase val
		   (integer
		    (storew (fixnumize val) fp (tn-offset y)))
		   (symbol
		    (storew (+ nil-value (static-symbol-offset val))
			    fp (tn-offset y)))
		   (character
		    (storew (logior (ash (char-code val) n-widetag-bits)
				    base-char-widetag)
			    fp (tn-offset y))))
	       ;; Lisp stack
	       (etypecase val
		 (integer
		  (storew (fixnumize val) fp (- (1+ (tn-offset y)))))
		 (symbol
		  (storew (+ nil-value (static-symbol-offset val))
			  fp (- (1+ (tn-offset y)))))
		 (character
		  (storew (logior (ash (char-code val) n-widetag-bits)
				  base-char-widetag)
			  fp (- (1+ (tn-offset y))))))))
	 (if (= (tn-offset fp) esp-offset)
	     ;; C-call
	     (storew x fp (tn-offset y))
	   ;; Lisp stack
	   (storew x fp (- (1+ (tn-offset y))))))))))

(define-move-vop move-arg :move-arg
  (any-reg descriptor-reg)
  (any-reg descriptor-reg))

;;;; ILLEGAL-MOVE

;;; This VOP exists just to begin the lifetime of a TN that couldn't
;;; be written legally due to a type error. An error is signalled
;;; before this VOP is so we don't need to do anything (not that there
;;; would be anything sensible to do anyway.)
(define-vop (illegal-move)
  (:args (x) (type))
  (:results (y))
  (:ignore y)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 666
    (error-call vop object-not-type-error x type)))

;;;; moves and coercions

;;; These MOVE-TO-WORD VOPs move a tagged integer to a raw full-word
;;; representation. Similarly, the MOVE-FROM-WORD VOPs converts a raw
;;; integer to a tagged bignum or fixnum.

;;; Arg is a fixnum, so just shift it. We need a type restriction
;;; because some possible arg SCs (control-stack) overlap with
;;; possible bignum arg SCs.
(define-vop (move-to-word/fixnum)
  (:args (x :scs (any-reg descriptor-reg) :target y
	    :load-if (not (location= x y))))
  (:results (y :scs (signed-reg unsigned-reg)
	       :load-if (not (location= x y))))
  (:arg-types tagged-num)
  (:note "fixnum untagging")
  (:generator 1
    (move y x)
    (inst sar y  (1- n-lowtag-bits))))
(define-move-vop move-to-word/fixnum :move
  (any-reg descriptor-reg) (signed-reg unsigned-reg))

;;; Arg is a non-immediate constant, load it.
(define-vop (move-to-word-c)
  (:args (x :scs (constant)))
  (:results (y :scs (signed-reg unsigned-reg)))
  (:note "constant load")
  (:generator 1
    (inst mov y (tn-value x))))
(define-move-vop move-to-word-c :move
  (constant) (signed-reg unsigned-reg))


;;; Arg is a fixnum or bignum, figure out which and load if necessary.
(define-vop (move-to-word/integer)
  (:args (x :scs (descriptor-reg) :target eax))
  (:results (y :scs (signed-reg unsigned-reg)))
  (:note "integer to untagged word coercion")
  (:temporary (:sc unsigned-reg :offset eax-offset
		   :from (:argument 0) :to (:result 0) :target y) eax)
  (:generator 4
    (move eax x)
    (inst test al-tn 7)			; a symbolic constant for this 
    (inst jmp :z fixnum)		; would be nice
    (loadw y eax bignum-digits-offset other-pointer-lowtag)
    (inst jmp done)
    FIXNUM
    (inst sar eax (1- n-lowtag-bits))
    (move y eax)
    DONE))
(define-move-vop move-to-word/integer :move
  (descriptor-reg) (signed-reg unsigned-reg))


;;; Result is a fixnum, so we can just shift. We need the result type
;;; restriction because of the control-stack ambiguity noted above.
(define-vop (move-from-word/fixnum)
  (:args (x :scs (signed-reg unsigned-reg) :target y
	    :load-if (not (location= x y))))
  (:results (y :scs (any-reg descriptor-reg)
	       :load-if (not (location= x y))))
  (:result-types tagged-num)
  (:note "fixnum tagging")
  (:generator 1
    (cond ((and (sc-is x signed-reg unsigned-reg)
		(not (location= x y)))
	   ;; Uses 7 bytes, but faster on the Pentium
	   (inst lea y (make-ea :qword :index x :scale 8)))
	  (t
	   ;; Uses: If x is a reg 2 + 3; if x = y uses only 3 bytes
	   (move y x)
	   (inst shl y (1- n-lowtag-bits))))))
(define-move-vop move-from-word/fixnum :move
  (signed-reg unsigned-reg) (any-reg descriptor-reg))

;;; Result may be a bignum, so we have to check. Use a worst-case cost
;;; to make sure people know they may be number consing.
;;;
;;; KLUDGE: I assume this is suppressed in favor of the "faster inline
;;; version" below. (See also mysterious comment "we don't want a VOP
;;; on this one" on DEFINE-ASSEMBLY-ROUTINE (MOVE-FROM-SIGNED) in
;;; "src/assembly/x86/alloc.lisp".) -- WHN 19990916
#+nil
(define-vop (move-from-signed)
  (:args (x :scs (signed-reg unsigned-reg) :target eax))
  (:temporary (:sc unsigned-reg :offset eax-offset :from (:argument 0)) eax)
  (:temporary (:sc unsigned-reg :offset ebx-offset :to (:result 0) :target y)
	      ebx)
  (:temporary (:sc unsigned-reg :offset ecx-offset
		   :from (:argument 0) :to (:result 0)) ecx)
  (:ignore ecx)
  (:results (y :scs (any-reg descriptor-reg)))
  (:note "signed word to integer coercion")
  (:generator 20
    (move eax x)
    (inst call (make-fixup 'move-from-signed :assembly-routine))
    (move y ebx)))
;;; Faster inline version,
;;; KLUDGE: Do we really want the faster inline version? It's sorta big.
;;; It is nice that it doesn't use any temporaries, though. -- WHN 19990916
(define-vop (move-from-signed)
  (:args (x :scs (signed-reg unsigned-reg) :to :result))
  (:results (y :scs (any-reg descriptor-reg) :from :argument))
  (:note "signed word to integer coercion")
  (:node-var node)
  (:generator 20
     (aver (not (location= x y)))
     (let ((bignum (gen-label))
	   (done (gen-label)))
       (inst mov y x)
       (inst shl y 1)
       (inst jmp :o bignum)
       (inst shl y 1)
       (inst jmp :o bignum)
       (inst shl y 1)
       (inst jmp :o bignum)
       (emit-label done)

       (assemble (*elsewhere*)
	  (emit-label bignum)
	  (with-fixed-allocation
	      (y bignum-widetag (+ bignum-digits-offset 1) node)
	    (storew x y bignum-digits-offset other-pointer-lowtag))
	  (inst jmp done)))))
(define-move-vop move-from-signed :move
  (signed-reg) (descriptor-reg))

;;; Check for fixnum, and possibly allocate one or two word bignum
;;; result. Use a worst-case cost to make sure people know they may be
;;; number consing.

(define-vop (move-from-unsigned)
  (:args (x :scs (signed-reg unsigned-reg) :to :save))
  (:temporary (:sc unsigned-reg) alloc)
  (:results (y :scs (any-reg descriptor-reg)))
  (:node-var node)
  (:note "unsigned word to integer coercion")
  (:generator 20
    (aver (not (location= x y)))
    (aver (not (location= x alloc)))
    (aver (not (location= y alloc)))
    (let ((bignum (gen-label))
	  (done (gen-label))
	  (one-word-bignum (gen-label))
	  (L1 (gen-label)))
      (inst bsr y x)			;find msb
      (inst cmov :z y x)
      (inst cmp y 60)
      (inst jmp :ae bignum)
      (inst lea y (make-ea :qword :index x :scale 8))
      (emit-label done)
      (assemble (*elsewhere*)
	 (emit-label bignum)
	 ;; Note: As on the mips port, space for a two word bignum is
	 ;; always allocated and the header size is set to either one
	 ;; or two words as appropriate.
	 (inst jmp :ns one-word-bignum)
	 ;; two word bignum
	 (inst mov y (logior (ash (1- (+ bignum-digits-offset 2))
				  n-widetag-bits)
			     bignum-widetag))
	 (inst jmp L1)
	 (emit-label one-word-bignum)
	 (inst mov y (logior (ash (1- (+ bignum-digits-offset 1))
				  n-widetag-bits)
			     bignum-widetag))
	 (emit-label L1)
	 (pseudo-atomic
	  (allocation alloc (pad-data-block (+ bignum-digits-offset 2)) node)
	  (storew y alloc)
	  (inst lea y (make-ea :byte :base alloc :disp other-pointer-lowtag))
	  (storew x y bignum-digits-offset other-pointer-lowtag))
	 (inst jmp done)))))
(define-move-vop move-from-unsigned :move
  (unsigned-reg) (descriptor-reg))

;;; Move untagged numbers.
(define-vop (word-move)
  (:args (x :scs (signed-reg unsigned-reg) :target y
	    :load-if (not (location= x y))))
  (:results (y :scs (signed-reg unsigned-reg)
	       :load-if
	       (not (or (location= x y)
			(and (sc-is x signed-reg unsigned-reg)
			     (sc-is y signed-stack unsigned-stack))))))
  (:effects)
  (:affected)
  (:note "word integer move")
  (:generator 0
    (move y x)))
(define-move-vop word-move :move
  (signed-reg unsigned-reg) (signed-reg unsigned-reg))

;;; Move untagged number arguments/return-values.
(define-vop (move-word-arg)
  (:args (x :scs (signed-reg unsigned-reg) :target y)
	 (fp :scs (any-reg) :load-if (not (sc-is y sap-reg))))
  (:results (y))
  (:note "word integer argument move")
  (:generator 0
    (sc-case y
      ((signed-reg unsigned-reg)
       (move y x))
      ((signed-stack unsigned-stack)
       (if (= (tn-offset fp) esp-offset)
	   (storew x fp (tn-offset y))	; c-call
	   (storew x fp (- (1+ (tn-offset y)))))))))
(define-move-vop move-word-arg :move-arg
  (descriptor-reg any-reg signed-reg unsigned-reg) (signed-reg unsigned-reg))

;;; Use standard MOVE-ARG and coercion to move an untagged number
;;; to a descriptor passing location.
(define-move-vop move-arg :move-arg
  (signed-reg unsigned-reg) (any-reg descriptor-reg))
