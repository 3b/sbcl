;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")

(/show0 "target-defstruct.lisp 12")

;;;; structure frobbing primitives

;;; Allocate a new instance with LENGTH data slots.
(defun %make-instance (length)
  (declare (type index length))
  (%make-instance length))

;;; Given an instance, return its length.
(defun %instance-length (instance)
  (declare (type instance instance))
  (%instance-length instance))

;;; Return the value from the INDEXth slot of INSTANCE. This is SETFable.
(defun %instance-ref (instance index)
  (%instance-ref instance index))

;;; Set the INDEXth slot of INSTANCE to NEW-VALUE.
(defun %instance-set (instance index new-value)
  (setf (%instance-ref instance index) new-value))

(defun %raw-ref-single (vec index)
  (declare (type index index))
  (%raw-ref-single vec index))

(defun %raw-ref-double (vec index)
  (declare (type index index))
  (%raw-ref-double vec index))

#!+long-float
(defun %raw-ref-long (vec index)
  (declare (type index index))
  (%raw-ref-long vec index))

(defun %raw-set-single (vec index val)
  (declare (type index index))
  (%raw-set-single vec index val))

(defun %raw-set-double (vec index val)
  (declare (type index index))
  (%raw-set-double vec index val))

#!+long-float
(defun %raw-set-long (vec index val)
  (declare (type index index))
  (%raw-set-long vec index val))

(defun %raw-ref-complex-single (vec index)
  (declare (type index index))
  (%raw-ref-complex-single vec index))

(defun %raw-ref-complex-double (vec index)
  (declare (type index index))
  (%raw-ref-complex-double vec index))

#!+long-float
(defun %raw-ref-complex-long (vec index)
  (declare (type index index))
  (%raw-ref-complex-long vec index))

(defun %raw-set-complex-single (vec index val)
  (declare (type index index))
  (%raw-set-complex-single vec index val))

(defun %raw-set-complex-double (vec index val)
  (declare (type index index))
  (%raw-set-complex-double vec index val))

#!+long-float
(defun %raw-set-complex-long (vec index val)
  (declare (type index index))
  (%raw-set-complex-long vec index val))

(defun %instance-layout (instance)
  (%instance-layout instance))

(defun %set-instance-layout (instance new-value)
  (%set-instance-layout instance new-value))

(defun %make-funcallable-instance (len layout)
   (%make-funcallable-instance len layout))

(defun funcallable-instance-p (x) (funcallable-instance-p x))

(defun %funcallable-instance-info (fin i)
  (%funcallable-instance-info fin i))

(defun %set-funcallable-instance-info (fin i new-value)
  (%set-funcallable-instance-info fin i new-value))

(defun funcallable-instance-fun (fin)
  (%funcallable-instance-lexenv fin))

;;; The heart of the magic of funcallable instances ("FINs"). The
;;; function for a FIN must be a magical INSTANCE-LAMBDA form. When
;;; called (as with any other function), we grab the code pointer, and
;;; call it, leaving the original function object in LEXENV (in case
;;; it was a closure). If it is actually a FIN, then we need to do an
;;; extra indirection with funcallable-instance-lexenv to get at any
;;; closure environment. This extra indirection is set up when
;;; accessing the closure environment of an INSTANCE-LAMBDA. Note that
;;; the original FIN pointer is lost, so if the called function wants
;;; to get at the original object to do some slot accesses, it must
;;; close over the FIN object.
;;;
;;; If we set the FIN function to be a FIN, we directly copy across
;;; both the code pointer and the lexenv, since that code pointer (for
;;; an instance-lambda) is expecting that lexenv to be accessed. This
;;; effectively pre-flattens what would otherwise be a chain of
;;; indirections. (That used to happen when PCL dispatch functions
;;; were byte-compiled; now that the byte compiler is gone, I can't
;;; think of another example offhand. -- WHN 2001-10-06)
;;;
;;; The only loss is that if someone accesses the
;;; FUNCALLABLE-INSTANCE-FUN, then won't get a FIN back. This probably
;;; doesn't matter, since PCL only sets the FIN function.
(defun (setf funcallable-instance-fun) (new-value fin)
  (setf (%funcallable-instance-fun fin)
	(%closure-fun new-value))
  (setf (%funcallable-instance-lexenv fin)
	(if (funcallable-instance-p new-value)
	    (%funcallable-instance-lexenv new-value)
	    new-value)))

