;;;; implementation-dependent transforms

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;; We need to define these predicates, since the TYPEP source
;;; transform picks whichever predicate was defined last when there
;;; are multiple predicates for equivalent types.
(define-source-transform short-float-p (x) `(single-float-p ,x))
#!-long-float
(define-source-transform long-float-p (x) `(double-float-p ,x))

(define-source-transform compiled-function-p (x)
  `(functionp ,x))

(define-source-transform char-int (x)
  `(char-code ,x))

(deftransform abs ((x) (rational))
  '(if (< x 0) (- x) x))

;;; The layout is stored in slot 0.
(define-source-transform %instance-layout (x)
  `(truly-the layout (%instance-ref ,x 0)))
(define-source-transform %set-instance-layout (x val)
  `(%instance-set ,x 0 (the layout ,val)))

;;;; character support

;;; In our implementation there are really only BASE-CHARs.
(define-source-transform characterp (obj)
  `(base-char-p ,obj))

;;;; simplifying HAIRY-DATA-VECTOR-REF and HAIRY-DATA-VECTOR-SET

(deftransform hairy-data-vector-ref ((array index) (array t) * :important t)
  "avoid runtime dispatch on array element type"
  (let ((element-ctype (extract-upgraded-element-type array)))
    (declare (type ctype element-ctype))
    (when (eq *wild-type* element-ctype)
      (give-up-ir1-transform
       "Upgraded element type of array is not known at compile time."))
    ;; (The expansion here is basically a degenerate case of
    ;; WITH-ARRAY-DATA. Since WITH-ARRAY-DATA is implemented as a
    ;; macro, and macros aren't expanded in transform output, we have
    ;; to hand-expand it ourselves.)
    (let ((element-type-specifier (type-specifier element-ctype)))
      `(multiple-value-bind (array index)
	   (%data-vector-and-index array index)
	 (declare (type (simple-array ,element-type-specifier 1) array))
	 (data-vector-ref array index)))))

