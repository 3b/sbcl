;;;; the VOPs and other necessary machine specific support
;;;; routines for call-out to C

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;; The MOVE-ARG vop is going to store args on the stack for
;; call-out. These tn's will be used for that. move-arg is normally
;; used for things going down the stack but C wants to have args
;; indexed in the positive direction.

(defun my-make-wired-tn (prim-type-name sc-name offset)
  (make-wired-tn (primitive-type-or-lose prim-type-name)
		 (sc-number-or-lose sc-name)
		 offset))

(defstruct (arg-state (:copier nil))
  (register-args 0)
  (xmm-args 0)
  (stack-frame-size 0))

(defun int-arg (state prim-type reg-sc stack-sc)
  (let ((reg-args (arg-state-register-args state)))
    (cond ((< reg-args 6)
	   (setf (arg-state-register-args state) (1+ reg-args))
	   (my-make-wired-tn prim-type reg-sc
			     (nth reg-args *c-call-register-arg-offsets*)))
	  (t
	   (let ((frame-size (arg-state-stack-frame-size state)))
	     (setf (arg-state-stack-frame-size state) (1+ frame-size))
	     (my-make-wired-tn prim-type stack-sc frame-size))))))

(define-alien-type-method (integer :arg-tn) (type state)
  (if (alien-integer-type-signed type)
      (int-arg state 'signed-byte-64 'signed-reg 'signed-stack)
      (int-arg state 'unsigned-byte-64 'unsigned-reg 'unsigned-stack)))

(define-alien-type-method (system-area-pointer :arg-tn) (type state)
  (declare (ignore type))
  (int-arg state 'system-area-pointer 'sap-reg 'sap-stack))

(defun float-arg (state prim-type reg-sc stack-sc)
  (let ((xmm-args (arg-state-xmm-args state)))
    (cond ((< xmm-args 8)
	   (setf (arg-state-xmm-args state) (1+ xmm-args))
	   (my-make-wired-tn prim-type reg-sc
			     (nth xmm-args *float-regs*)))
	  (t
	   (let ((frame-size (arg-state-stack-frame-size state)))
	     (setf (arg-state-stack-frame-size state) (1+ frame-size))
	     (my-make-wired-tn prim-type stack-sc frame-size))))))

(define-alien-type-method (double-float :arg-tn) (type state)
  (declare (ignore type))
  (float-arg state 'double-float 'double-reg 'double-stack))

(define-alien-type-method (single-float :arg-tn) (type state)
  (declare (ignore type))
  (float-arg state 'single-float 'single-reg 'single-stack))

(defstruct (result-state (:copier nil))
  (num-results 0))

(defun result-reg-offset (slot)
  (ecase slot
    (0 eax-offset)
    (1 edx-offset)))

;; XXX The return handling probably doesn't conform to the ABI

(define-alien-type-method (integer :result-tn) (type state)
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (multiple-value-bind (ptype reg-sc)
	(if (alien-integer-type-signed type)
	    (values (if (= (sb!alien::alien-integer-type-bits type) 32)
			'signed-byte-32
			'signed-byte-64)
		    'signed-reg)
	    (values 'unsigned-byte-64 'unsigned-reg))
      (my-make-wired-tn ptype reg-sc (result-reg-offset num-results)))))

(define-alien-type-method (system-area-pointer :result-tn) (type state)
  (declare (ignore type))
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (my-make-wired-tn 'system-area-pointer 'sap-reg
		      (result-reg-offset num-results))))

(define-alien-type-method (double-float :result-tn) (type state)
  (declare (ignore type))
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (my-make-wired-tn 'double-float 'double-reg num-results)))

(define-alien-type-method (single-float :result-tn) (type state)
  (declare (ignore type))
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (my-make-wired-tn 'single-float 'single-reg num-results 2)))

(define-alien-type-method (values :result-tn) (type state)
  (let ((values (alien-values-type-values type)))
    (when (> (length values) 2)
      (error "Too many result values from c-call."))
    (mapcar (lambda (type)
	      (invoke-alien-type-method :result-tn type state))
	    values)))

(!def-vm-support-routine make-call-out-tns (type)
  (let ((arg-state (make-arg-state)))
    (collect ((arg-tns))
      (dolist (arg-type (alien-fun-type-arg-types type))
	(arg-tns (invoke-alien-type-method :arg-tn arg-type arg-state)))
      (values (my-make-wired-tn 'positive-fixnum 'any-reg esp-offset)
	      (* (arg-state-stack-frame-size arg-state) n-word-bytes)
	      (arg-tns)
	      (invoke-alien-type-method :result-tn
					(alien-fun-type-result-type type)
					(make-result-state))))))


(deftransform %alien-funcall ((function type &rest args) * * :node node)
  (aver (sb!c::constant-lvar-p type))
  (let* ((type (sb!c::lvar-value type))
	 (env (sb!c::node-lexenv node))
         (arg-types (alien-fun-type-arg-types type))
         (result-type (alien-fun-type-result-type type)))
    (aver (= (length arg-types) (length args)))
    (if (or (some #'(lambda (type)
                      (and (alien-integer-type-p type)
                           (> (sb!alien::alien-integer-type-bits type) 64)))
                  arg-types)
            (and (alien-integer-type-p result-type)
                 (> (sb!alien::alien-integer-type-bits result-type) 64)))
        (collect ((new-args) (lambda-vars) (new-arg-types))
          (dolist (type arg-types)
            (let ((arg (gensym)))
              (lambda-vars arg)
              (cond ((and (alien-integer-type-p type)
                          (> (sb!alien::alien-integer-type-bits type) 64))
                     (new-args `(logand ,arg #xffffffff))
                     (new-args `(ash ,arg -64))
                     (new-arg-types (parse-alien-type '(unsigned 64) env))
                     (if (alien-integer-type-signed type)
                         (new-arg-types (parse-alien-type '(signed 64) env))
                         (new-arg-types (parse-alien-type '(unsigned 64) env))))
                    (t
                     (new-args arg)
                     (new-arg-types type)))))
          (cond ((and (alien-integer-type-p result-type)
                      (> (sb!alien::alien-integer-type-bits result-type) 64))
                 (let ((new-result-type
                        (let ((sb!alien::*values-type-okay* t))
                          (parse-alien-type
                           (if (alien-integer-type-signed result-type)
                               '(values (unsigned 64) (signed 64))
                               '(values (unsigned 64) (unsigned 64)))
			   env))))
                   `(lambda (function type ,@(lambda-vars))
                      (declare (ignore type))
                      (multiple-value-bind (low high)
                          (%alien-funcall function
                                          ',(make-alien-fun-type
                                             :arg-types (new-arg-types)
                                             :result-type new-result-type)
                                          ,@(new-args))
                        (logior low (ash high 64))))))
                (t
                 `(lambda (function type ,@(lambda-vars))
                    (declare (ignore type))
                    (%alien-funcall function
                                    ',(make-alien-fun-type
                                       :arg-types (new-arg-types)
                                       :result-type result-type)
                                    ,@(new-args))))))
        (sb!c::give-up-ir1-transform))))




(define-vop (foreign-symbol-address)
  (:translate foreign-symbol-address)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-base-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
   (inst lea res (make-fixup (extern-alien-name foreign-symbol) :foreign))))

#!+linkage-table
(define-vop (foreign-symbol-dataref-address)
  (:translate foreign-symbol-dataref-address)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
   (inst mov res (make-fixup (extern-alien-name foreign-symbol) :foreign-dataref))))

(define-vop (call-out)
  (:args (function :scs (sap-reg))
	 (args :more t))
  (:results (results :more t))
  (:temporary (:sc unsigned-reg :offset eax-offset
		   :from :eval :to :result) eax)
  (:temporary (:sc unsigned-reg :offset ecx-offset
		   :from :eval :to :result) ecx)
  (:temporary (:sc unsigned-reg :offset edx-offset
		   :from :eval :to :result) edx)
  (:node-var node)
  (:vop-var vop)
  (:save-p t)
  (:ignore args ecx edx)
  (:generator 0
    (cond ;; This probably doesn't make sense on x86-64 since the space-
          ;; intensive x87-frobbing doesn't need to be done. Disabled.
          #+nil 
	  ((policy node (> space speed))
	   (move eax function)
	   (inst call (make-fixup (extern-alien-name "call_into_c") :foreign)))
	  (t
 	   (inst call function)
	   ;; To give the debugger a clue. XX not really internal-error?
	   (note-this-location vop :internal-error)
	   ;; Sign-extend s-b-32 return values.
	   (dolist (res (if (listp results)
			    results
			    (list results)))
	     (let ((tn (tn-ref-tn res)))	       
	       (when (eq (sb!c::tn-primitive-type tn)
			 (primitive-type-or-lose 'signed-byte-32))
		 (inst shl tn 32)
		 (inst sar tn 32))))
           ;; FLOAT15 needs to contain FP zero in Lispland
           (inst xor ecx ecx)
           (inst movd (make-random-tn :kind :normal 
                                      :sc (sc-or-lose 'double-reg)
                                      :offset float15-offset)
                      ecx)))))

(define-vop (alloc-number-stack-space)
  (:info amount)
  (:results (result :scs (sap-reg any-reg)))
  (:generator 0
    (aver (location= result rsp-tn))
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 3) 3)))
	(inst sub rsp-tn delta)))
    (move result rsp-tn)))

(define-vop (dealloc-number-stack-space)
  (:info amount)
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 3) 3)))
	(inst add rsp-tn delta)))))

(define-vop (alloc-alien-stack-space)
  (:info amount)
  #!+sb-thread (:temporary (:sc unsigned-reg) temp)
  (:results (result :scs (sap-reg any-reg)))
  #!+sb-thread
  (:generator 0
    (aver (not (location= result rsp-tn)))
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 3) 3)))
	(inst mov temp
	      (make-ea :dword
		       :disp (+ nil-value
				(static-symbol-offset '*alien-stack*)
				(ash symbol-tls-index-slot word-shift)
				(- other-pointer-lowtag))))
	(inst fs-segment-prefix)
	(inst sub (make-ea :dword :scale 1 :index temp) delta)))
    (load-tl-symbol-value result *alien-stack*))
  #!-sb-thread
  (:generator 0
    (aver (not (location= result rsp-tn)))
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 3) 3)))
        (inst sub (make-ea :qword
                           :disp (+ nil-value
                                    (static-symbol-offset '*alien-stack*)
                                    (ash symbol-value-slot word-shift)
                                    (- other-pointer-lowtag)))
              delta)))
    (load-symbol-value result *alien-stack*)))