;;; service function for structure constructors
(defun %make-instance-with-layout (layout)
  (let ((result (%make-instance (layout-length layout))))
    (setf (%instance-layout result) layout)
    result))

;;;; target-only parts of the DEFSTRUCT top level code

;;; A list of hooks designating functions of one argument, the
;;; classoid, to be called when a defstruct is evaluated.
(defvar *defstruct-hooks* nil)

;;; Catch attempts to mess up definitions of symbols in the CL package.
(defun protect-cl (symbol)
  (/show0 "entering PROTECT-CL, SYMBOL=..")
  (/hexstr symbol)
  (when (and *cold-init-complete-p*
	     (eq (symbol-package symbol) *cl-package*))
    (cerror "Go ahead and patch the system."
	    "attempting to modify a symbol in the COMMON-LISP package: ~S"
	    symbol))
  (/show0 "leaving PROTECT-CL")
  (values))

;;; the part of %DEFSTRUCT which makes sense only on the target SBCL
;;;
;;; (The "static" in the name is because it needs to be done not only
;;; in ordinary toplevel %DEFSTRUCT, but also in cold init as early as
;;; possible, to simulate static linking of structure functions as
;;; nearly as possible.)
(defun %target-defstruct (dd layout)
  (declare (type defstruct-description dd))
  (declare (type layout layout))

  (/show0 "entering %TARGET-DEFSTRUCT")

  (remhash (dd-name dd) *typecheckfuns*)

  ;; (Constructors aren't set up here, because constructors are
  ;; varied enough (possibly parsing any specified argument list)
  ;; that we can't reasonably implement them as closures, so we
  ;; implement them with DEFUN instead.)

  ;; Set FDEFINITIONs for slot accessors.
  (dolist (dsd (dd-slots dd))
    (/show0 "doing FDEFINITION for slot accessor")
    (let ((accessor-name (dsd-accessor-name dsd)))
      ;; We mustn't step on any inherited accessors
      (unless (accessor-inherited-data accessor-name dd)
	(/show0 "ACCESSOR-NAME=..")
	(/hexstr accessor-name)
	(protect-cl accessor-name)
	(/hexstr "getting READER-FUN and WRITER-FUN")
	(multiple-value-bind (reader-fun writer-fun)
	    (slot-accessor-funs dd dsd)
	  (declare (type function reader-fun writer-fun))
	  (/show0 "got READER-FUN and WRITER-FUN=..")
	  (/hexstr reader-fun)
	  (setf (symbol-function accessor-name) reader-fun)
	  (unless (dsd-read-only dsd)
	    (/show0 "setting FDEFINITION for WRITER-FUN=..")
	    (/hexstr writer-fun)
	    (setf (fdefinition `(setf ,accessor-name)) writer-fun))))))

  ;; Set FDEFINITION for copier.
  (when (dd-copier-name dd)
    (/show0 "doing FDEFINITION for copier")
    (protect-cl (dd-copier-name dd))
    ;; We can't use COPY-STRUCTURE for other kinds of objects, notably
    ;; funcallable structures, since it returns a STRUCTURE-OBJECT.
    ;; (And funcallable instances don't need copiers anyway.)
    (aver (eql (dd-type dd) 'structure))
    (setf (symbol-function (dd-copier-name dd))
	  ;; FIXME: should use a closure which checks arg type before copying
	  #'copy-structure))

  ;; Set FDEFINITION for predicate.
  (when (dd-predicate-name dd)
    (/show0 "doing FDEFINITION for predicate")
    (protect-cl (dd-predicate-name dd))
    (setf (symbol-function (dd-predicate-name dd))
	  (ecase (dd-type dd)
	    ;; structures with LAYOUTs
	    ((structure funcallable-structure)
	     (/show0 "with-LAYOUT case")
	     (lambda (object)
	       (locally ; <- to keep SAFETY 0 from affecting arg count checking
		 (declare (optimize (speed 3) (safety 0)))
		 (/noshow0 "in with-LAYOUT structure predicate closure, OBJECT,LAYOUT=..")
		 (/nohexstr object)
		 (/nohexstr layout)
		 (typep-to-layout object layout))))
	    ;; structures with no LAYOUT (i.e. :TYPE VECTOR or :TYPE LIST)
	    ;;
	    ;; FIXME: should handle the :NAMED T case in these cases
	    (vector
	     (/show0 ":TYPE VECTOR case")
	     #'vectorp)
	    (list
	     (/show0 ":TYPE LIST case")
	     #'listp))))

  (when (dd-doc dd)
    (setf (fdocumentation (dd-name dd) 'type)
	  (dd-doc dd)))

  ;; the BOUNDP test here is to get past cold-init.
  (when (boundp '*defstruct-hooks*)
    (dolist (fun *defstruct-hooks*)
      (funcall fun (find-classoid (dd-name dd)))))
  
  (/show0 "leaving %TARGET-DEFSTRUCT")
  (values))

;;;; generating out-of-line slot accessor functions

;;; FIXME: Ideally, the presence of the type checks in the functions
;;; here would be conditional on the optimization policy at the point
;;; of expansion of DEFSTRUCT. (For now we're just doing the simpler
;;; thing, putting in the type checks unconditionally.)

;;; Return (VALUES SLOT-READER-FUN SLOT-WRITER-FUN).
(defun slot-accessor-funs (dd dsd)

  #+sb-xc (/show0 "entering SLOT-ACCESSOR-FUNS")

  ;; various code generators
  ;;
  ;; Note: They're only minimally parameterized, and cavalierly grab
  ;; things like INSTANCE and DSD-INDEX from the namespace they're
  ;; expanded in.
  (macrolet (;; code shared between funcallable instance case and the
	     ;; ordinary STRUCTURE-OBJECT case: Handle native
	     ;; structures with LAYOUTs and (possibly) raw slots.
	     (%native-slot-accessor-funs (dd-ref-fun-name)
	       (let ((instance-type-check-form
		      '(%check-structure-type-from-layout instance layout)))
		 (/show "macroexpanding %NATIVE-SLOT-ACCESSOR-FUNS" dd-ref-fun-name instance-type-check-form)
		 `(let ((layout (dd-layout-or-lose dd))
			(dsd-raw-type (dsd-raw-type dsd)))
		    #+sb-xc (/show0 "in %NATIVE-SLOT-ACCESSOR-FUNS macroexpanded code")
		    ;; Map over all the possible RAW-TYPEs, compiling
		    ;; a different closure function for each one, so
		    ;; that once the COND over RAW-TYPEs happens (at
		    ;; the time closure is allocated) there are no
		    ;; more decisions to be made and things execute
		    ;; reasonably efficiently.
		    (cond
		     ;; nonraw slot case
		     ((eql dsd-raw-type t)
		      #+sb-xc (/show0 "in nonraw slot case")
		      (%slotplace-accessor-funs
		       (,dd-ref-fun-name instance dsd-index)
		       ,instance-type-check-form))
		     ;; raw slot cases
		     ,@(mapcar (lambda (rtd)
				 (let ((raw-type (raw-slot-data-raw-type rtd))
				       (accessor-name
					(raw-slot-data-accessor-name rtd))
				       (n-words (raw-slot-data-n-words rtd)))
				   `((equal dsd-raw-type ',raw-type)
				     #+sb-xc (/show0 "in raw slot case")
				     (let ((raw-index (dd-raw-index dd)))
				       (multiple-value-bind (scaled-dsd-index
							     misalignment)
					   (floor dsd-index ,n-words)
					 (aver (zerop misalignment))
					 (%slotplace-accessor-funs
					  (,accessor-name (,dd-ref-fun-name
							   instance
							   raw-index)
							  scaled-dsd-index)
					  ,instance-type-check-form))))))
			       *raw-slot-data-list*)
		     ;; oops
		     (t
		      (bug "unexpected DSD-RAW-TYPE ~S" dsd-raw-type))))))
	     ;; code shared between DEFSTRUCT :TYPE LIST and
	     ;; DEFSTRUCT :TYPE VECTOR cases: Handle the "typed
	     ;; structure" case, with no LAYOUTs and no raw slots.
	     (%colontyped-slot-accessor-funs () (error "stub")) 
	     ;; the common structure of the raw-slot and not-raw-slot
	     ;; cases, defined in terms of the writable SLOTPLACE. All
	     ;; possible flavors of slot access should be able to pass
	     ;; through here.
	     (%slotplace-accessor-funs (slotplace instance-type-check-form)
	       (/show "macroexpanding %SLOTPLACE-ACCESSOR-FUNS" slotplace instance-type-check-form)
	       `(let ((typecheckfun (typespec-typecheckfun dsd-type)))
                  (values (if (dsd-safe-p dsd)
                              (lambda (instance)
                                (/noshow0 "in %SLOTPLACE-ACCESSOR-FUNS-defined reader")
                                ,instance-type-check-form
                                (/noshow0 "back from INSTANCE-TYPE-CHECK-FORM")
                                ,slotplace)
                              (lambda (instance)
                                (/noshow0 "in %SLOTPLACE-ACCESSOR-FUNS-defined reader")
                                ,instance-type-check-form
                                (/noshow0 "back from INSTANCE-TYPE-CHECK-FORM")
                                (let ((value ,slotplace))
                                  (funcall typecheckfun value)
                                  value)))
                          (lambda (new-value instance)
			    (/noshow0 "in %SLOTPLACE-ACCESSOR-FUNS-defined writer")
			    ,instance-type-check-form
			    (/noshow0 "back from INSTANCE-TYPE-CHECK-FORM")
			    (funcall typecheckfun new-value)
			    (/noshow0 "back from TYPECHECKFUN")
			    (setf ,slotplace new-value))))))

    (let ((dsd-index (dsd-index dsd))
	  (dsd-type (dsd-type dsd)))

      #+sb-xc (/show0 "got DSD-TYPE=..")
      #+sb-xc (/hexstr dsd-type)
      (ecase (dd-type dd)

	;; native structures
	(structure
	 #+sb-xc (/show0 "case of DSD-TYPE = STRUCTURE")
	 (%native-slot-accessor-funs %instance-ref))

	;; structures with the :TYPE option

	;; FIXME: Worry about these later..
	#|
        ;; In :TYPE LIST and :TYPE VECTOR structures, ANSI specifies the
        ;; layout completely, so that raw slots are impossible.
        (list
         (dd-type-slot-accessor-funs nth-but-with-sane-arg-order
  	    			 `(%check-structure-type-from-dd
    		  		 :maybe-raw-p nil))
        (vector
         (dd-type-slot-accessor-funs aref
  	  			 :maybe-raw-p nil)))
        |#
	))))

;;; Copy any old kind of structure.
(defun copy-structure (structure)
  #!+sb-doc
  "Return a copy of STRUCTURE with the same (EQL) slot values."
  (declare (type structure-object structure))
  (let* ((len (%instance-length structure))
	 (res (%make-instance len))
	 (layout (%instance-layout structure)))

    (declare (type index len))
    (when (layout-invalid layout)
      (error "attempt to copy an obsolete structure:~%  ~S" structure))

    ;; Copy ordinary slots.
    (dotimes (i len)
      (declare (type index i))
      (setf (%instance-ref res i)
	    (%instance-ref structure i)))

    ;; Copy raw slots.
    (let ((raw-index (dd-raw-index (layout-info layout))))
      (when raw-index
	(let* ((data (%instance-ref structure raw-index))
	       (raw-len (length data))
	       (new (make-array raw-len :element-type 'sb!vm::word)))
	  (declare (type (simple-array sb!vm::word (*)) data))
	  (setf (%instance-ref res raw-index) new)
	  (dotimes (i raw-len)
	    (setf (aref new i) (aref data i))))))

    res))

;;; default PRINT-OBJECT method

(defun %default-structure-pretty-print (structure stream)
  (let* ((layout (%instance-layout structure))
	 (name (classoid-name (layout-classoid layout)))
	 (dd (layout-info layout)))
    ;; KLUDGE: during the build process with SB-SHOW, we can sometimes
    ;; attempt to print out a PCL object (with null LAYOUT-INFO).
    #!+sb-show
    (when (null dd)
      (pprint-logical-block (stream nil :prefix "#<" :suffix ">")
	(prin1 name stream)
	(write-char #\space stream)
	(write-string "(no LAYOUT-INFO)"))
      (return-from %default-structure-pretty-print nil))
    ;; the structure type doesn't count as a component for
    ;; *PRINT-LEVEL* processing.  We can likewise elide the logical
    ;; block processing, since all we have to print is the type name.
    ;; -- CSR, 2004-10-05
    (when (and dd (null (dd-slots dd)))
      (write-string "#S(" stream)
      (prin1 name stream)
      (write-char #\) stream)
      (return-from %default-structure-pretty-print nil))
    (pprint-logical-block (stream nil :prefix "#S(" :suffix ")")
      (prin1 name stream)
      (let ((remaining-slots (dd-slots dd)))
	(when remaining-slots
	  (write-char #\space stream)
	  ;; CMU CL had (PPRINT-INDENT :BLOCK 2 STREAM) here,
	  ;; but I can't see why. -- WHN 20000205
	  (pprint-newline :linear stream)
	  (loop
	   (pprint-pop)
	   (let ((slot (pop remaining-slots)))
	     (write-char #\: stream)
	     (output-symbol-name (symbol-name (dsd-name slot)) stream)
	     (write-char #\space stream)
	     (pprint-newline :miser stream)
	     (output-object (funcall (fdefinition (dsd-accessor-name slot))
				     structure)
			    stream)
	     (when (null remaining-slots)
	       (return))
	     (write-char #\space stream)
	     (pprint-newline :linear stream))))))))
(defun %default-structure-ugly-print (structure stream)
  (let* ((layout (%instance-layout structure))
	 (name (classoid-name (layout-classoid layout)))
	 (dd (layout-info layout)))
    (when (and dd (null (dd-slots dd)))
      (write-string "#S(" stream)
      (prin1 name stream)
      (write-char #\) stream)
      (return-from %default-structure-ugly-print nil))
    (descend-into (stream)
      (write-string "#S(" stream)
      (prin1 name stream)
      (do ((index 0 (1+ index))
	   (remaining-slots (dd-slots dd) (cdr remaining-slots)))
	  ((or (null remaining-slots)
	       (and (not *print-readably*)
		    *print-length*
		    (>= index *print-length*)))
	   (if (null remaining-slots)
	       (write-string ")" stream)
	       (write-string " ...)" stream)))
	(declare (type index index))
	(write-char #\space stream)
	(write-char #\: stream)
	(let ((slot (first remaining-slots)))
	  (output-symbol-name (symbol-name (dsd-name slot)) stream)
	  (write-char #\space stream)
	  (output-object
	   (funcall (fdefinition (dsd-accessor-name slot))
		    structure)
	   stream))))))
(defun default-structure-print (structure stream depth)
  (declare (ignore depth))
  (cond ((funcallable-instance-p structure)
	 (print-unreadable-object (structure stream :identity t :type t)))
	(*print-pretty*
	 (%default-structure-pretty-print structure stream))
	(t
	 (%default-structure-ugly-print structure stream))))
(def!method print-object ((x structure-object) stream)
  (default-structure-print x stream *current-level-in-print*))

;;;; testing structure types

;;; Return true if OBJ is an object of the structure type
;;; corresponding to LAYOUT. This is called by the accessor closures,
;;; which have a handle on the type's LAYOUT.
;;;
;;; FIXME: This is fairly big, so it should probably become
;;; MAYBE-INLINE instead of INLINE, or its inlineness should become
;;; conditional (probably through DEFTRANSFORM) on (> SPEED SPACE). Or
;;; else we could fix things up so that the things which call it are
;;; all closures, so that it's expanded only in a small number of
;;; places.
#!-sb-fluid (declaim (inline typep-to-layout))
(defun typep-to-layout (obj layout)
  (declare (type layout layout) (optimize (speed 3) (safety 0)))
  (/noshow0 "entering TYPEP-TO-LAYOUT, OBJ,LAYOUT=..")
  (/nohexstr obj)
  (/nohexstr layout)
  (when (layout-invalid layout)
    (error "An obsolete structure accessor function was called."))
  (/noshow0 "back from testing LAYOUT-INVALID LAYOUT")
  ;; FIXME: CMU CL used (%INSTANCEP OBJ) here. Check that
  ;; (TYPEP OBJ 'INSTANCE) is optimized to equally efficient code.
  (and (typep obj 'instance)
       (let ((obj-layout (%instance-layout obj)))
	 (cond ((eq obj-layout layout)
		;; (In this case OBJ-LAYOUT can't be invalid, because
		;; we determined LAYOUT is valid in the test above.)
		(/noshow0 "EQ case")
		t)
	       ((layout-invalid obj-layout)
		(/noshow0 "LAYOUT-INVALID case")
		(error 'layout-invalid
		       :expected-type (layout-classoid obj-layout)
		       :datum obj))
	       (t
		(let ((depthoid (layout-depthoid layout)))
		  (/noshow0 "DEPTHOID case, DEPTHOID,LAYOUT-INHERITS=..")
		  (/nohexstr depthoid)
		  (/nohexstr layout-inherits)
		  (and (> (layout-depthoid obj-layout) depthoid)
		       (eq (svref (layout-inherits obj-layout) depthoid)
			   layout))))))))

;;;; checking structure types

;;; Check that X is an instance of the named structure type.
(defmacro %check-structure-type-from-name (x name)
  `(%check-structure-type-from-layout ,x ,(compiler-layout-or-lose name)))

;;; Check that X is a structure of the type described by DD.
(defmacro %check-structure-type-from-dd (x dd)
  (declare (type defstruct-description dd))
  (let ((class-name (dd-name dd)))
    (ecase (dd-type dd)
      ((structure funcallable-instance)
       `(%check-structure-type-from-layout
	 ,x
	 ,(compiler-layout-or-lose class-name)))
      ((vector)
       (with-unique-names (xx)
	 `(let ((,xx ,x))
	    (declare (type vector ,xx))
	    ,@(when (dd-named dd)
		`((unless (eql (aref ,xx 0) ',class-name)
		    (error
		     'simple-type-error
		     :datum (aref ,xx 0)
		     :expected-type `(member ,class-name)
		     :format-control
		     "~@<missing name in instance of ~
                      VECTOR-typed structure ~S: ~2I~_S~:>"
		     :format-arguments (list ',class-name ,xx)))))
	    (values))))
      ((list)
       (with-unique-names (xx)
	 `(let ((,xx ,x))
	    (declare (type list ,xx))
	    ,@(when (dd-named dd)
		`((unless (eql (first ,xx) ',class-name)
		    (error
		     'simple-type-error
		     :datum (aref ,xx 0)
		     :expected-type `(member ,class-name)
		     :format-control
		     "~@<missing name in instance of LIST-typed structure ~S: ~
                      ~2I~_S~:>"
		     :format-arguments (list ',class-name ,xx)))))
	    (values)))))))

;;; Check that X is an instance of the structure class with layout LAYOUT.
(defun %check-structure-type-from-layout (x layout)
  (unless (typep-to-layout x layout)
    (error 'type-error
	   :datum x
	   :expected-type (classoid-name (layout-classoid layout))))
  (values))

(/show0 "target-defstruct.lisp end of file")