(deftransform data-vector-ref ((array index)
                               (simple-array t))
  (let ((array-type (continuation-type array)))
    (unless (array-type-p array-type)
      (give-up-ir1-transform))
    (let ((dims (array-type-dimensions array-type)))
      (when (or (atom dims) (= (length dims) 1))
        (give-up-ir1-transform))
      (let ((el-type (array-type-specialized-element-type array-type))
            (total-size (if (member '* dims)
                            '*
                            (reduce #'* dims))))
        `(data-vector-ref (truly-the (simple-array ,(type-specifier el-type)
                                                   (,total-size))
                                     (%array-data-vector array))
                          index)))))

(deftransform hairy-data-vector-set ((array index new-value)
				     (array t t)
				     *
				     :important t)
  "avoid runtime dispatch on array element type"
  (let ((element-ctype (extract-upgraded-element-type array)))
    (declare (type ctype element-ctype))
    (when (eq *wild-type* element-ctype)
      (give-up-ir1-transform
       "Upgraded element type of array is not known at compile time."))
    (let ((element-type-specifier (type-specifier element-ctype)))
      `(multiple-value-bind (array index)
	   (%data-vector-and-index array index)
	 (declare (type (simple-array ,element-type-specifier 1) array)
	          (type ,element-type-specifier new-value))
	 (data-vector-set array
			  index
			  new-value)))))

(deftransform data-vector-set ((array index new-value)
                               (simple-array t t))
  (let ((array-type (continuation-type array)))
    (unless (array-type-p array-type)
      (give-up-ir1-transform))
    (let ((dims (array-type-dimensions array-type)))
      (when (or (atom dims) (= (length dims) 1))
        (give-up-ir1-transform))
      (let ((el-type (array-type-specialized-element-type array-type))
            (total-size (if (member '* dims)
                            '*
                            (reduce #'* dims))))
        `(data-vector-set (truly-the (simple-array ,(type-specifier el-type)
                                                   (,total-size))
                                     (%array-data-vector array))
                          index
                          new-value)))))

(defoptimizer (%data-vector-and-index derive-type) ((array index))
  (let ((atype (continuation-type array)))
    (when (array-type-p atype)
      (values-specifier-type
       `(values (simple-array ,(type-specifier
                                (array-type-specialized-element-type atype))
                              (*))
                index)))))

(deftransform %data-vector-and-index ((array index)
                                     (simple-array t)
                                     *
                                     :important t)

  ;; We do this solely for the -OR-GIVE-UP side effect, since we want
  ;; to know that the type can be figured out in the end before we
  ;; proceed, but we don't care yet what the type will turn out to be.
  (upgraded-element-type-specifier-or-give-up array)

  '(if (array-header-p array)
       (values (%array-data-vector array) index)
       (values array index)))

;;; transforms for getting at simple arrays of (UNSIGNED-BYTE N) when (< N 8)
;;;
;;; FIXME: In CMU CL, these were commented out with #+NIL. Why? Should
;;; we fix them or should we delete them? (Perhaps these definitions
;;; predate the various DATA-VECTOR-REF-FOO VOPs which have
;;; (:TRANSLATE DATA-VECTOR-REF), and are redundant now?)
#+nil
(macrolet
    ((frob (type bits)
       (let ((elements-per-word (truncate sb!vm:n-word-bits bits)))
	 `(progn
	    (deftransform data-vector-ref ((vector index)
					   (,type *))
	      `(multiple-value-bind (word bit)
		   (floor index ,',elements-per-word)
		 (ldb ,(ecase sb!vm:target-byte-order
			 (:little-endian '(byte ,bits (* bit ,bits)))
			 (:big-endian '(byte ,bits (- sb!vm:n-word-bits
						      (* (1+ bit) ,bits)))))
		      (%raw-bits vector (+ word sb!vm:vector-data-offset)))))
	    (deftransform data-vector-set ((vector index new-value)
					   (,type * *))
	      `(multiple-value-bind (word bit)
		   (floor index ,',elements-per-word)
		 (setf (ldb ,(ecase sb!vm:target-byte-order
			       (:little-endian '(byte ,bits (* bit ,bits)))
			       (:big-endian
				'(byte ,bits (- sb!vm:n-word-bits
						(* (1+ bit) ,bits)))))
			    (%raw-bits vector (+ word sb!vm:vector-data-offset)))
		       new-value)))))))
  (frob simple-bit-vector 1)
  (frob (simple-array (unsigned-byte 2) (*)) 2)
  (frob (simple-array (unsigned-byte 4) (*)) 4))

;;;; BIT-VECTOR hackery

;;; SIMPLE-BIT-VECTOR bit-array operations are transformed to a word
;;; loop that does 32 bits at a time.
;;;
;;; FIXME: This is a lot of repeatedly macroexpanded code. It should
;;; be a function call instead.
(macrolet ((def (bitfun wordfun)
             `(deftransform ,bitfun ((bit-array-1 bit-array-2 result-bit-array)
                                     (simple-bit-vector
				      simple-bit-vector
				      simple-bit-vector)
				     *
                                     :node node :policy (>= speed space))
                `(progn
                   ,@(unless (policy node (zerop safety))
                             '((unless (= (length bit-array-1)
					  (length bit-array-2)
                                          (length result-bit-array))
                                 (error "Argument and/or result bit arrays are not the same length:~
			 ~%  ~S~%  ~S  ~%  ~S"
                                        bit-array-1
					bit-array-2
					result-bit-array))))
		  (let ((length (length result-bit-array)))
		    (if (= length 0)
			;; We avoid doing anything to 0-length
			;; bit-vectors, or rather, the memory that
			;; follows them. Other divisible-by-32 cases
			;; are handled by the (1- length), below.
			;; CSR, 2002-04-24
			result-bit-array
			(do ((index sb!vm:vector-data-offset (1+ index))
			     (end-1 (+ sb!vm:vector-data-offset
				       ;; bit-vectors of length 1-32
				       ;; need precisely one (SETF
				       ;; %RAW-BITS), done here in the
				       ;; epilogue. - CSR, 2002-04-24
				       (truncate (truly-the index (1- length))
						 sb!vm:n-word-bits))))
			    ((= index end-1)
			     (setf (%raw-bits result-bit-array index)
				   (,',wordfun (%raw-bits bit-array-1 index)
					       (%raw-bits bit-array-2 index)))
			     result-bit-array)
			  (declare (optimize (speed 3) (safety 0))
				   (type index index end-1))
			  (setf (%raw-bits result-bit-array index)
				(,',wordfun (%raw-bits bit-array-1 index)
					    (%raw-bits bit-array-2 index))))))))))
 (def bit-and 32bit-logical-and)
 (def bit-ior 32bit-logical-or)
 (def bit-xor 32bit-logical-xor)
 (def bit-eqv 32bit-logical-eqv)
 (def bit-nand 32bit-logical-nand)
 (def bit-nor 32bit-logical-nor)
 (def bit-andc1 32bit-logical-andc1)
 (def bit-andc2 32bit-logical-andc2)
 (def bit-orc1 32bit-logical-orc1)
 (def bit-orc2 32bit-logical-orc2))

(deftransform bit-not
	      ((bit-array result-bit-array)
	       (simple-bit-vector simple-bit-vector) *
	       :node node :policy (>= speed space))
  `(progn
     ,@(unless (policy node (zerop safety))
	 '((unless (= (length bit-array)
		      (length result-bit-array))
	     (error "Argument and result bit arrays are not the same length:~
	     	     ~%  ~S~%  ~S"
		    bit-array result-bit-array))))
    (let ((length (length result-bit-array)))
      (if (= length 0)
	  ;; We avoid doing anything to 0-length bit-vectors, or
	  ;; rather, the memory that follows them. Other
	  ;; divisible-by-32 cases are handled by the (1- length),
	  ;; below.  CSR, 2002-04-24
	  result-bit-array
	  (do ((index sb!vm:vector-data-offset (1+ index))
	       (end-1 (+ sb!vm:vector-data-offset
			 ;; bit-vectors of length 1-32 need precisely
			 ;; one (SETF %RAW-BITS), done here in the
			 ;; epilogue. - CSR, 2002-04-24
			 (truncate (truly-the index (1- length))
				   sb!vm:n-word-bits))))
	      ((= index end-1)
	       (setf (%raw-bits result-bit-array index)
		     (32bit-logical-not (%raw-bits bit-array index)))
	       result-bit-array)
	    (declare (optimize (speed 3) (safety 0))
		     (type index index end-1))
	    (setf (%raw-bits result-bit-array index)
		  (32bit-logical-not (%raw-bits bit-array index))))))))

(deftransform bit-vector-= ((x y) (simple-bit-vector simple-bit-vector))
  `(and (= (length x) (length y))
        (let ((length (length x)))
	  (or (= length 0)
	      (do* ((i sb!vm:vector-data-offset (+ i 1))
		    (end-1 (+ sb!vm:vector-data-offset
			      (floor (1- length) sb!vm:n-word-bits))))
		   ((= i end-1)
		    (let* ((extra (mod length sb!vm:n-word-bits))
			   (mask (1- (ash 1 extra)))
			   (numx
			    (logand
			     (ash mask
				  ,(ecase sb!c:*backend-byte-order*
				     (:little-endian 0)
				     (:big-endian
				      '(- sb!vm:n-word-bits extra))))
			     (%raw-bits x i)))
			   (numy
			    (logand
			     (ash mask
				  ,(ecase sb!c:*backend-byte-order*
				     (:little-endian 0)
				     (:big-endian
				      '(- sb!vm:n-word-bits extra))))
			     (%raw-bits y i))))
		      (declare (type (integer 0 31) extra)
			       (type (unsigned-byte 32) mask numx numy))
		      (= numx numy)))
		(declare (type index i end-1))
		(let ((numx (%raw-bits x i))
		      (numy (%raw-bits y i)))
		  (declare (type (unsigned-byte 32) numx numy))
		  (unless (= numx numy)
		    (return nil))))))))

;;;; %BYTE-BLT

;;; FIXME: The old CMU CL code used various COPY-TO/FROM-SYSTEM-AREA
;;; stuff (with all the associated bit-index cruft and overflow
;;; issues) even for byte moves. In SBCL, we're converting to byte
;;; moves as problems are discovered with the old code, and this is
;;; currently (ca. sbcl-0.6.12.30) the main interface for code in
;;; SB!KERNEL and SB!SYS (e.g. i/o code). It's not clear that it's the
;;; ideal interface, though, and it probably deserves some thought.
(deftransform %byte-blt ((src src-start dst dst-start dst-end)
			 ((or (simple-unboxed-array (*)) system-area-pointer)
			  index
			  (or (simple-unboxed-array (*)) system-area-pointer)
			  index
			  index))
  ;; FIXME: CMU CL had a hairier implementation of this (back when it
  ;; was still called (%PRIMITIVE BYTE-BLT). It had the small problem
  ;; that it didn't work for large (>16M) values of SRC-START or
  ;; DST-START. However, it might have been more efficient. In
  ;; particular, I don't really know how much the foreign function
  ;; call costs us here. My guess is that if the overhead is
  ;; acceptable for SQRT and COS, it's acceptable here, but this
  ;; should probably be checked. -- WHN
  '(flet ((sapify (thing)
	    (etypecase thing
	      (system-area-pointer thing)
	      ;; FIXME: The code here rather relies on the simple
	      ;; unboxed array here having byte-sized entries. That
	      ;; should be asserted explicitly, I just haven't found
	      ;; a concise way of doing it. (It would be nice to
	      ;; declare it in the DEFKNOWN too.)
	      ((simple-unboxed-array (*)) (vector-sap thing)))))
     (declare (inline sapify))
     (without-gcing
      (memmove (sap+ (sapify dst) dst-start)
	       (sap+ (sapify src) src-start)
	       (- dst-end dst-start)))
     nil))

;;;; transforms for EQL of floating point values

(deftransform eql ((x y) (single-float single-float))
  '(= (single-float-bits x) (single-float-bits y)))

(deftransform eql ((x y) (double-float double-float))
  '(and (= (double-float-low-bits x) (double-float-low-bits y))
	(= (double-float-high-bits x) (double-float-high-bits y))))

