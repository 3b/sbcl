;;;; miscellaneous VM definition noise for the x86-64

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;; the size of an INTEGER representation of a SYSTEM-AREA-POINTER, i.e.
;;; size of a native memory address
(deftype sap-int () '(unsigned-byte 64))

;;;; register specs

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *byte-register-names* (make-array 8 :initial-element nil))
  (defvar *word-register-names* (make-array 16 :initial-element nil))
  (defvar *dword-register-names* (make-array 16 :initial-element nil))
  (defvar *qword-register-names* (make-array 32 :initial-element nil))
  (defvar *xmm-register-names* (make-array 16 :initial-element nil)))

(macrolet ((defreg (name offset size)
	     (let ((offset-sym (symbolicate name "-OFFSET"))
		   (names-vector (symbolicate "*" size "-REGISTER-NAMES*")))
	       `(progn
		  (eval-when (:compile-toplevel :load-toplevel :execute)
                    ;; EVAL-WHEN is necessary because stuff like #.EAX-OFFSET
                    ;; (in the same file) depends on compile-time evaluation
                    ;; of the DEFCONSTANT. -- AL 20010224
		    (def!constant ,offset-sym ,offset))
		  (setf (svref ,names-vector ,offset-sym)
			,(symbol-name name)))))
	   ;; FIXME: It looks to me as though DEFREGSET should also
	   ;; define the related *FOO-REGISTER-NAMES* variable.
	   (defregset (name &rest regs)
	     `(eval-when (:compile-toplevel :load-toplevel :execute)
		(defparameter ,name
		  (list ,@(mapcar (lambda (name)
				    (symbolicate name "-OFFSET"))
				  regs))))))

  ;; byte registers
  ;;
  ;; Note: the encoding here is different than that used by the chip.
  ;; We use this encoding so that the compiler thinks that AX (and
  ;; EAX) overlap AL and AH instead of AL and CL.
  (defreg al 0 :byte)
  (defreg ah 1 :byte)
  (defreg cl 2 :byte)
  (defreg ch 3 :byte)
  (defreg dl 4 :byte)
  (defreg dh 5 :byte)
  (defreg bl 6 :byte)
  (defreg bh 7 :byte)
  (defregset *byte-regs* al ah cl ch dl dh bl bh)

  ;; word registers
  (defreg ax 0 :word)
  (defreg cx 2 :word)
  (defreg dx 4 :word)
  (defreg bx 6 :word)
  (defreg sp 8 :word)
  (defreg bp 10 :word)
  (defreg si 12 :word)
  (defreg di 14 :word)
  (defregset *word-regs* ax cx dx bx si di)

  ;; double word registers
  (defreg eax 0 :dword)
  (defreg ecx 2 :dword)
  (defreg edx 4 :dword)
  (defreg ebx 6 :dword)
  (defreg esp 8 :dword)
  (defreg ebp 10 :dword)
  (defreg esi 12 :dword)
  (defreg edi 14 :dword)
  (defregset *dword-regs* eax ecx edx ebx esi edi)

  ;; quadword registers
  (defreg rax 0 :qword)
  (defreg rcx 2 :qword)
  (defreg rdx 4 :qword)
  (defreg rbx 6 :qword)
  (defreg rsp 8 :qword)
  (defreg rbp 10 :qword)
  (defreg rsi 12 :qword)
  (defreg rdi 14 :qword)
  (defreg r8  16 :qword)
  (defreg r9  18 :qword)
  (defreg r10 20 :qword)
  (defreg r11 22 :qword)
  (defreg r12 24 :qword)
  (defreg r13 26 :qword)
  (defreg r14 28 :qword)
  (defreg r15 30 :qword)
  (defregset *qword-regs* rax rcx rdx rbx rsi rdi 
	     r8 r9 r10 r11 #+nil r12 #+nil r13 r14 r15)

  ;; floating point registers
  (defreg xmm0 0 :float)
  (defreg xmm1 1 :float)
  (defreg xmm2 2 :float)
  (defreg xmm3 3 :float)
  (defreg xmm4 4 :float)
  (defreg xmm5 5 :float)
  (defreg xmm6 6 :float)
  (defreg xmm7 7 :float)
  (defreg xmm8 8 :float)
  (defreg xmm9 9 :float)
  (defreg xmm10 10 :float)
  (defreg xmm11 11 :float)
  (defreg xmm12 12 :float)
  (defreg xmm13 13 :float)
  (defreg xmm14 14 :float)
  (defreg xmm15 15 :float)
  (defregset *xmm-regs* xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7
	     xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15)

  ;; registers used to pass arguments
  ;;
  ;; the number of arguments/return values passed in registers
  (def!constant  register-arg-count 3)
  ;; names and offsets for registers used to pass arguments
  (eval-when (:compile-toplevel :load-toplevel :execute)
    (defparameter *register-arg-names* '(rdx rdi rsi)))
  (defregset    *register-arg-offsets* rdx rdi rsi))

;;;; SB definitions

;;; There are 16 registers really, but we consider them 32 in order to
;;; describe the overlap of byte registers. The only thing we need to
;;; represent is what registers overlap. Therefore, we consider bytes
;;; to take one unit, and [dq]?words to take two. We don't need to
;;; tell the difference between [dq]?words, because you can't put two
;;; words in a dword register.
(define-storage-base registers :finite :size 32)

(define-storage-base xmm-registers :finite :size 16)

(define-storage-base stack :unbounded :size 8)
(define-storage-base constant :non-packed)
(define-storage-base immediate-constant :non-packed)
(define-storage-base noise :unbounded :size 2)

;;;; SC definitions

;;; a handy macro so we don't have to keep changing all the numbers whenever
;;; we insert a new storage class
;;;
(defmacro !define-storage-classes (&rest classes)
  (collect ((forms))
    (let ((index 0))
      (dolist (class classes)
	(let* ((sc-name (car class))
	       (constant-name (symbolicate sc-name "-SC-NUMBER")))
	  (forms `(define-storage-class ,sc-name ,index
		    ,@(cdr class)))
	  (forms `(def!constant ,constant-name ,index))
	  (incf index))))
    `(progn
       ,@(forms))))

;;; The DEFINE-STORAGE-CLASS call for CATCH-BLOCK refers to the size
;;; of CATCH-BLOCK. The size of CATCH-BLOCK isn't calculated until
;;; later in the build process, and the calculation is entangled with
;;; code which has lots of predependencies, including dependencies on
;;; the prior call of DEFINE-STORAGE-CLASS. The proper way to
;;; unscramble this would be to untangle the code, so that the code
;;; which calculates the size of CATCH-BLOCK can be separated from the
;;; other lots-of-dependencies code, so that the code which calculates
;;; the size of CATCH-BLOCK can be executed early, so that this value
;;; is known properly at this point in compilation. However, that
;;; would be a lot of editing of code that I (WHN 19990131) can't test
;;; until the project is complete. So instead, I set the correct value
;;; by hand here (a sort of nondeterministic guess of the right
;;; answer:-) and add an assertion later, after the value is
;;; calculated, that the original guess was correct.
;;;
;;; (What a KLUDGE! Anyone who wants to come in and clean up this mess
;;; has my gratitude.) (FIXME: Maybe this should be me..)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (def!constant kludge-nondeterministic-catch-block-size 6))

(!define-storage-classes

  ;; non-immediate constants in the constant pool
  (constant constant)

  (immediate immediate-constant)

  ;;
  ;; the stacks
  ;;
  
  ;; the control stack
  (control-stack stack)			; may be pointers, scanned by GC

  ;; the non-descriptor stacks
  ;; XXX alpha backend has :element-size 2 :alignment 2 in these entries
  (signed-stack stack)			; (signed-byte 32)
  (unsigned-stack stack)		; (unsigned-byte 32)
  (base-char-stack stack)		; non-descriptor characters.
  (sap-stack stack)			; System area pointers.
  (single-stack stack)			; single-floats
  (double-stack stack)
  (complex-single-stack stack :element-size 2)	; complex-single-floats
  (complex-double-stack stack :element-size 2)	; complex-double-floats


  ;;
  ;; magic SCs
  ;;

  (ignore-me noise)

  ;;
  ;; things that can go in the integer registers
  ;;

  ;; On the X86, we don't have to distinguish between descriptor and
  ;; non-descriptor registers, because of the conservative GC.
  ;; Therefore, we use different scs only to distinguish between
  ;; descriptor and non-descriptor values and to specify size.

  ;; immediate descriptor objects. Don't have to be seen by GC, but nothing
  ;; bad will happen if they are. (fixnums, characters, header values, etc).
  (any-reg registers
	   :locations #.*qword-regs*
	   :element-size 2 ; I think this is for the al/ah overlap thing
	   :constant-scs (immediate)
	   :save-p t
	   :alternate-scs (control-stack))

  ;; pointer descriptor objects -- must be seen by GC
  (descriptor-reg registers
		  :locations #.*qword-regs*
		  :element-size 2
;		  :reserve-locations (#.eax-offset)
		  :constant-scs (constant immediate)
		  :save-p t
		  :alternate-scs (control-stack))

  ;; non-descriptor characters
  (base-char-reg registers
		 :locations #.*byte-regs*
		 :reserve-locations (#.ah-offset #.al-offset)
		 :constant-scs (immediate)
		 :save-p t
		 :alternate-scs (base-char-stack))

  ;; non-descriptor SAPs (arbitrary pointers into address space)
  (sap-reg registers
	   :locations #.*qword-regs*
	   :element-size 2
;	   :reserve-locations (#.eax-offset)
	   :constant-scs (immediate)
	   :save-p t
	   :alternate-scs (sap-stack))

  ;; non-descriptor (signed or unsigned) numbers
  (signed-reg registers
	      :locations #.*qword-regs*
	      :element-size 2
	      :constant-scs (immediate)
	      :save-p t
	      :alternate-scs (signed-stack))
  (unsigned-reg registers
		:locations #.*qword-regs*
		:element-size 2
		:constant-scs (immediate)
		:save-p t
		:alternate-scs (unsigned-stack))

  ;; miscellaneous objects that must not be seen by GC. Used only as
  ;; temporaries.
  (word-reg registers
	    :locations #.*word-regs*
	    :element-size 2
	    )
  (dword-reg registers
	    :locations #.*dword-regs*
	    :element-size 2
	    )
  (byte-reg registers
	    :locations #.*byte-regs*
	    )

  ;; that can go in the floating point registers

  ;; non-descriptor SINGLE-FLOATs
  (single-reg xmm-registers
	      :locations #.(loop for i from 0 to 15 collect i)
	      :constant-scs (fp-constant)
	      :save-p t
	      :alternate-scs (single-stack))

  ;; non-descriptor DOUBLE-FLOATs
  (double-reg xmm-registers
	      :locations #.(loop for i from 0 to 15 collect i)
	      :constant-scs (fp-constant)
	      :save-p t
	      :alternate-scs (double-stack))

  (complex-single-reg xmm-registers
		      :locations #.(loop for i from 0 to 14 by 2 collect i)
		      :element-size 2
		      :constant-scs ()
		      :save-p t
		      :alternate-scs (complex-single-stack))

  (complex-double-reg xmm-registers
		      :locations #.(loop for i from 0 to 14 by 2 collect i)
		      :element-size 2
		      :constant-scs ()
		      :save-p t
		      :alternate-scs (complex-double-stack))

  ;; a catch or unwind block
  (catch-block stack :element-size kludge-nondeterministic-catch-block-size))

(eval-when (:compile-toplevel :load-toplevel :execute)
(defparameter *byte-sc-names* '(base-char-reg byte-reg base-char-stack))
(defparameter *word-sc-names* '(word-reg))
(defparameter *dword-sc-names* '(dword-reg))
(defparameter *qword-sc-names* 
  '(any-reg descriptor-reg sap-reg signed-reg unsigned-reg control-stack
    signed-stack unsigned-stack sap-stack single-stack constant))
;;; added by jrd. I guess the right thing to do is to treat floats
;;; as a separate size...
;;;
;;; These are used to (at least) determine operand size.
(defparameter *float-sc-names* '(single-reg))
(defparameter *double-sc-names* '(double-reg double-stack))
) ; EVAL-WHEN

;;;; miscellaneous TNs for the various registers

(macrolet ((def-misc-reg-tns (sc-name &rest reg-names)
	     (collect ((forms))
		      (dolist (reg-name reg-names)
			(let ((tn-name (symbolicate reg-name "-TN"))
			      (offset-name (symbolicate reg-name "-OFFSET")))
			  ;; FIXME: It'd be good to have the special
			  ;; variables here be named with the *FOO*
			  ;; convention.
			  (forms `(defparameter ,tn-name
				    (make-random-tn :kind :normal
						    :sc (sc-or-lose ',sc-name)
						    :offset
						    ,offset-name)))))
		      `(progn ,@(forms)))))

  (def-misc-reg-tns unsigned-reg rax rbx rcx rdx rbp rsp rdi rsi
		    r8 r9 r10 r11  r12 r13 r14 r15)
  (def-misc-reg-tns dword-reg eax ebx ecx edx ebp esp edi esi)
  (def-misc-reg-tns word-reg ax bx cx dx bp sp di si)
  (def-misc-reg-tns byte-reg al ah bl bh cl ch dl dh)
  (def-misc-reg-tns single-reg 
      xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7
      xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15))

;;; TNs for registers used to pass arguments
(defparameter *register-arg-tns*
  (mapcar (lambda (register-arg-name)
	    (symbol-value (symbolicate register-arg-name "-TN")))
	  *register-arg-names*))


(defparameter fp-single-zero-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'single-reg)
		  :offset 15))

(defparameter fp-double-zero-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'double-reg)
		  :offset 15))

;;; If value can be represented as an immediate constant, then return
;;; the appropriate SC number, otherwise return NIL.
(!def-vm-support-routine immediate-constant-sc (value)
  (typecase value
    ((or (integer #.sb!xc:most-negative-fixnum #.sb!xc:most-positive-fixnum)
	 #-sb-xc-host system-area-pointer character)
     (sc-number-or-lose 'immediate))
    (symbol
     (when (static-symbol-p value)
       (sc-number-or-lose 'immediate)))
    (single-float
     (if (eql value 0f0)
	 (sc-number-or-lose 'fp-single-zero )
	 nil))
    (double-float
     (if (eql value 0d0)
	 (sc-number-or-lose 'fp-double-zero )
	 nil))))


;;;; miscellaneous function call parameters

;;; offsets of special stack frame locations
(def!constant ocfp-save-offset 0)
(def!constant return-pc-save-offset 1)
(def!constant code-save-offset 2)

(def!constant lra-save-offset return-pc-save-offset) ; ?

;;; This is used by the debugger.
(def!constant single-value-return-byte-offset 3)

;;; This function is called by debug output routines that want a pretty name
;;; for a TN's location. It returns a thing that can be printed with PRINC.
(!def-vm-support-routine location-print-name (tn)
  (declare (type tn tn))
  (let* ((sc (tn-sc tn))
	 (sb (sb-name (sc-sb sc)))
	 (offset (tn-offset tn)))
    (ecase sb
      (registers
       (let* ((sc-name (sc-name sc))
	      (name-vec (cond ((member sc-name *byte-sc-names*)
			       *byte-register-names*)
			      ((member sc-name *word-sc-names*)
			       *word-register-names*)
			      ((member sc-name *dword-sc-names*)
			       *dword-register-names*)
			      ((member sc-name *qword-sc-names*)
			       *qword-register-names*))))
	 (or (and name-vec
		  (< -1 offset (length name-vec))
		  (svref name-vec offset))
	     ;; FIXME: Shouldn't this be an ERROR?
	     (format nil "<unknown reg: off=~W, sc=~A>" offset sc-name))))
      (float-registers (format nil "FR~D" offset))
      (stack (format nil "S~D" offset))
      (constant (format nil "Const~D" offset))
      (immediate-constant "Immed")
      (noise (symbol-name (sc-name sc))))))
;;; FIXME: Could this, and everything that uses it, be made #!+SB-SHOW?


;;; The loader uses this to convert alien names to the form they need in
;;; the symbol table (for example, prepending an underscore).
(defun extern-alien-name (name)
  (declare (type simple-base-string name))
  ;; OpenBSD is non-ELF, and needs a _ prefix
  #!+openbsd (concatenate 'string "_" name)
  ;; The other (ELF) ports currently don't need any prefix
  #!-openbsd name)

(defun dwords-for-quad (value)
  (let* ((lo (logand value (1- (ash 1 32))))
	 (hi (ash (- value lo) -32)))
    (values lo hi)))