(define-vop (dealloc-alien-stack-space)
  (:info amount)
  #!+sb-thread (:temporary (:sc unsigned-reg) temp)
  #!+sb-thread
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 3) 3)))
	(inst mov temp
	      (make-ea :dword
			   :disp (+ nil-value
				    (static-symbol-offset '*alien-stack*)
				(ash symbol-tls-index-slot word-shift)
				(- other-pointer-lowtag))))
	(inst fs-segment-prefix)
	(inst add (make-ea :dword :scale 1 :index temp) delta))))
  #!-sb-thread
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 3) 3)))
        (inst add (make-ea :qword
                           :disp (+ nil-value
                                    (static-symbol-offset '*alien-stack*)
                                    (ash symbol-value-slot word-shift)
                                    (- other-pointer-lowtag)))
              delta)))))

;;; these are not strictly part of the c-call convention, but are
;;; needed for the WITH-PRESERVED-POINTERS macro used for "locking
;;; down" lisp objects so that GC won't move them while foreign
;;; functions go to work.

(define-vop (push-word-on-c-stack)
    (:translate push-word-on-c-stack)
  (:args (val :scs (sap-reg)))
  (:policy :fast-safe)
  (:arg-types system-area-pointer)
  (:generator 2
    (inst push val)))

(define-vop (pop-words-from-c-stack)
    (:translate pop-words-from-c-stack)
  (:args)
  (:arg-types (:constant (unsigned-byte 60)))
  (:info number)
  (:policy :fast-safe)
  (:generator 2
    (inst add rsp-tn (fixnumize number))))

