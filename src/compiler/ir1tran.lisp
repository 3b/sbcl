;;;; This file contains code which does the translation from Lisp code
;;;; to the first intermediate representation (IR1).

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

(declaim (special *compiler-error-bailout*))

;;; *SOURCE-PATHS* is a hashtable from source code forms to the path
;;; taken through the source to reach the form. This provides a way to
;;; keep track of the location of original source forms, even when
;;; macroexpansions and other arbitary permutations of the code
;;; happen. This table is initialized by calling FIND-SOURCE-PATHS on
;;; the original source.
(declaim (hash-table *source-paths*))
(defvar *source-paths*)

;;; *CURRENT-COMPONENT* is the Component structure which we link
;;; blocks into as we generate them. This just serves to glue the
;;; emitted blocks together until local call analysis and flow graph
;;; canonicalization figure out what is really going on. We need to
;;; keep track of all the blocks generated so that we can delete them
;;; if they turn out to be unreachable.
;;;
;;; FIXME: It's confusing having one variable named *CURRENT-COMPONENT*
;;; and another named *COMPONENT-BEING-COMPILED*. (In CMU CL they
;;; were called *CURRENT-COMPONENT* and *COMPILE-COMPONENT* respectively,
;;; which also confusing.)
(declaim (type (or component null) *current-component*))
(defvar *current-component*)

;;; *CURRENT-PATH* is the source path of the form we are currently
;;; translating. See NODE-SOURCE-PATH in the NODE structure.
(declaim (list *current-path*))
(defvar *current-path*)

(defvar *derive-function-types* nil
  "Should the compiler assume that function types will never change,
  so that it can use type information inferred from current definitions
  to optimize code which uses those definitions? Setting this true
  gives non-ANSI, early-CMU-CL behavior. It can be useful for improving
  the efficiency of stable code.")

;;;; namespace management utilities

;;; Return a GLOBAL-VAR structure usable for referencing the global
;;; function NAME.
(defun find-free-really-function (name)
  (unless (info :function :kind name)
    (setf (info :function :kind name) :function)
    (setf (info :function :where-from name) :assumed))

  (let ((where (info :function :where-from name)))
    (when (and (eq where :assumed)
	       ;; In the ordinary target Lisp, it's silly to report
	       ;; undefinedness when the function is defined in the
	       ;; running Lisp. But at cross-compile time, the current
	       ;; definedness of a function is irrelevant to the
	       ;; definedness at runtime, which is what matters.
	       #-sb-xc-host (not (fboundp name)))
      (note-undefined-reference name :function))
    (make-global-var :kind :global-function
		     :name name
		     :type (if (or *derive-function-types*
				   (eq where :declared))
			       (info :function :type name)
			       (specifier-type 'function))
		     :where-from where)))

;;; Return a SLOT-ACCESSOR structure usable for referencing the slot
;;; accessor NAME. CLASS is the structure class.
(defun find-structure-slot-accessor (class name)
  (declare (type sb!xc:class class))
  (let* ((info (layout-info
		(or (info :type :compiler-layout (sb!xc:class-name class))
		    (class-layout class))))
	 (accessor-name (if (listp name) (cadr name) name))
	 (slot (find accessor-name (dd-slots info)
		     :key #'sb!kernel:dsd-accessor-name))
	 (type (dd-name info))
	 (slot-type (dsd-type slot)))
    (unless slot
      (error "can't find slot ~S" type))
    (make-slot-accessor
     :name name
     :type (specifier-type
	    (if (listp name)
		`(function (,slot-type ,type) ,slot-type)
		`(function (,type) ,slot-type)))
     :for class
     :slot slot)))

;;; If NAME is already entered in *FREE-FUNCTIONS*, then return the
;;; value. Otherwise, make a new GLOBAL-VAR using information from the
;;; global environment and enter it in *FREE-FUNCTIONS*. If NAME names
;;; a macro or special form, then we error out using the supplied
;;; context which indicates what we were trying to do that demanded a
;;; function.
(defun find-free-function (name context)
  (declare (string context))
  (declare (values global-var))
  (or (gethash name *free-functions*)
      (ecase (info :function :kind name)
	;; FIXME: The :MACRO and :SPECIAL-FORM cases could be merged.
	(:macro
	 (compiler-error "The macro name ~S was found ~A." name context))
	(:special-form
	 (compiler-error "The special form name ~S was found ~A."
			 name
			 context))
	((:function nil)
	 (check-function-name name)
	 (note-if-setf-function-and-macro name)
	 (let ((expansion (info :function :inline-expansion name))
	       (inlinep (info :function :inlinep name)))
	   (setf (gethash name *free-functions*)
		 (if (or expansion inlinep)
		     (make-defined-function
		      :name name
		      :inline-expansion expansion
		      :inlinep inlinep
		      :where-from (info :function :where-from name)
		      :type (info :function :type name))
		     (let ((info (info :function :accessor-for name)))
		       (etypecase info
			 (null
			  (find-free-really-function name))
			 (sb!xc:structure-class
			  (find-structure-slot-accessor info name))
			 (sb!xc:class
			  (if (typep (layout-info (info :type :compiler-layout
							(sb!xc:class-name
							 info)))
				     'defstruct-description)
			      (find-structure-slot-accessor info name)
			      (find-free-really-function name))))))))))))

;;; Return the LEAF structure for the lexically apparent function
;;; definition of NAME.
(declaim (ftype (function (t string) leaf) find-lexically-apparent-function))
(defun find-lexically-apparent-function (name context)
  (let ((var (lexenv-find name functions :test #'equal)))
    (cond (var
	   (unless (leaf-p var)
	     (aver (and (consp var) (eq (car var) 'macro)))
	     (compiler-error "found macro name ~S ~A" name context))
	   var)
	  (t
	   (find-free-function name context)))))

;;; Return the LEAF node for a global variable reference to NAME. If
;;; NAME is already entered in *FREE-VARIABLES*, then we just return
;;; the corresponding value. Otherwise, we make a new leaf using
;;; information from the global environment and enter it in
;;; *FREE-VARIABLES*. If the variable is unknown, then we emit a
;;; warning.
(defun find-free-variable (name)
  (declare (values (or leaf heap-alien-info)))
  (unless (symbolp name)
    (compiler-error "Variable name is not a symbol: ~S." name))
  (or (gethash name *free-variables*)
      (let ((kind (info :variable :kind name))
	    (type (info :variable :type name))
	    (where-from (info :variable :where-from name)))
	(when (and (eq where-from :assumed) (eq kind :global))
	  (note-undefined-reference name :variable))

	(setf (gethash name *free-variables*)
	      (if (eq kind :alien)
		  (info :variable :alien-info name)
		  (multiple-value-bind (val valp)
		      (info :variable :constant-value name)
		    (if (and (eq kind :constant) valp)
			(make-constant :value val
				       :name name
				       :type (ctype-of val)
				       :where-from where-from)
			(make-global-var :kind kind
					 :name name
					 :type type
					 :where-from where-from))))))))

;;; Grovel over CONSTANT checking for any sub-parts that need to be
;;; processed with MAKE-LOAD-FORM. We have to be careful, because
;;; CONSTANT might be circular. We also check that the constant (and
;;; any subparts) are dumpable at all.
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; The EVAL-WHEN is necessary for #.(1+ LIST-TO-HASH-TABLE-THRESHOLD) 
  ;; below. -- AL 20010227
  (defconstant list-to-hash-table-threshold 32))
(defun maybe-emit-make-load-forms (constant)
  (let ((things-processed nil)
	(count 0))
    ;; FIXME: Does this LIST-or-HASH-TABLE messiness give much benefit?
    (declare (type (or list hash-table) things-processed)
	     (type (integer 0 #.(1+ list-to-hash-table-threshold)) count)
	     (inline member))
    (labels ((grovel (value)
	       ;; Unless VALUE is an object which which obviously
	       ;; can't contain other objects
	       (unless (typep value
			      '(or #-sb-xc-host unboxed-array
				   symbol
				   number
				   character
				   string))
		 (etypecase things-processed
		   (list
		    (when (member value things-processed :test #'eq)
		      (return-from grovel nil))
		    (push value things-processed)
		    (incf count)
		    (when (> count list-to-hash-table-threshold)
		      (let ((things things-processed))
			(setf things-processed
			      (make-hash-table :test 'eq))
			(dolist (thing things)
			  (setf (gethash thing things-processed) t)))))
		   (hash-table
		    (when (gethash value things-processed)
		      (return-from grovel nil))
		    (setf (gethash value things-processed) t)))
		 (typecase value
		   (cons
		    (grovel (car value))
		    (grovel (cdr value)))
		   (simple-vector
		    (dotimes (i (length value))
		      (grovel (svref value i))))
		   ((vector t)
		    (dotimes (i (length value))
		      (grovel (aref value i))))
		   ((simple-array t)
		    ;; Even though the (ARRAY T) branch does the exact
		    ;; same thing as this branch we do this separately
		    ;; so that the compiler can use faster versions of
		    ;; array-total-size and row-major-aref.
		    (dotimes (i (array-total-size value))
		      (grovel (row-major-aref value i))))
		   ((array t)
		    (dotimes (i (array-total-size value))
		      (grovel (row-major-aref value i))))
		   (;; In the target SBCL, we can dump any instance,
		    ;; but in the cross-compilation host,
		    ;; %INSTANCE-FOO functions don't work on general
		    ;; instances, only on STRUCTURE!OBJECTs.
		    #+sb-xc-host structure!object
		    #-sb-xc-host instance
		    (when (emit-make-load-form value)
		      (dotimes (i (%instance-length value))
			(grovel (%instance-ref value i)))))
		   (t
		    (compiler-error
		     "Objects of type ~S can't be dumped into fasl files."
		     (type-of value)))))))
      (grovel constant)))
  (values))

;;;; some flow-graph hacking utilities

;;; This function sets up the back link between the node and the
;;; continuation which continues at it.
#!-sb-fluid (declaim (inline prev-link))
(defun prev-link (node cont)
  (declare (type node node) (type continuation cont))
  (aver (not (continuation-next cont)))
  (setf (continuation-next cont) node)
  (setf (node-prev node) cont))

;;; This function is used to set the continuation for a node, and thus
;;; determine what receives the value and what is evaluated next. If
;;; the continuation has no block, then we make it be in the block
;;; that the node is in. If the continuation heads its block, we end
;;; our block and link it to that block. If the continuation is not
;;; currently used, then we set the derived-type for the continuation
;;; to that of the node, so that a little type propagation gets done.
;;;
;;; We also deal with a bit of THE's semantics here: we weaken the
;;; assertion on CONT to be no stronger than the assertion on CONT in
;;; our scope. See the IR1-CONVERT method for THE.
#!-sb-fluid (declaim (inline use-continuation))
(defun use-continuation (node cont)
  (declare (type node node) (type continuation cont))
  (let ((node-block (continuation-block (node-prev node))))
    (case (continuation-kind cont)
      (:unused
       (setf (continuation-block cont) node-block)
       (setf (continuation-kind cont) :inside-block)
       (setf (continuation-use cont) node)
       (setf (node-cont node) cont))
      (t
       (%use-continuation node cont)))))
(defun %use-continuation (node cont)
  (declare (type node node) (type continuation cont) (inline member))
  (let ((block (continuation-block cont))
	(node-block (continuation-block (node-prev node))))
    (aver (eq (continuation-kind cont) :block-start))
    (when (block-last node-block)
      (error "~S has already ended." node-block))
    (setf (block-last node-block) node)
    (when (block-succ node-block)
      (error "~S already has successors." node-block))
    (setf (block-succ node-block) (list block))
    (when (memq node-block (block-pred block))
      (error "~S is already a predecessor of ~S." node-block block))
    (push node-block (block-pred block))
    (add-continuation-use node cont)
    (unless (eq (continuation-asserted-type cont) *wild-type*)
      (let ((new (values-type-union (continuation-asserted-type cont)
				    (or (lexenv-find cont type-restrictions)
					*wild-type*))))
	(when (type/= new (continuation-asserted-type cont))
	  (setf (continuation-asserted-type cont) new)
	  (reoptimize-continuation cont))))))

;;;; exported functions

;;; This function takes a form and the top-level form number for that
;;; form, and returns a lambda representing the translation of that
;;; form in the current global environment. The returned lambda is a
;;; top-level lambda that can be called to cause evaluation of the
;;; forms. This lambda is in the initial component. If FOR-VALUE is T,
;;; then the value of the form is returned from the function,
;;; otherwise NIL is returned.
;;;
;;; This function may have arbitrary effects on the global environment
;;; due to processing of PROCLAIMs and EVAL-WHENs. All syntax error
;;; checking is done, with erroneous forms being replaced by a proxy
;;; which signals an error if it is evaluated. Warnings about possibly
;;; inconsistent or illegal changes to the global environment will
;;; also be given.
;;;
;;; We make the initial component and convert the form in a PROGN (and
;;; an optional NIL tacked on the end.) We then return the lambda. We
;;; bind all of our state variables here, rather than relying on the
;;; global value (if any) so that IR1 conversion will be reentrant.
;;; This is necessary for EVAL-WHEN processing, etc.
;;;
;;; The hashtables used to hold global namespace info must be
;;; reallocated elsewhere. Note also that *LEXENV* is not bound, so
;;; that local macro definitions can be introduced by enclosing code.
(defun ir1-top-level (form path for-value)
  (declare (list path))
  (let* ((*current-path* path)
	 (component (make-empty-component))
	 (*current-component* component))
    (setf (component-name component) "initial component")
    (setf (component-kind component) :initial)
    (let* ((forms (if for-value `(,form) `(,form nil)))
	   (res (ir1-convert-lambda-body forms ())))
      (setf (leaf-name res) "top-level form")
      (setf (functional-entry-function res) res)
      (setf (functional-arg-documentation res) ())
      (setf (functional-kind res) :top-level)
      res)))

;;; *CURRENT-FORM-NUMBER* is used in FIND-SOURCE-PATHS to compute the
;;; form number to associate with a source path. This should be bound
;;; to an initial value of 0 before the processing of each truly
;;; top-level form.
(declaim (type index *current-form-number*))
(defvar *current-form-number*)

;;; This function is called on freshly read forms to record the
;;; initial location of each form (and subform.) Form is the form to
;;; find the paths in, and TLF-NUM is the top-level form number of the
;;; truly top-level form.
;;;
;;; This gets a bit interesting when the source code is circular. This
;;; can (reasonably?) happen in the case of circular list constants.
(defun find-source-paths (form tlf-num)
  (declare (type index tlf-num))
  (let ((*current-form-number* 0))
    (sub-find-source-paths form (list tlf-num)))
  (values))
(defun sub-find-source-paths (form path)
  (unless (gethash form *source-paths*)
    (setf (gethash form *source-paths*)
	  (list* 'original-source-start *current-form-number* path))
    (incf *current-form-number*)
    (let ((pos 0)
	  (subform form)
	  (trail form))
      (declare (fixnum pos))
      (macrolet ((frob ()
		   '(progn
		      (when (atom subform) (return))
		      (let ((fm (car subform)))
			(when (consp fm)
			  (sub-find-source-paths fm (cons pos path)))
			(incf pos))
		      (setq subform (cdr subform))
		      (when (eq subform trail) (return)))))
	(loop
	  (frob)
	  (frob)
	  (setq trail (cdr trail)))))))

;;;; IR1-CONVERT, macroexpansion and special form dispatching

(macrolet (;; Bind *COMPILER-ERROR-BAILOUT* to a function that throws
	   ;; out of the body and converts a proxy form instead.
	   (ir1-error-bailout ((start
				cont
				form
				&optional
				(proxy ``(error "execution of a form compiled with errors:~% ~S"
						',,form)))
			       &body body)
			      (let ((skip (gensym "SKIP")))
				`(block ,skip
				   (catch 'ir1-error-abort
				     (let ((*compiler-error-bailout*
					    (lambda ()
					      (throw 'ir1-error-abort nil))))
				       ,@body
				       (return-from ,skip nil)))
				   (ir1-convert ,start ,cont ,proxy)))))

  ;; Translate FORM into IR1. The code is inserted as the NEXT of the
  ;; continuation START. CONT is the continuation which receives the
  ;; value of the FORM to be translated. The translators call this
  ;; function recursively to translate their subnodes.
  ;;
  ;; As a special hack to make life easier in the compiler, a LEAF
  ;; IR1-converts into a reference to that LEAF structure. This allows
  ;; the creation using backquote of forms that contain leaf
  ;; references, without having to introduce dummy names into the
  ;; namespace.
  (declaim (ftype (function (continuation continuation t) (values)) ir1-convert))
  (defun ir1-convert (start cont form)
    (ir1-error-bailout (start cont form)
      (let ((*current-path* (or (gethash form *source-paths*)
				(cons form *current-path*))))
	(if (atom form)
	    (cond ((and (symbolp form) (not (keywordp form)))
		   (ir1-convert-variable start cont form))
		  ((leaf-p form)
		   (reference-leaf start cont form))
		  (t
		   (reference-constant start cont form)))
	    (let ((fun (car form)))
	      (cond
	       ((symbolp fun)
		(let ((lexical-def (lexenv-find fun functions)))
		  (typecase lexical-def
		    (null (ir1-convert-global-functoid start cont form))
		    (functional
		     (ir1-convert-local-combination start
						    cont
						    form
						    lexical-def))
		    (global-var
		     (ir1-convert-srctran start cont lexical-def form))
		    (t
		     (aver (and (consp lexical-def)
				(eq (car lexical-def) 'macro)))
		     (ir1-convert start cont
				  (careful-expand-macro (cdr lexical-def)
							form))))))
	       ((or (atom fun) (not (eq (car fun) 'lambda)))
		(compiler-error "illegal function call"))
	       (t
		(ir1-convert-combination start
					 cont
					 form
					 (ir1-convert-lambda fun))))))))
    (values))

  ;; Generate a reference to a manifest constant, creating a new leaf
  ;; if necessary. If we are producing a fasl file, make sure that
  ;; MAKE-LOAD-FORM gets used on any parts of the constant that it
  ;; needs to be.
  (defun reference-constant (start cont value)
    (declare (type continuation start cont)
	     (inline find-constant))
    (ir1-error-bailout
     (start cont value
	    '(error "attempt to reference undumpable constant"))
     (when (producing-fasl-file)
       (maybe-emit-make-load-forms value))
     (let* ((leaf (find-constant value))
	    (res (make-ref (leaf-type leaf) leaf)))
       (push res (leaf-refs leaf))
       (prev-link res start)
       (use-continuation res cont)))
    (values)))

;;; Add Fun to the COMPONENT-REANALYZE-FUNCTIONS. Fun is returned.
 (defun maybe-reanalyze-function (fun)
  (declare (type functional fun))
  (when (typep fun '(or optional-dispatch clambda))
    (pushnew fun (component-reanalyze-functions *current-component*)))
  fun)

;;; Generate a REF node for LEAF, frobbing the LEAF structure as
;;; needed. If LEAF represents a defined function which has already
;;; been converted, and is not :NOTINLINE, then reference the
;;; functional instead.
(defun reference-leaf (start cont leaf)
  (declare (type continuation start cont) (type leaf leaf))
  (let* ((leaf (or (and (defined-function-p leaf)
			(not (eq (defined-function-inlinep leaf)
				 :notinline))
			(let ((fun (defined-function-functional leaf)))
			  (when (and fun (not (functional-kind fun)))
			    (maybe-reanalyze-function fun))))
		   leaf))
	 (res (make-ref (or (lexenv-find leaf type-restrictions)
			    (leaf-type leaf))
			leaf)))
    (push res (leaf-refs leaf))
    (setf (leaf-ever-used leaf) t)
    (prev-link res start)
    (use-continuation res cont)))

;;; Convert a reference to a symbolic constant or variable. If the
;;; symbol is entered in the LEXENV-VARIABLES we use that definition,
;;; otherwise we find the current global definition. This is also
;;; where we pick off symbol macro and Alien variable references.
(defun ir1-convert-variable (start cont name)
  (declare (type continuation start cont) (symbol name))
  (let ((var (or (lexenv-find name variables) (find-free-variable name))))
    (etypecase var
      (leaf
       (when (and (lambda-var-p var) (lambda-var-ignorep var))
	 ;; (ANSI's specification for the IGNORE declaration requires
	 ;; that this be a STYLE-WARNING, not a full WARNING.)
	 (compiler-style-warning "reading an ignored variable: ~S" name))
       (reference-leaf start cont var))
      (cons
       (aver (eq (car var) 'MACRO))
       (ir1-convert start cont (cdr var)))
      (heap-alien-info
       (ir1-convert start cont `(%heap-alien ',var)))))
  (values))

;;; Convert anything that looks like a special form, global function
;;; or macro call.
(defun ir1-convert-global-functoid (start cont form)
  (declare (type continuation start cont) (list form))
  (let* ((fun (first form))
	 (translator (info :function :ir1-convert fun))
	 (cmacro (info :function :compiler-macro-function fun)))
    (cond (translator (funcall translator start cont form))
	  ((and cmacro
		(not (eq (info :function :inlinep fun)
			 :notinline)))
	   (let ((res (careful-expand-macro cmacro form)))
	     (if (eq res form)
		 (ir1-convert-global-functoid-no-cmacro start cont form fun)
		 (ir1-convert start cont res))))
	  (t
	   (ir1-convert-global-functoid-no-cmacro start cont form fun)))))

;;; Handle the case of where the call was not a compiler macro, or was a
;;; compiler macro and passed.
(defun ir1-convert-global-functoid-no-cmacro (start cont form fun)
  (declare (type continuation start cont) (list form))
  ;; FIXME: Couldn't all the INFO calls here be converted into
  ;; standard CL functions, like MACRO-FUNCTION or something?
  ;; And what happens with lexically-defined (MACROLET) macros
  ;; here, anyway?
  (ecase (info :function :kind fun)
    (:macro
     (ir1-convert start
		  cont
		  (careful-expand-macro (info :function :macro-function fun)
					form)))
    ((nil :function)
     (ir1-convert-srctran start cont (find-free-function fun "Eh?") form))))

(defun muffle-warning-or-die ()
  (muffle-warning)
  (error "internal error -- no MUFFLE-WARNING restart"))

;;; Expand FORM using the macro whose MACRO-FUNCTION is FUN, trapping
;;; errors which occur during the macroexpansion.
(defun careful-expand-macro (fun form)
  (handler-bind (;; When cross-compiling, we can get style warnings
		 ;; about e.g. undefined functions. An unhandled
		 ;; CL:STYLE-WARNING (as opposed to a
		 ;; SB!C::COMPILER-NOTE) would cause FAILURE-P to be
		 ;; set on the return from #'SB!XC:COMPILE-FILE, which
		 ;; would falsely indicate an error sufficiently
		 ;; serious that we should stop the build process. To
		 ;; avoid this, we translate CL:STYLE-WARNING
		 ;; conditions from the host Common Lisp into
		 ;; cross-compiler SB!C::COMPILER-NOTE calls. (It
		 ;; might be cleaner to just make Python use
		 ;; CL:STYLE-WARNING internally, so that the
		 ;; significance of any host Common Lisp
		 ;; CL:STYLE-WARNINGs is understood automatically. But
		 ;; for now I'm not motivated to do this. -- WHN
		 ;; 19990412)
		 (style-warning (lambda (c)
				  (compiler-note "(during macroexpansion)~%~A"
						 c)
				  (muffle-warning-or-die)))
		 ;; KLUDGE: CMU CL in its wisdom (version 2.4.6 for
		 ;; Debian Linux, anyway) raises a CL:WARNING
		 ;; condition (not a CL:STYLE-WARNING) for undefined
		 ;; symbols when converting interpreted functions,
		 ;; causing COMPILE-FILE to think the file has a real
		 ;; problem, causing COMPILE-FILE to return FAILURE-P
		 ;; set (not just WARNINGS-P set). Since undefined
		 ;; symbol warnings are often harmless forward
		 ;; references, and since it'd be inordinately painful
		 ;; to try to eliminate all such forward references,
		 ;; these warnings are basically unavoidable. Thus, we
		 ;; need to coerce the system to work through them,
		 ;; and this code does so, by crudely suppressing all
		 ;; warnings in cross-compilation macroexpansion. --
		 ;; WHN 19990412
		 #+cmu
		 (warning (lambda (c)
			    (compiler-note
			     "(during macroexpansion)~%~
			      ~A~%~
			      (KLUDGE: That was a non-STYLE WARNING.~%~
			      Ordinarily that would cause compilation to~%~
			      fail. However, since we're running under~%~
			      CMU CL, and since CMU CL emits non-STYLE~%~
			      warnings for safe, hard-to-fix things (e.g.~%~
			      references to not-yet-defined functions)~%~
			      we're going to have to ignore it and proceed~%~
			      anyway. Hopefully we're not ignoring anything~%~
			      horrible here..)~%"
			     c)
			    (muffle-warning-or-die)))
		 (error (lambda (c)
			  (compiler-error "(during macroexpansion)~%~A" c))))
    (funcall sb!xc:*macroexpand-hook*
	     fun
	     form
	     *lexenv*)))

;;;; conversion utilities

;;; Convert a bunch of forms, discarding all the values except the
;;; last. If there aren't any forms, then translate a NIL.
(declaim (ftype (function (continuation continuation list) (values))
		ir1-convert-progn-body))
(defun ir1-convert-progn-body (start cont body)
  (if (endp body)
      (reference-constant start cont nil)
      (let ((this-start start)
	    (forms body))
	(loop
	  (let ((form (car forms)))
	    (when (endp (cdr forms))
	      (ir1-convert this-start cont form)
	      (return))
	    (let ((this-cont (make-continuation)))
	      (ir1-convert this-start this-cont form)
	      (setq this-start this-cont  forms (cdr forms)))))))
  (values))

;;;; converting combinations

;;; Convert a function call where the function (Fun) is a Leaf. We
;;; return the Combination node so that we can poke at it if we want to.
(declaim (ftype (function (continuation continuation list leaf) combination)
		ir1-convert-combination))
(defun ir1-convert-combination (start cont form fun)
  (let ((fun-cont (make-continuation)))
    (reference-leaf start fun-cont fun)
    (ir1-convert-combination-args fun-cont cont (cdr form))))

;;; Convert the arguments to a call and make the Combination node. Fun-Cont
;;; is the continuation which yields the function to call. Form is the source
;;; for the call. Args is the list of arguments for the call, which defaults
;;; to the cdr of source. We return the Combination node.
(defun ir1-convert-combination-args (fun-cont cont args)
  (declare (type continuation fun-cont cont) (list args))
  (let ((node (make-combination fun-cont)))
    (setf (continuation-dest fun-cont) node)
    (assert-continuation-type fun-cont
			      (specifier-type '(or function symbol)))
    (collect ((arg-conts))
      (let ((this-start fun-cont))
	(dolist (arg args)
	  (let ((this-cont (make-continuation node)))
	    (ir1-convert this-start this-cont arg)
	    (setq this-start this-cont)
	    (arg-conts this-cont)))
	(prev-link node this-start)
	(use-continuation node cont)
	(setf (combination-args node) (arg-conts))))
    node))

;;; Convert a call to a global function. If not :NOTINLINE, then we do
;;; source transforms and try out any inline expansion. If there is no
;;; expansion, but is :INLINE, then give an efficiency note (unless a
;;; known function which will quite possibly be open-coded.) Next, we
;;; go to ok-combination conversion.
(defun ir1-convert-srctran (start cont var form)
  (declare (type continuation start cont) (type global-var var))
  (let ((inlinep (when (defined-function-p var)
		   (defined-function-inlinep var))))
    (if (eq inlinep :notinline)
	(ir1-convert-combination start cont form var)
	(let ((transform (info :function :source-transform (leaf-name var))))
	  (if transform
	      (multiple-value-bind (result pass) (funcall transform form)
		(if pass
		    (ir1-convert-maybe-predicate start cont form var)
		    (ir1-convert start cont result)))
	      (ir1-convert-maybe-predicate start cont form var))))))

;;; If the function has the PREDICATE attribute, and the CONT's DEST
;;; isn't an IF, then we convert (IF <form> T NIL), ensuring that a
;;; predicate always appears in a conditional context.
;;;
;;; If the function isn't a predicate, then we call
;;; IR1-CONVERT-COMBINATION-CHECKING-TYPE.
(defun ir1-convert-maybe-predicate (start cont form var)
  (declare (type continuation start cont) (list form) (type global-var var))
  (let ((info (info :function :info (leaf-name var))))
    (if (and info
	     (ir1-attributep (function-info-attributes info) predicate)
	     (not (if-p (continuation-dest cont))))
	(ir1-convert start cont `(if ,form t nil))
	(ir1-convert-combination-checking-type start cont form var))))

;;; Actually really convert a global function call that we are allowed
;;; to early-bind.
;;;
;;; If we know the function type of the function, then we check the
;;; call for syntactic legality with respect to the declared function
;;; type. If it is impossible to determine whether the call is correct
;;; due to non-constant keywords, then we give up, marking the call as
;;; :FULL to inhibit further error messages. We return true when the
;;; call is legal.
;;;
;;; If the call is legal, we also propagate type assertions from the
;;; function type to the arg and result continuations. We do this now
;;; so that IR1 optimize doesn't have to redundantly do the check
;;; later so that it can do the type propagation.
(defun ir1-convert-combination-checking-type (start cont form var)
  (declare (type continuation start cont) (list form) (type leaf var))
  (let* ((node (ir1-convert-combination start cont form var))
	 (fun-cont (basic-combination-fun node))
	 (type (leaf-type var)))
    (when (validate-call-type node type t)
      (setf (continuation-%derived-type fun-cont) type)
      (setf (continuation-reoptimize fun-cont) nil)
      (setf (continuation-%type-check fun-cont) nil)))

  (values))

;;; Convert a call to a local function. If the function has already
;;; been let converted, then throw FUN to LOCAL-CALL-LOSSAGE. This
;;; should only happen when we are converting inline expansions for
;;; local functions during optimization.
(defun ir1-convert-local-combination (start cont form fun)
  (if (functional-kind fun)
      (throw 'local-call-lossage fun)
      (ir1-convert-combination start cont form
			       (maybe-reanalyze-function fun))))

;;;; PROCESS-DECLS

;;; Given a list of Lambda-Var structures and a variable name, return
;;; the structure for that name, or NIL if it isn't found. We return
;;; the *last* variable with that name, since LET* bindings may be
;;; duplicated, and declarations always apply to the last.
(declaim (ftype (function (list symbol) (or lambda-var list))
		find-in-bindings))
(defun find-in-bindings (vars name)
  (let ((found nil))
    (dolist (var vars)
      (cond ((leaf-p var)
	     (when (eq (leaf-name var) name)
	       (setq found var))
	     (let ((info (lambda-var-arg-info var)))
	       (when info
		 (let ((supplied-p (arg-info-supplied-p info)))
		   (when (and supplied-p
			      (eq (leaf-name supplied-p) name))
		     (setq found supplied-p))))))
	    ((and (consp var) (eq (car var) name))
	     (setf found (cdr var)))))
    found))

;;; Called by Process-Decls to deal with a variable type declaration.
;;; If a lambda-var being bound, we intersect the type with the vars
;;; type, otherwise we add a type-restriction on the var. If a symbol
;;; macro, we just wrap a THE around the expansion.
(defun process-type-decl (decl res vars)
  (declare (list decl vars) (type lexenv res))
  (let ((type (specifier-type (first decl))))
    (collect ((restr nil cons)
	      (new-vars nil cons))
      (dolist (var-name (rest decl))
	(let* ((bound-var (find-in-bindings vars var-name))
	       (var (or bound-var
			(lexenv-find var-name variables)
			(find-free-variable var-name))))
	  (etypecase var
	    (leaf
	     (let* ((old-type (or (lexenv-find var type-restrictions)
				  (leaf-type var)))
		    (int (if (or (function-type-p type)
				 (function-type-p old-type))
			     type
			     (type-approx-intersection2 old-type type))))
	       (cond ((eq int *empty-type*)
		      (unless (policy *lexenv* (= inhibit-warnings 3))
			(compiler-warning
			 "The type declarations ~S and ~S for ~S conflict."
			 (type-specifier old-type) (type-specifier type)
			 var-name)))
		     (bound-var (setf (leaf-type bound-var) int))
		     (t
		      (restr (cons var int))))))
	    (cons
	     ;; FIXME: non-ANSI weirdness
	     (aver (eq (car var) 'MACRO))
	     (new-vars `(,var-name . (MACRO . (the ,(first decl)
						   ,(cdr var))))))
	    (heap-alien-info
	     (compiler-error
	      "~S is an alien variable, so its type can't be declared."
	      var-name)))))

      (if (or (restr) (new-vars))
	  (make-lexenv :default res
		       :type-restrictions (restr)
		       :variables (new-vars))
	  res))))

;;; This is somewhat similar to PROCESS-TYPE-DECL, but handles
;;; declarations for function variables. In addition to allowing
;;; declarations for functions being bound, we must also deal with
;;; declarations that constrain the type of lexically apparent
;;; functions.
(defun process-ftype-decl (spec res names fvars)
  (declare (list spec names fvars) (type lexenv res))
  (let ((type (specifier-type spec)))
    (collect ((res nil cons))
      (dolist (name names)
	(let ((found (find name fvars :key #'leaf-name :test #'equal)))
	  (cond
	   (found
	    (setf (leaf-type found) type)
	    (assert-definition-type found type
				    :warning-function #'compiler-note
				    :where "FTYPE declaration"))
	   (t
	    (res (cons (find-lexically-apparent-function
			name "in a function type declaration")
		       type))))))
      (if (res)
	  (make-lexenv :default res :type-restrictions (res))
	  res))))

;;; Process a special declaration, returning a new LEXENV. A non-bound
;;; special declaration is instantiated by throwing a special variable
;;; into the variables.
(defun process-special-decl (spec res vars)
  (declare (list spec vars) (type lexenv res))
  (collect ((new-venv nil cons))
    (dolist (name (cdr spec))
      (let ((var (find-in-bindings vars name)))
	(etypecase var
	  (cons
	   (aver (eq (car var) 'MACRO))
	   (compiler-error
	    "~S is a symbol-macro and thus can't be declared special."
	    name))
	  (lambda-var
	   (when (lambda-var-ignorep var)
	     ;; ANSI's definition for "Declaration IGNORE, IGNORABLE"
	     ;; requires that this be a STYLE-WARNING, not a full WARNING.
	     (compiler-style-warning
	      "The ignored variable ~S is being declared special."
	      name))
	   (setf (lambda-var-specvar var)
		 (specvar-for-binding name)))
	  (null
	   (unless (assoc name (new-venv) :test #'eq)
	     (new-venv (cons name (specvar-for-binding name))))))))
    (if (new-venv)
	(make-lexenv :default res :variables (new-venv))
	res)))

;;; Return a DEFINED-FUNCTION which copies a global-var but for its inlinep.
(defun make-new-inlinep (var inlinep)
  (declare (type global-var var) (type inlinep inlinep))
  (let ((res (make-defined-function
	      :name (leaf-name var)
	      :where-from (leaf-where-from var)
	      :type (leaf-type var)
	      :inlinep inlinep)))
    (when (defined-function-p var)
      (setf (defined-function-inline-expansion res)
	    (defined-function-inline-expansion var))
      (setf (defined-function-functional res)
	    (defined-function-functional var)))
    res))

;;; Parse an inline/notinline declaration. If it's a local function we're
;;; defining, set its INLINEP. If a global function, add a new FENV entry.
(defun process-inline-decl (spec res fvars)
  (let ((sense (cdr (assoc (first spec) *inlinep-translations* :test #'eq)))
	(new-fenv ()))
    (dolist (name (rest spec))
      (let ((fvar (find name fvars :key #'leaf-name :test #'equal)))
	(if fvar
	    (setf (functional-inlinep fvar) sense)
	    (let ((found
		   (find-lexically-apparent-function
		    name "in an inline or notinline declaration")))
	      (etypecase found
		(functional
		 (when (policy *lexenv* (>= speed inhibit-warnings))
		   (compiler-note "ignoring ~A declaration not at ~
				   definition of local function:~%  ~S"
				  sense name)))
		(global-var
		 (push (cons name (make-new-inlinep found sense))
		       new-fenv)))))))

    (if new-fenv
	(make-lexenv :default res :functions new-fenv)
	res)))

;;; Like FIND-IN-BINDINGS, but looks for #'foo in the fvars.
(defun find-in-bindings-or-fbindings (name vars fvars)
  (declare (list vars fvars))
  (if (consp name)
      (destructuring-bind (wot fn-name) name
	(unless (eq wot 'function)
	  (compiler-error "The function or variable name ~S is unrecognizable."
			  name))
	(find fn-name fvars :key #'leaf-name :test #'equal))
      (find-in-bindings vars name)))

;;; Process an ignore/ignorable declaration, checking for various losing
;;; conditions.
(defun process-ignore-decl (spec vars fvars)
  (declare (list spec vars fvars))
  (dolist (name (rest spec))
    (let ((var (find-in-bindings-or-fbindings name vars fvars)))
      (cond
       ((not var)
	;; ANSI's definition for "Declaration IGNORE, IGNORABLE"
	;; requires that this be a STYLE-WARNING, not a full WARNING.
	(compiler-style-warning "declaring unknown variable ~S to be ignored"
				name))
       ;; FIXME: This special case looks like non-ANSI weirdness.
       ((and (consp var) (consp (cdr var)) (eq (cadr var) 'macro))
	;; Just ignore the IGNORE decl.
	)
       ((functional-p var)
	(setf (leaf-ever-used var) t))
       ((lambda-var-specvar var)
	;; ANSI's definition for "Declaration IGNORE, IGNORABLE"
	;; requires that this be a STYLE-WARNING, not a full WARNING.
	(compiler-style-warning "declaring special variable ~S to be ignored"
				name))
       ((eq (first spec) 'ignorable)
	(setf (leaf-ever-used var) t))
       (t
	(setf (lambda-var-ignorep var) t)))))
  (values))

;;; FIXME: This is non-ANSI, so the default should be T, or it should
;;; go away, I think.
(defvar *suppress-values-declaration* nil
  #!+sb-doc
  "If true, processing of the VALUES declaration is inhibited.")

;;; Process a single declaration spec, augmenting the specified LEXENV
;;; RES and returning it as a result. VARS and FVARS are as described in
;;; PROCESS-DECLS.
(defun process-1-decl (raw-spec res vars fvars cont)
  (declare (type list raw-spec vars fvars))
  (declare (type lexenv res))
  (declare (type continuation cont))
  (let ((spec (canonized-decl-spec raw-spec)))
    (case (first spec)
      (special (process-special-decl spec res vars))
      (ftype
       (unless (cdr spec)
	 (compiler-error "No type specified in FTYPE declaration: ~S" spec))
       (process-ftype-decl (second spec) res (cddr spec) fvars))
      ((inline notinline maybe-inline)
       (process-inline-decl spec res fvars))
      ((ignore ignorable)
       (process-ignore-decl spec vars fvars)
       res)
      (optimize
       (make-lexenv
	:default res
	:policy (process-optimize-decl spec (lexenv-policy res))))
      (type
       (process-type-decl (cdr spec) res vars))
      (values
       (if *suppress-values-declaration*
	   res
	   (let ((types (cdr spec)))
	     (do-the-stuff (if (eql (length types) 1)
			       (car types)
			       `(values ,@types))
			   cont res 'values))))
      (dynamic-extent
       (when (policy *lexenv* (> speed inhibit-warnings))
	 (compiler-note
	  "compiler limitation:~
           ~%  There's no special support for DYNAMIC-EXTENT (so it's ignored)."))
       res)
      (t
       (unless (info :declaration :recognized (first spec))
	 (compiler-warning "unrecognized declaration ~S" raw-spec))
       res))))

;;; Use a list of DECLARE forms to annotate the lists of LAMBDA-VAR
;;; and FUNCTIONAL structures which are being bound. In addition to
;;; filling in slots in the leaf structures, we return a new LEXENV
;;; which reflects pervasive special and function type declarations,
;;; (NOT)INLINE declarations and OPTIMIZE declarations. CONT is the
;;; continuation affected by VALUES declarations.
;;;
;;; This is also called in main.lisp when PROCESS-FORM handles a use
;;; of LOCALLY.
(defun process-decls (decls vars fvars cont &optional (env *lexenv*))
  (declare (list decls vars fvars) (type continuation cont))
  (dolist (decl decls)
    (dolist (spec (rest decl))
      (unless (consp spec)
	(compiler-error "malformed declaration specifier ~S in ~S"
			spec
			decl))
      (setq env (process-1-decl spec env vars fvars cont))))
  env)

;;; Return the SPECVAR for NAME to use when we see a local SPECIAL
;;; declaration. If there is a global variable of that name, then
;;; check that it isn't a constant and return it. Otherwise, create an
;;; anonymous GLOBAL-VAR.
(defun specvar-for-binding (name)
  (cond ((not (eq (info :variable :where-from name) :assumed))
	 (let ((found (find-free-variable name)))
	   (when (heap-alien-info-p found)
	     (compiler-error
	      "~S is an alien variable and so can't be declared special."
	      name))
	   (when (or (not (global-var-p found))
		     (eq (global-var-kind found) :constant))
	     (compiler-error
	      "~S is a constant and so can't be declared special."
	      name))
	   found))
	(t
	 (make-global-var :kind :special
			  :name name
			  :where-from :declared))))

;;;; LAMBDA hackery

;;;; Note: Take a look at the compiler-overview.tex section on "Hairy
;;;; function representation" before you seriously mess with this
;;;; stuff.

;;; Verify that a thing is a legal name for a variable and return a
;;; Var structure for it, filling in info if it is globally special.
;;; If it is losing, we punt with a Compiler-Error. Names-So-Far is an
;;; alist of names which have previously been bound. If the name is in
;;; this list, then we error out.
(declaim (ftype (function (t list) lambda-var) varify-lambda-arg))
(defun varify-lambda-arg (name names-so-far)
  (declare (inline member))
  (unless (symbolp name)
    (compiler-error "The lambda-variable ~S is not a symbol." name))
  (when (member name names-so-far :test #'eq)
    (compiler-error "The variable ~S occurs more than once in the lambda-list."
		    name))
  (let ((kind (info :variable :kind name)))
    (when (or (keywordp name) (eq kind :constant))
      (compiler-error "The name of the lambda-variable ~S is a constant."
		      name))
    (cond ((eq kind :special)
	   (let ((specvar (find-free-variable name)))
	     (make-lambda-var :name name
			      :type (leaf-type specvar)
			      :where-from (leaf-where-from specvar)
			      :specvar specvar)))
	  (t
	   (note-lexical-binding name)
	   (make-lambda-var :name name)))))

;;; Make the default keyword for a &KEY arg, checking that the keyword
;;; isn't already used by one of the VARS. We also check that the
;;; keyword isn't the magical :ALLOW-OTHER-KEYS.
(declaim (ftype (function (symbol list t) keyword) make-keyword-for-arg))
(defun make-keyword-for-arg (symbol vars keywordify)
  (let ((key (if (and keywordify (not (keywordp symbol)))
		 (keywordicate symbol)
		 symbol)))
    (when (eq key :allow-other-keys)
      (compiler-error "No &KEY arg can be called :ALLOW-OTHER-KEYS."))
    (dolist (var vars)
      (let ((info (lambda-var-arg-info var)))
	(when (and info
		   (eq (arg-info-kind info) :keyword)
		   (eq (arg-info-key info) key))
	  (compiler-error
	   "The keyword ~S appears more than once in the lambda-list."
	   key))))
    key))

;;; Parse a lambda-list into a list of VAR structures, stripping off
;;; any aux bindings. Each arg name is checked for legality, and
;;; duplicate names are checked for. If an arg is globally special,
;;; the var is marked as :SPECIAL instead of :LEXICAL. &KEY,
;;; &OPTIONAL and &REST args are annotated with an ARG-INFO structure
;;; which contains the extra information. If we hit something losing,
;;; we bug out with COMPILER-ERROR. These values are returned:
;;;  1. a list of the var structures for each top-level argument;
;;;  2. a flag indicating whether &KEY was specified;
;;;  3. a flag indicating whether other &KEY args are allowed;
;;;  4. a list of the &AUX variables; and
;;;  5. a list of the &AUX values.
(declaim (ftype (function (list) (values list boolean boolean list list))
		find-lambda-vars))
(defun find-lambda-vars (list)
  (multiple-value-bind (required optional restp rest keyp keys allowp aux
			morep more-context more-count)
      (parse-lambda-list list)
    (collect ((vars)
	      (names-so-far)
	      (aux-vars)
	      (aux-vals))
      (flet (;; PARSE-DEFAULT deals with defaults and supplied-p args
	     ;; for optionals and keywords args.
	     (parse-default (spec info)
	       (when (consp (cdr spec))
		 (setf (arg-info-default info) (second spec))
		 (when (consp (cddr spec))
		   (let* ((supplied-p (third spec))
			  (supplied-var (varify-lambda-arg supplied-p
							   (names-so-far))))
		     (setf (arg-info-supplied-p info) supplied-var)
		     (names-so-far supplied-p)
		     (when (> (length (the list spec)) 3)
		       (compiler-error
			"The list ~S is too long to be an arg specifier."
			spec)))))))
	
	(dolist (name required)
	  (let ((var (varify-lambda-arg name (names-so-far))))
	    (vars var)
	    (names-so-far name)))
	
	(dolist (spec optional)
	  (if (atom spec)
	      (let ((var (varify-lambda-arg spec (names-so-far))))
		(setf (lambda-var-arg-info var) (make-arg-info :kind :optional))
		(vars var)
		(names-so-far spec))
	      (let* ((name (first spec))
		     (var (varify-lambda-arg name (names-so-far)))
		     (info (make-arg-info :kind :optional)))
		(setf (lambda-var-arg-info var) info)
		(vars var)
		(names-so-far name)
		(parse-default spec info))))
	
	(when restp
	  (let ((var (varify-lambda-arg rest (names-so-far))))
	    (setf (lambda-var-arg-info var) (make-arg-info :kind :rest))
	    (vars var)
	    (names-so-far rest)))

	(when morep
	  (let ((var (varify-lambda-arg more-context (names-so-far))))
	    (setf (lambda-var-arg-info var)
		  (make-arg-info :kind :more-context))
	    (vars var)
	    (names-so-far more-context))
	  (let ((var (varify-lambda-arg more-count (names-so-far))))
	    (setf (lambda-var-arg-info var)
		  (make-arg-info :kind :more-count))
	    (vars var)
	    (names-so-far more-count)))
	
	(dolist (spec keys)
	  (cond
	   ((atom spec)
	    (let ((var (varify-lambda-arg spec (names-so-far))))
	      (setf (lambda-var-arg-info var)
		    (make-arg-info :kind :keyword
				   :key (make-keyword-for-arg spec
							      (vars)
							      t)))
	      (vars var)
	      (names-so-far spec)))
	   ((atom (first spec))
	    (let* ((name (first spec))
		   (var (varify-lambda-arg name (names-so-far)))
		   (info (make-arg-info
			  :kind :keyword
			  :key (make-keyword-for-arg name (vars) t))))
	      (setf (lambda-var-arg-info var) info)
	      (vars var)
	      (names-so-far name)
	      (parse-default spec info)))
	   (t
	    (let ((head (first spec)))
	      (unless (proper-list-of-length-p head 2)
		(error "malformed &KEY argument specifier: ~S" spec))
	      (let* ((name (second head))
		     (var (varify-lambda-arg name (names-so-far)))
		     (info (make-arg-info
			    :kind :keyword
			    :key (make-keyword-for-arg (first head)
						       (vars)
						       nil))))
		(setf (lambda-var-arg-info var) info)
		(vars var)
		(names-so-far name)
		(parse-default spec info))))))
	
	(dolist (spec aux)
	  (cond ((atom spec)
		 (let ((var (varify-lambda-arg spec nil)))
		   (aux-vars var)
		   (aux-vals nil)
		   (names-so-far spec)))
		(t
		 (unless (proper-list-of-length-p spec 1 2)
		   (compiler-error "malformed &AUX binding specifier: ~S"
				   spec))
		 (let* ((name (first spec))
			(var (varify-lambda-arg name nil)))
		   (aux-vars var)
		   (aux-vals (second spec))
		   (names-so-far name)))))

	(values (vars) keyp allowp (aux-vars) (aux-vals))))))

;;; This is similar to IR1-CONVERT-PROGN-BODY except that we
;;; sequentially bind each AUX-VAR to the corresponding AUX-VAL before
;;; converting the body. If there are no bindings, just convert the
;;; body, otherwise do one binding and recurse on the rest.
(defun ir1-convert-aux-bindings (start cont body aux-vars aux-vals)
  (declare (type continuation start cont) (list body aux-vars aux-vals))
  (if (null aux-vars)
      (ir1-convert-progn-body start cont body)
      (let ((fun-cont (make-continuation))
	    (fun (ir1-convert-lambda-body body
					  (list (first aux-vars))
					  :aux-vars (rest aux-vars)
					  :aux-vals (rest aux-vals))))
	(reference-leaf start fun-cont fun)
	(ir1-convert-combination-args fun-cont cont
				      (list (first aux-vals)))))
  (values))

;;; This is similar to IR1-CONVERT-PROGN-BODY except that code to bind
;;; the SPECVAR for each SVAR to the value of the variable is wrapped
;;; around the body. If there are no special bindings, we just convert
;;; the body, otherwise we do one special binding and recurse on the
;;; rest.
;;;
;;; We make a cleanup and introduce it into the lexical environment.
;;; If there are multiple special bindings, the cleanup for the blocks
;;; will end up being the innermost one. We force CONT to start a
;;; block outside of this cleanup, causing cleanup code to be emitted
;;; when the scope is exited.
(defun ir1-convert-special-bindings (start cont body aux-vars aux-vals svars)
  (declare (type continuation start cont)
	   (list body aux-vars aux-vals svars))
  (cond
   ((null svars)
    (ir1-convert-aux-bindings start cont body aux-vars aux-vals))
   (t
    (continuation-starts-block cont)
    (let ((cleanup (make-cleanup :kind :special-bind))
	  (var (first svars))
	  (next-cont (make-continuation))
	  (nnext-cont (make-continuation)))
      (ir1-convert start next-cont
		   `(%special-bind ',(lambda-var-specvar var) ,var))
      (setf (cleanup-mess-up cleanup) (continuation-use next-cont))
      (let ((*lexenv* (make-lexenv :cleanup cleanup)))
	(ir1-convert next-cont nnext-cont '(%cleanup-point))
	(ir1-convert-special-bindings nnext-cont cont body aux-vars aux-vals
				      (rest svars))))))
  (values))

;;; Create a lambda node out of some code, returning the result. The
;;; bindings are specified by the list of VAR structures VARS. We deal
;;; with adding the names to the LEXENV-VARIABLES for the conversion.
;;; The result is added to the NEW-FUNCTIONS in the
;;; *CURRENT-COMPONENT* and linked to the component head and tail.
;;;
;;; We detect special bindings here, replacing the original VAR in the
;;; lambda list with a temporary variable. We then pass a list of the
;;; special vars to IR1-CONVERT-SPECIAL-BINDINGS, which actually emits
;;; the special binding code.
;;;
;;; We ignore any ARG-INFO in the VARS, trusting that someone else is
;;; dealing with &nonsense.
;;;
;;; AUX-VARS is a list of VAR structures for variables that are to be
;;; sequentially bound. Each AUX-VAL is a form that is to be evaluated
;;; to get the initial value for the corresponding AUX-VAR. 
(defun ir1-convert-lambda-body (body vars &key aux-vars aux-vals result)
  (declare (list body vars aux-vars aux-vals)
	   (type (or continuation null) result))
  (let* ((bind (make-bind))
	 (lambda (make-lambda :vars vars :bind bind))
	 (result (or result (make-continuation))))
    (setf (lambda-home lambda) lambda)
    (collect ((svars)
	      (new-venv nil cons))

      (dolist (var vars)
	;; As far as I can see, LAMBDA-VAR-HOME should never have
	;; been set before. Let's make sure. -- WHN 2001-09-29
	(aver (null (lambda-var-home var)))
	(setf (lambda-var-home var) lambda)
	(let ((specvar (lambda-var-specvar var)))
	  (cond (specvar
		 (svars var)
		 (new-venv (cons (leaf-name specvar) specvar)))
		(t
		 (note-lexical-binding (leaf-name var))
		 (new-venv (cons (leaf-name var) var))))))

      (let ((*lexenv* (make-lexenv :variables (new-venv)
				   :lambda lambda
				   :cleanup nil)))
	(setf (bind-lambda bind) lambda)
	(setf (node-lexenv bind) *lexenv*)
	
	(let ((cont1 (make-continuation))
	      (cont2 (make-continuation)))
	  (continuation-starts-block cont1)
	  (prev-link bind cont1)
	  (use-continuation bind cont2)
	  (ir1-convert-special-bindings cont2 result body aux-vars aux-vals
					(svars)))

	(let ((block (continuation-block result)))
	  (when block
	    (let ((return (make-return :result result :lambda lambda))
		  (tail-set (make-tail-set :functions (list lambda)))
		  (dummy (make-continuation)))
	      (setf (lambda-tail-set lambda) tail-set)
	      (setf (lambda-return lambda) return)
	      (setf (continuation-dest result) return)
	      (setf (block-last block) return)
	      (prev-link return result)
	      (use-continuation return dummy))
	    (link-blocks block (component-tail *current-component*))))))

    (link-blocks (component-head *current-component*) (node-block bind))
    (push lambda (component-new-functions *current-component*))
    lambda))

;;; Create the actual entry-point function for an optional entry
;;; point. The lambda binds copies of each of the VARS, then calls FUN
;;; with the argument VALS and the DEFAULTS. Presumably the VALS refer
;;; to the VARS by name. The VALS are passed in in reverse order.
;;;
;;; If any of the copies of the vars are referenced more than once,
;;; then we mark the corresponding var as EVER-USED to inhibit
;;; "defined but not read" warnings for arguments that are only used
;;; by default forms.
(defun convert-optional-entry (fun vars vals defaults)
  (declare (type clambda fun) (list vars vals defaults))
  (let* ((fvars (reverse vars))
	 (arg-vars (mapcar (lambda (var)
			     (unless (lambda-var-specvar var)
			       (note-lexical-binding (leaf-name var)))
			     (make-lambda-var
			      :name (leaf-name var)
			      :type (leaf-type var)
			      :where-from (leaf-where-from var)
			      :specvar (lambda-var-specvar var)))
			   fvars))
	 (fun
	  (ir1-convert-lambda-body `((%funcall ,fun
					       ,@(reverse vals)
					       ,@defaults))
				   arg-vars)))
    (mapc (lambda (var arg-var)
	    (when (cdr (leaf-refs arg-var))
	      (setf (leaf-ever-used var) t)))
	  fvars arg-vars)
    fun))

;;; This function deals with supplied-p vars in optional arguments. If
;;; the there is no supplied-p arg, then we just call
;;; IR1-CONVERT-HAIRY-ARGS on the remaining arguments, and generate a
;;; optional entry that calls the result. If there is a supplied-p
;;; var, then we add it into the default vars and throw a T into the
;;; entry values. The resulting entry point function is returned.
(defun generate-optional-default-entry (res default-vars default-vals
					    entry-vars entry-vals
					    vars supplied-p-p body
					    aux-vars aux-vals cont)
  (declare (type optional-dispatch res)
	   (list default-vars default-vals entry-vars entry-vals vars body
		 aux-vars aux-vals)
	   (type (or continuation null) cont))
  (let* ((arg (first vars))
	 (arg-name (leaf-name arg))
	 (info (lambda-var-arg-info arg))
	 (supplied-p (arg-info-supplied-p info))
	 (ep (if supplied-p
		 (ir1-convert-hairy-args
		  res
		  (list* supplied-p arg default-vars)
		  (list* (leaf-name supplied-p) arg-name default-vals)
		  (cons arg entry-vars)
		  (list* t arg-name entry-vals)
		  (rest vars) t body aux-vars aux-vals cont)
		 (ir1-convert-hairy-args
		  res
		  (cons arg default-vars)
		  (cons arg-name default-vals)
		  (cons arg entry-vars)
		  (cons arg-name entry-vals)
		  (rest vars) supplied-p-p body aux-vars aux-vals cont))))

    (convert-optional-entry ep default-vars default-vals
			    (if supplied-p
				(list (arg-info-default info) nil)
				(list (arg-info-default info))))))

;;; Create the MORE-ENTRY function for the OPTIONAL-DISPATCH RES.
;;; ENTRY-VARS and ENTRY-VALS describe the fixed arguments. REST is
;;; the var for any &REST arg. KEYS is a list of the &KEY arg vars.
;;;
;;; The most interesting thing that we do is parse keywords. We create
;;; a bunch of temporary variables to hold the result of the parse,
;;; and then loop over the supplied arguments, setting the appropriate
;;; temps for the supplied keyword. Note that it is significant that
;;; we iterate over the keywords in reverse order --- this implements
;;; the CL requirement that (when a keyword appears more than once)
;;; the first value is used.
;;;
;;; If there is no supplied-p var, then we initialize the temp to the
;;; default and just pass the temp into the main entry. Since
;;; non-constant &KEY args are forcibly given a supplied-p var, we
;;; know that the default is constant, and thus safe to evaluate out
;;; of order.
;;;
;;; If there is a supplied-p var, then we create temps for both the
;;; value and the supplied-p, and pass them into the main entry,
;;; letting it worry about defaulting.
;;;
;;; We deal with :ALLOW-OTHER-KEYS by delaying unknown keyword errors
;;; until we have scanned all the keywords.
(defun convert-more-entry (res entry-vars entry-vals rest morep keys)
  (declare (type optional-dispatch res) (list entry-vars entry-vals keys))
  (collect ((arg-vars)
	    (arg-vals (reverse entry-vals))
	    (temps)
	    (body))

    (dolist (var (reverse entry-vars))
      (arg-vars (make-lambda-var :name (leaf-name var)
				 :type (leaf-type var)
				 :where-from (leaf-where-from var))))

    (let* ((n-context (gensym "N-CONTEXT-"))
	   (context-temp (make-lambda-var :name n-context))
	   (n-count (gensym "N-COUNT-"))
	   (count-temp (make-lambda-var :name n-count
					:type (specifier-type 'index))))

      (arg-vars context-temp count-temp)

      (when rest
	(arg-vals `(%listify-rest-args ,n-context ,n-count)))
      (when morep
	(arg-vals n-context)
	(arg-vals n-count))

      (when (optional-dispatch-keyp res)
	(let ((n-index (gensym "N-INDEX-"))
	      (n-key (gensym "N-KEY-"))
	      (n-value-temp (gensym "N-VALUE-TEMP-"))
	      (n-allowp (gensym "N-ALLOWP-"))
	      (n-losep (gensym "N-LOSEP-"))
	      (allowp (or (optional-dispatch-allowp res)
			  (policy *lexenv* (zerop safety)))))

	  (temps `(,n-index (1- ,n-count)) n-key n-value-temp)
	  (body `(declare (fixnum ,n-index) (ignorable ,n-key ,n-value-temp)))

	  (collect ((tests))
	    (dolist (key keys)
	      (let* ((info (lambda-var-arg-info key))
		     (default (arg-info-default info))
		     (keyword (arg-info-key info))
		     (supplied-p (arg-info-supplied-p info))
		     (n-value (gensym "N-VALUE-")))
		(temps `(,n-value ,default))
		(cond (supplied-p
		       (let ((n-supplied (gensym "N-SUPPLIED-")))
			 (temps n-supplied)
			 (arg-vals n-value n-supplied)
			 (tests `((eq ,n-key ',keyword)
				  (setq ,n-supplied t)
				  (setq ,n-value ,n-value-temp)))))
		      (t
		       (arg-vals n-value)
		       (tests `((eq ,n-key ',keyword)
				(setq ,n-value ,n-value-temp)))))))

	    (unless allowp
	      (temps n-allowp n-losep)
	      (tests `((eq ,n-key :allow-other-keys)
		       (setq ,n-allowp ,n-value-temp)))
	      (tests `(t
		       (setq ,n-losep ,n-key))))

	    (body
	     `(when (oddp ,n-count)
		(%odd-key-arguments-error)))

	    (body
	     `(locally
		(declare (optimize (safety 0)))
		(loop
		  (when (minusp ,n-index) (return))
		  (setf ,n-value-temp (%more-arg ,n-context ,n-index))
		  (decf ,n-index)
		  (setq ,n-key (%more-arg ,n-context ,n-index))
		  (decf ,n-index)
		  (cond ,@(tests)))))

	    (unless allowp
	      (body `(when (and ,n-losep (not ,n-allowp))
		       (%unknown-key-argument-error ,n-losep)))))))

      (let ((ep (ir1-convert-lambda-body
		 `((let ,(temps)
		     ,@(body)
		     (%funcall ,(optional-dispatch-main-entry res)
			       . ,(arg-vals)))) ; FIXME: What is the '.'? ,@?
		 (arg-vars))))
	(setf (optional-dispatch-more-entry res) ep))))

  (values))

;;; This is called by IR1-CONVERT-HAIRY-ARGS when we run into a &REST
;;; or &KEY arg. The arguments are similar to that function, but we
;;; split off any &REST arg and pass it in separately. REST is the
;;; &REST arg var, or NIL if there is no &REST arg. KEYS is a list of
;;; the &KEY argument vars.
;;;
;;; When there are &KEY arguments, we introduce temporary gensym
;;; variables to hold the values while keyword defaulting is in
;;; progress to get the required sequential binding semantics.
;;;
;;; This gets interesting mainly when there are &KEY arguments with
;;; supplied-p vars or non-constant defaults. In either case, pass in
;;; a supplied-p var. If the default is non-constant, we introduce an
;;; IF in the main entry that tests the supplied-p var and decides
;;; whether to evaluate the default or not. In this case, the real
;;; incoming value is NIL, so we must union NULL with the declared
;;; type when computing the type for the main entry's argument.
(defun ir1-convert-more (res default-vars default-vals entry-vars entry-vals
			     rest more-context more-count keys supplied-p-p
			     body aux-vars aux-vals cont)
  (declare (type optional-dispatch res)
	   (list default-vars default-vals entry-vars entry-vals keys body
		 aux-vars aux-vals)
	   (type (or continuation null) cont))
  (collect ((main-vars (reverse default-vars))
	    (main-vals default-vals cons)
	    (bind-vars)
	    (bind-vals))
    (when rest
      (main-vars rest)
      (main-vals '()))
    (when more-context
      (main-vars more-context)
      (main-vals nil)
      (main-vars more-count)
      (main-vals 0))

    (dolist (key keys)
      (let* ((info (lambda-var-arg-info key))
	     (default (arg-info-default info))
	     (hairy-default (not (sb!xc:constantp default)))
	     (supplied-p (arg-info-supplied-p info))
	     (n-val (make-symbol (format nil
					 "~A-DEFAULTING-TEMP"
					 (leaf-name key))))
	     (key-type (leaf-type key))
	     (val-temp (make-lambda-var
			:name n-val
			:type (if hairy-default
				  (type-union key-type (specifier-type 'null))
				  key-type))))
	(main-vars val-temp)
	(bind-vars key)
	(cond ((or hairy-default supplied-p)
	       (let* ((n-supplied (gensym "N-SUPPLIED-"))
		      (supplied-temp (make-lambda-var :name n-supplied)))
		 (unless supplied-p
		   (setf (arg-info-supplied-p info) supplied-temp))
		 (when hairy-default
		   (setf (arg-info-default info) nil))
		 (main-vars supplied-temp)
		 (cond (hairy-default
			(main-vals nil nil)
			(bind-vals `(if ,n-supplied ,n-val ,default)))
		       (t
			(main-vals default nil)
			(bind-vals n-val)))
		 (when supplied-p
		   (bind-vars supplied-p)
		   (bind-vals n-supplied))))
	      (t
	       (main-vals (arg-info-default info))
	       (bind-vals n-val)))))

    (let* ((main-entry (ir1-convert-lambda-body
			body (main-vars)
			:aux-vars (append (bind-vars) aux-vars)
			:aux-vals (append (bind-vals) aux-vals)
			:result cont))
	   (last-entry (convert-optional-entry main-entry default-vars
					       (main-vals) ())))
      (setf (optional-dispatch-main-entry res) main-entry)
      (convert-more-entry res entry-vars entry-vals rest more-context keys)

      (push (if supplied-p-p
		(convert-optional-entry last-entry entry-vars entry-vals ())
		last-entry)
	    (optional-dispatch-entry-points res))
      last-entry)))

;;; This function generates the entry point functions for the
;;; OPTIONAL-DISPATCH RES. We accomplish this by recursion on the list
;;; of arguments, analyzing the arglist on the way down and generating
;;; entry points on the way up.
;;;
;;; DEFAULT-VARS is a reversed list of all the argument vars processed
;;; so far, including supplied-p vars. DEFAULT-VALS is a list of the
;;; names of the DEFAULT-VARS.
;;;
;;; ENTRY-VARS is a reversed list of processed argument vars,
;;; excluding supplied-p vars. ENTRY-VALS is a list things that can be
;;; evaluated to get the values for all the vars from the ENTRY-VARS.
;;; It has the var name for each required or optional arg, and has T
;;; for each supplied-p arg.
;;;
;;; VARS is a list of the LAMBDA-VAR structures for arguments that
;;; haven't been processed yet. SUPPLIED-P-P is true if a supplied-p
;;; argument has already been processed; only in this case are the
;;; DEFAULT-XXX and ENTRY-XXX different.
;;;
;;; The result at each point is a lambda which should be called by the
;;; above level to default the remaining arguments and evaluate the
;;; body. We cause the body to be evaluated by converting it and
;;; returning it as the result when the recursion bottoms out.
;;;
;;; Each level in the recursion also adds its entry point function to
;;; the result OPTIONAL-DISPATCH. For most arguments, the defaulting
;;; function and the entry point function will be the same, but when
;;; SUPPLIED-P args are present they may be different.
;;;
;;; When we run into a &REST or &KEY arg, we punt out to
;;; IR1-CONVERT-MORE, which finishes for us in this case.
(defun ir1-convert-hairy-args (res default-vars default-vals
				   entry-vars entry-vals
				   vars supplied-p-p body aux-vars
				   aux-vals cont)
  (declare (type optional-dispatch res)
	   (list default-vars default-vals entry-vars entry-vals vars body
		 aux-vars aux-vals)
	   (type (or continuation null) cont))
  (cond ((not vars)
	 (if (optional-dispatch-keyp res)
	     ;; Handle &KEY with no keys...
	     (ir1-convert-more res default-vars default-vals
			       entry-vars entry-vals
			       nil nil nil vars supplied-p-p body aux-vars
			       aux-vals cont)
	     (let ((fun (ir1-convert-lambda-body body (reverse default-vars)
						 :aux-vars aux-vars
						 :aux-vals aux-vals
						 :result cont)))
	       (setf (optional-dispatch-main-entry res) fun)
	       (push (if supplied-p-p
			 (convert-optional-entry fun entry-vars entry-vals ())
			 fun)
		     (optional-dispatch-entry-points res))
	       fun)))
	((not (lambda-var-arg-info (first vars)))
	 (let* ((arg (first vars))
		(nvars (cons arg default-vars))
		(nvals (cons (leaf-name arg) default-vals)))
	   (ir1-convert-hairy-args res nvars nvals nvars nvals
				   (rest vars) nil body aux-vars aux-vals
				   cont)))
	(t
	 (let* ((arg (first vars))
		(info (lambda-var-arg-info arg))
		(kind (arg-info-kind info)))
	   (ecase kind
	     (:optional
	      (let ((ep (generate-optional-default-entry
			 res default-vars default-vals
			 entry-vars entry-vals vars supplied-p-p body
			 aux-vars aux-vals cont)))
		(push (if supplied-p-p
			  (convert-optional-entry ep entry-vars entry-vals ())
			  ep)
		      (optional-dispatch-entry-points res))
		ep))
	     (:rest
	      (ir1-convert-more res default-vars default-vals
				entry-vars entry-vals
				arg nil nil (rest vars) supplied-p-p body
				aux-vars aux-vals cont))
	     (:more-context
	      (ir1-convert-more res default-vars default-vals
				entry-vars entry-vals
				nil arg (second vars) (cddr vars) supplied-p-p
				body aux-vars aux-vals cont))
	     (:keyword
	      (ir1-convert-more res default-vars default-vals
				entry-vars entry-vals
				nil nil nil vars supplied-p-p body aux-vars
				aux-vals cont)))))))

;;; This function deals with the case where we have to make an
;;; OPTIONAL-DISPATCH to represent a LAMBDA. We cons up the result and
;;; call IR1-CONVERT-HAIRY-ARGS to do the work. When it is done, we
;;; figure out the MIN-ARGS and MAX-ARGS.
(defun ir1-convert-hairy-lambda (body vars keyp allowp aux-vars aux-vals cont)
  (declare (list body vars aux-vars aux-vals) (type continuation cont))
  (let ((res (make-optional-dispatch :arglist vars
				     :allowp allowp
				     :keyp keyp))
	(min (or (position-if #'lambda-var-arg-info vars) (length vars))))
    (push res (component-new-functions *current-component*))
    (ir1-convert-hairy-args res () () () () vars nil body aux-vars aux-vals
			    cont)
    (setf (optional-dispatch-min-args res) min)
    (setf (optional-dispatch-max-args res)
	  (+ (1- (length (optional-dispatch-entry-points res))) min))

    (flet ((frob (ep)
	     (when ep
	       (setf (functional-kind ep) :optional)
	       (setf (leaf-ever-used ep) t)
	       (setf (lambda-optional-dispatch ep) res))))
      (dolist (ep (optional-dispatch-entry-points res)) (frob ep))
      (frob (optional-dispatch-more-entry res))
      (frob (optional-dispatch-main-entry res)))

    res))

;;; Convert a LAMBDA form into a LAMBDA leaf or an OPTIONAL-DISPATCH leaf.
(defun ir1-convert-lambda (form &optional name)
  (unless (consp form)
    (compiler-error "A ~S was found when expecting a lambda expression:~%  ~S"
		    (type-of form)
		    form))
  (unless (eq (car form) 'lambda)
    (compiler-error "~S was expected but ~S was found:~%  ~S"
		    'lambda
		    (car form)
		    form))
  (unless (and (consp (cdr form)) (listp (cadr form)))
    (compiler-error
     "The lambda expression has a missing or non-list lambda-list:~%  ~S"
     form))

  (multiple-value-bind (vars keyp allow-other-keys aux-vars aux-vals)
      (find-lambda-vars (cadr form))
    (multiple-value-bind (forms decls) (sb!sys:parse-body (cddr form))
      (let* ((cont (make-continuation))
	     (*lexenv* (process-decls decls
				      (append aux-vars vars)
				      nil cont))
	     (res (if (or (find-if #'lambda-var-arg-info vars) keyp)
		      (ir1-convert-hairy-lambda forms vars keyp
						allow-other-keys
						aux-vars aux-vals cont)
		      (ir1-convert-lambda-body forms vars
					       :aux-vars aux-vars
					       :aux-vals aux-vals
					       :result cont))))
	(setf (functional-inline-expansion res) form)
	(setf (functional-arg-documentation res) (cadr form))
	(setf (leaf-name res) name)
	res))))

;;; FIXME: This file is rather long, and contains two distinct sections,
;;; transform machinery above this point and transforms themselves below this
;;; point. Why not split it in two? (ir1translate.lisp and
;;; ir1translators.lisp?) Then consider byte-compiling the translators, too.

;;;; control special forms

(def-ir1-translator progn ((&rest forms) start cont)
  #!+sb-doc
  "Progn Form*
  Evaluates each Form in order, returning the values of the last form. With no
  forms, returns NIL."
  (ir1-convert-progn-body start cont forms))

(def-ir1-translator if ((test then &optional else) start cont)
  #!+sb-doc
  "If Predicate Then [Else]
  If Predicate evaluates to non-null, evaluate Then and returns its values,
  otherwise evaluate Else and return its values. Else defaults to NIL."
  (let* ((pred (make-continuation))
	 (then-cont (make-continuation))
	 (then-block (continuation-starts-block then-cont))
	 (else-cont (make-continuation))
	 (else-block (continuation-starts-block else-cont))
	 (dummy-cont (make-continuation))
	 (node (make-if :test pred
			:consequent then-block
			:alternative else-block)))
    (setf (continuation-dest pred) node)
    (ir1-convert start pred test)
    (prev-link node pred)
    (use-continuation node dummy-cont)

    (let ((start-block (continuation-block pred)))
      (setf (block-last start-block) node)
      (continuation-starts-block cont)

      (link-blocks start-block then-block)
      (link-blocks start-block else-block)

      (ir1-convert then-cont cont then)
      (ir1-convert else-cont cont else))))

;;;; BLOCK and TAGBODY

;;;; We make an Entry node to mark the start and a :Entry cleanup to
;;;; mark its extent. When doing GO or RETURN-FROM, we emit an Exit
;;;; node.

;;; Make a :ENTRY cleanup and emit an ENTRY node, then convert the
;;; body in the modified environment. We make CONT start a block now,
;;; since if it was done later, the block would be in the wrong
;;; environment.
(def-ir1-translator block ((name &rest forms) start cont)
  #!+sb-doc
  "Block Name Form*
  Evaluate the Forms as a PROGN. Within the lexical scope of the body,
  (RETURN-FROM Name Value-Form) can be used to exit the form, returning the
  result of Value-Form."
  (unless (symbolp name)
    (compiler-error "The block name ~S is not a symbol." name))
  (continuation-starts-block cont)
  (let* ((dummy (make-continuation))
	 (entry (make-entry))
	 (cleanup (make-cleanup :kind :block
				:mess-up entry)))
    (push entry (lambda-entries (lexenv-lambda *lexenv*)))
    (setf (entry-cleanup entry) cleanup)
    (prev-link entry start)
    (use-continuation entry dummy)
    
    (let* ((env-entry (list entry cont))
           (*lexenv* (make-lexenv :blocks (list (cons name env-entry))
				  :cleanup cleanup)))
      (push env-entry (continuation-lexenv-uses cont))
      (ir1-convert-progn-body dummy cont forms))))


;;; We make CONT start a block just so that it will have a block
;;; assigned. People assume that when they pass a continuation into
;;; IR1-CONVERT as CONT, it will have a block when it is done.
(def-ir1-translator return-from ((name &optional value)
				 start cont)
  #!+sb-doc
  "Return-From Block-Name Value-Form
  Evaluate the Value-Form, returning its values from the lexically enclosing
  BLOCK Block-Name. This is constrained to be used only within the dynamic
  extent of the BLOCK."
  (continuation-starts-block cont)
  (let* ((found (or (lexenv-find name blocks)
		    (compiler-error "return for unknown block: ~S" name)))
	 (value-cont (make-continuation))
	 (entry (first found))
	 (exit (make-exit :entry entry
			  :value value-cont)))
    (push exit (entry-exits entry))
    (setf (continuation-dest value-cont) exit)
    (ir1-convert start value-cont value)
    (prev-link exit value-cont)
    (use-continuation exit (second found))))

;;; Return a list of the segments of a TAGBODY. Each segment looks
;;; like (<tag> <form>* (go <next tag>)). That is, we break up the
;;; tagbody into segments of non-tag statements, and explicitly
;;; represent the drop-through with a GO. The first segment has a
;;; dummy NIL tag, since it represents code before the first tag. The
;;; last segment (which may also be the first segment) ends in NIL
;;; rather than a GO.
(defun parse-tagbody (body)
  (declare (list body))
  (collect ((segments))
    (let ((current (cons nil body)))
      (loop
	(let ((tag-pos (position-if (complement #'listp) current :start 1)))
	  (unless tag-pos
	    (segments `(,@current nil))
	    (return))
	  (let ((tag (elt current tag-pos)))
	    (when (assoc tag (segments))
	      (compiler-error
	       "The tag ~S appears more than once in the tagbody."
	       tag))
	    (unless (or (symbolp tag) (integerp tag))
	      (compiler-error "~S is not a legal tagbody statement." tag))
	    (segments `(,@(subseq current 0 tag-pos) (go ,tag))))
	  (setq current (nthcdr tag-pos current)))))
    (segments)))

;;; Set up the cleanup, emitting the entry node. Then make a block for
;;; each tag, building up the tag list for LEXENV-TAGS as we go.
;;; Finally, convert each segment with the precomputed Start and Cont
;;; values.
(def-ir1-translator tagbody ((&rest statements) start cont)
  #!+sb-doc
  "Tagbody {Tag | Statement}*
  Define tags for used with GO. The Statements are evaluated in order
  (skipping Tags) and NIL is returned. If a statement contains a GO to a
  defined Tag within the lexical scope of the form, then control is transferred
  to the next statement following that tag. A Tag must an integer or a
  symbol. A statement must be a list. Other objects are illegal within the
  body."
  (continuation-starts-block cont)
  (let* ((dummy (make-continuation))
	 (entry (make-entry))
	 (segments (parse-tagbody statements))
	 (cleanup (make-cleanup :kind :tagbody
				:mess-up entry)))
    (push entry (lambda-entries (lexenv-lambda *lexenv*)))
    (setf (entry-cleanup entry) cleanup)
    (prev-link entry start)
    (use-continuation entry dummy)

    (collect ((tags)
	      (starts)
	      (conts))
      (starts dummy)
      (dolist (segment (rest segments))
	(let* ((tag-cont (make-continuation))
               (tag (list (car segment) entry tag-cont)))          
	  (conts tag-cont)
	  (starts tag-cont)
	  (continuation-starts-block tag-cont)
          (tags tag)
          (push (cdr tag) (continuation-lexenv-uses tag-cont))))
      (conts cont)

      (let ((*lexenv* (make-lexenv :cleanup cleanup :tags (tags))))
	(mapc (lambda (segment start cont)
		(ir1-convert-progn-body start cont (rest segment)))
	      segments (starts) (conts))))))

;;; Emit an EXIT node without any value.
(def-ir1-translator go ((tag) start cont)
  #!+sb-doc
  "Go Tag
  Transfer control to the named Tag in the lexically enclosing TAGBODY. This
  is constrained to be used only within the dynamic extent of the TAGBODY."
  (continuation-starts-block cont)
  (let* ((found (or (lexenv-find tag tags :test #'eql)
		    (compiler-error "Go to nonexistent tag: ~S." tag)))
	 (entry (first found))
	 (exit (make-exit :entry entry)))
    (push exit (entry-exits entry))
    (prev-link exit start)
    (use-continuation exit (second found))))

;;;; translators for compiler-magic special forms

;;; This handles EVAL-WHEN in non-top-level forms. (EVAL-WHENs in
;;; top-level forms are picked off and handled by PROCESS-TOP-LEVEL-FORM,
;;; so that they're never seen at this level.)
;;;
;;; ANSI "3.2.3.1 Processing of Top Level Forms" says that processing
;;; of non-top-level EVAL-WHENs is very simple:
;;;   EVAL-WHEN forms cause compile-time evaluation only at top level.
;;;   Both :COMPILE-TOPLEVEL and :LOAD-TOPLEVEL situation specifications
;;;   are ignored for non-top-level forms. For non-top-level forms, an
;;;   eval-when specifying the :EXECUTE situation is treated as an
;;;   implicit PROGN including the forms in the body of the EVAL-WHEN
;;;   form; otherwise, the forms in the body are ignored. 
(def-ir1-translator eval-when ((situations &rest forms) start cont)
  #!+sb-doc
  "EVAL-WHEN (Situation*) Form*
  Evaluate the Forms in the specified Situations (any of :COMPILE-TOPLEVEL,
  :LOAD-TOPLEVEL, or :EXECUTE, or (deprecated) COMPILE, LOAD, or EVAL)."
  (multiple-value-bind (ct lt e) (parse-eval-when-situations situations)
    (declare (ignore ct lt))
    (ir1-convert-progn-body start cont (and e forms)))
  (values))

;;; common logic for MACROLET and SYMBOL-MACROLET
;;;
;;; Call DEFINITIONIZE-FUN on each element of DEFINITIONS to find its
;;; in-lexenv representation, stuff the results into *LEXENV*, and
;;; call FUN (with no arguments).
(defun %funcall-in-foomacrolet-lexenv (definitionize-fun
				       definitionize-keyword
				       definitions
				       fun)
  (declare (type function definitionize-fun fun))
  (declare (type (member :variables :functions) definitionize-keyword))
  (declare (type list definitions))
  (unless (= (length definitions)
             (length (remove-duplicates definitions :key #'first)))
    (compiler-style-warning "duplicate definitions in ~S" definitions))
  (let* ((processed-definitions (mapcar definitionize-fun definitions))
         (*lexenv* (make-lexenv definitionize-keyword processed-definitions)))
    (funcall fun)))

;;; Tweak *LEXENV* to include the DEFINITIONS from a MACROLET, then
;;; call FUN (with no arguments).
;;;
;;; This is split off from the IR1 convert method so that it can be
;;; shared by the special-case top-level MACROLET processing code.
(defun funcall-in-macrolet-lexenv (definitions fun)
  (%funcall-in-foomacrolet-lexenv
   (lambda (definition)
     (unless (list-of-length-at-least-p definition 2)
       (compiler-error
	"The list ~S is too short to be a legal local macro definition."
	definition))
     (destructuring-bind (name arglist &body body) definition
       (unless (symbolp name)
	 (compiler-error "The local macro name ~S is not a symbol." name))
       (let ((whole (gensym "WHOLE"))
	     (environment (gensym "ENVIRONMENT")))
	 (multiple-value-bind (body local-decls)
	     (parse-defmacro arglist whole body name 'macrolet
			     :environment environment)
	   `(,name macro .
		   ,(compile nil
			     `(lambda (,whole ,environment)
				,@local-decls
				(block ,name ,body))))))))
   :functions
   definitions
   fun))

(def-ir1-translator macrolet ((definitions &rest body) start cont)
  #!+sb-doc
  "MACROLET ({(Name Lambda-List Form*)}*) Body-Form*
  Evaluate the Body-Forms in an environment with the specified local macros
  defined. Name is the local macro name, Lambda-List is the DEFMACRO style
  destructuring lambda list, and the Forms evaluate to the expansion. The
  Forms are evaluated in the null environment."
  (funcall-in-macrolet-lexenv definitions
			      (lambda ()
				(ir1-translate-locally body start cont))))

(defun funcall-in-symbol-macrolet-lexenv (definitions fun)
  (%funcall-in-foomacrolet-lexenv
   (lambda (definition)
     (unless (proper-list-of-length-p definition 2)
       (compiler-error "malformed symbol/expansion pair: ~S" definition))
     (destructuring-bind (name expansion) definition
       (unless (symbolp name)
         (compiler-error
          "The local symbol macro name ~S is not a symbol."
          name))
       `(,name . (MACRO . ,expansion))))
   :variables
   definitions
   fun))
  
(def-ir1-translator symbol-macrolet ((macrobindings &body body) start cont)
  #!+sb-doc
  "SYMBOL-MACROLET ({(Name Expansion)}*) Decl* Form*
  Define the Names as symbol macros with the given Expansions. Within the
  body, references to a Name will effectively be replaced with the Expansion."
  (funcall-in-symbol-macrolet-lexenv
   macrobindings
   (lambda ()
     (ir1-translate-locally body start cont))))

;;; not really a special form, but..
(def-ir1-translator declare ((&rest stuff) start cont)
  (declare (ignore stuff))
  ;; We ignore START and CONT too, but we can't use DECLARE IGNORE to
  ;; tell the compiler about it here, because the DEF-IR1-TRANSLATOR
  ;; macro would put the DECLARE in the wrong place, so..
  start cont
  (compiler-error "misplaced declaration"))

;;;; %PRIMITIVE
;;;;
;;;; Uses of %PRIMITIVE are either expanded into Lisp code or turned
;;;; into a funny function.

;;; Carefully evaluate a list of forms, returning a list of the results.
(defun eval-info-args (args)
  (declare (list args))
  (handler-case (mapcar #'eval args)
    (error (condition)
      (compiler-error "Lisp error during evaluation of info args:~%~A"
		      condition))))

;;; If there is a primitive translator, then we expand the call.
;;; Otherwise, we convert to the %%PRIMITIVE funny function. The first
;;; argument is the template, the second is a list of the results of
;;; any codegen-info args, and the remaining arguments are the runtime
;;; arguments.
;;;
;;; We do a bunch of error checking now so that we don't bomb out with
;;; a fatal error during IR2 conversion.
;;;
;;; KLUDGE: It's confusing having multiple names floating around for
;;; nearly the same concept: PRIMITIVE, TEMPLATE, VOP. Now that CMU
;;; CL's *PRIMITIVE-TRANSLATORS* stuff is gone, we could call
;;; primitives VOPs, rename TEMPLATE to VOP-TEMPLATE, rename
;;; BACKEND-TEMPLATE-NAMES to BACKEND-VOPS, and rename %PRIMITIVE to
;;; VOP or %VOP.. -- WHN 2001-06-11
;;; FIXME: Look at doing this ^, it doesn't look too hard actually.
(def-ir1-translator %primitive ((name &rest args) start cont)
  (unless (symbolp name)
    (compiler-error "The primitive name ~S is not a symbol." name))

  (let* ((template (or (gethash name *backend-template-names*)
		       (compiler-error
			"The primitive name ~A is not defined."
			name)))
	 (required (length (template-arg-types template)))
	 (info (template-info-arg-count template))
	 (min (+ required info))
	 (nargs (length args)))
    (if (template-more-args-type template)
	(when (< nargs min)
	  (compiler-error "Primitive ~A was called with ~R argument~:P, ~
	    		   but wants at least ~R."
			  name
			  nargs
			  min))
	(unless (= nargs min)
	  (compiler-error "Primitive ~A was called with ~R argument~:P, ~
			   but wants exactly ~R."
			  name
			  nargs
			  min)))

    (when (eq (template-result-types template) :conditional)
      (compiler-error
       "%PRIMITIVE was used with a conditional template."))

    (when (template-more-results-type template)
      (compiler-error
       "%PRIMITIVE was used with an unknown values template."))

    (ir1-convert start
		 cont
		 `(%%primitive ',template
			       ',(eval-info-args
				  (subseq args required min))
			       ,@(subseq args 0 required)
			       ,@(subseq args min)))))

;;;; QUOTE and FUNCTION

(def-ir1-translator quote ((thing) start cont)
  #!+sb-doc
  "QUOTE Value
  Return Value without evaluating it."
  (reference-constant start cont thing))

(def-ir1-translator function ((thing) start cont)
  #!+sb-doc
  "FUNCTION Name
  Return the lexically apparent definition of the function Name. Name may also
  be a lambda."
  (if (consp thing)
      (case (car thing)
	((lambda)
	 (reference-leaf start cont (ir1-convert-lambda thing)))
	((setf)
	 (let ((var (find-lexically-apparent-function
		     thing "as the argument to FUNCTION")))
	   (reference-leaf start cont var)))
	((instance-lambda)
	 (let ((res (ir1-convert-lambda `(lambda ,@(cdr thing)))))
	   (setf (getf (functional-plist res) :fin-function) t)
	   (reference-leaf start cont res)))
	(t
	 (compiler-error "~S is not a legal function name." thing)))
      (let ((var (find-lexically-apparent-function
		  thing "as the argument to FUNCTION")))
	(reference-leaf start cont var))))

;;;; FUNCALL

;;; FUNCALL is implemented on %FUNCALL, which can only call functions
;;; (not symbols). %FUNCALL is used directly in some places where the
;;; call should always be open-coded even if FUNCALL is :NOTINLINE.
(deftransform funcall ((function &rest args) * * :when :both)
  (let ((arg-names (make-gensym-list (length args))))
    `(lambda (function ,@arg-names)
       (%funcall ,(if (csubtypep (continuation-type function)
				 (specifier-type 'function))
		      'function
		      '(%coerce-callable-to-function function))
		 ,@arg-names))))

(def-ir1-translator %funcall ((function &rest args) start cont)
  (let ((fun-cont (make-continuation)))
    (ir1-convert start fun-cont function)
    (assert-continuation-type fun-cont (specifier-type 'function))
    (ir1-convert-combination-args fun-cont cont args)))

;;; This source transform exists to reduce the amount of work for the
;;; compiler. If the called function is a FUNCTION form, then convert
;;; directly to %FUNCALL, instead of waiting around for type
;;; inference.
(def-source-transform funcall (function &rest args)
  (if (and (consp function) (eq (car function) 'function))
      `(%funcall ,function ,@args)
      (values nil t)))

(deftransform %coerce-callable-to-function ((thing) (function) *
					    :when :both
					    :important t)
  "optimize away possible call to FDEFINITION at runtime"
  'thing)

;;;; LET and LET*
;;;;
;;;; (LET and LET* can't be implemented as macros due to the fact that
;;;; any pervasive declarations also affect the evaluation of the
;;;; arguments.)

;;; Given a list of binding specifiers in the style of Let, return:
;;;  1. The list of var structures for the variables bound.
;;;  2. The initial value form for each variable.
;;;
;;; The variable names are checked for legality and globally special
;;; variables are marked as such. Context is the name of the form, for
;;; error reporting purposes.
(declaim (ftype (function (list symbol) (values list list list))
		extract-let-variables))
(defun extract-let-variables (bindings context)
  (collect ((vars)
	    (vals)
	    (names))
    (flet ((get-var (name)
	     (varify-lambda-arg name
				(if (eq context 'let*)
				    nil
				    (names)))))
      (dolist (spec bindings)
	(cond ((atom spec)
	       (let ((var (get-var spec)))
		 (vars var)
		 (names (cons spec var))
		 (vals nil)))
	      (t
	       (unless (proper-list-of-length-p spec 1 2)
		 (compiler-error "The ~S binding spec ~S is malformed."
				 context
				 spec))
	       (let* ((name (first spec))
		      (var (get-var name)))
		 (vars var)
		 (names name)
		 (vals (second spec)))))))

    (values (vars) (vals) (names))))

(def-ir1-translator let ((bindings &body body)
			 start cont)
  #!+sb-doc
  "LET ({(Var [Value]) | Var}*) Declaration* Form*
  During evaluation of the Forms, bind the Vars to the result of evaluating the
  Value forms. The variables are bound in parallel after all of the Values are
  evaluated."
  (multiple-value-bind (forms decls) (sb!sys:parse-body body nil)
    (multiple-value-bind (vars values) (extract-let-variables bindings 'let)
      (let* ((*lexenv* (process-decls decls vars nil cont))
	     (fun-cont (make-continuation))
	     (fun (ir1-convert-lambda-body forms vars)))
	(reference-leaf start fun-cont fun)
	(ir1-convert-combination-args fun-cont cont values)))))

(def-ir1-translator let* ((bindings &body body)
			  start cont)
  #!+sb-doc
  "LET* ({(Var [Value]) | Var}*) Declaration* Form*
  Similar to LET, but the variables are bound sequentially, allowing each Value
  form to reference any of the previous Vars."
  (multiple-value-bind (forms decls) (sb!sys:parse-body body nil)
    (multiple-value-bind (vars values) (extract-let-variables bindings 'let*)
      (let ((*lexenv* (process-decls decls vars nil cont)))
	(ir1-convert-aux-bindings start cont forms vars values)))))

;;; logic shared between IR1 translators for LOCALLY, MACROLET,
;;; and SYMBOL-MACROLET
;;;
;;; Note that all these things need to preserve top-level-formness,
;;; but we don't need to worry about that within an IR1 translator,
;;; since top-level-formness is picked off by PROCESS-TOP-LEVEL-FOO
;;; forms before we hit the IR1 transform level.
(defun ir1-translate-locally (body start cont)
  (declare (type list body) (type continuation start cont))
  (multiple-value-bind (forms decls) (sb!sys:parse-body body nil)
    (let ((*lexenv* (process-decls decls nil nil cont)))
      (ir1-convert-aux-bindings start cont forms nil nil))))

(def-ir1-translator locally ((&body body) start cont)
  #!+sb-doc
  "LOCALLY Declaration* Form*
  Sequentially evaluate the Forms in a lexical environment where the
  the Declarations have effect. If LOCALLY is a top-level form, then
  the Forms are also processed as top-level forms."
  (ir1-translate-locally body start cont))

;;;; FLET and LABELS

;;; Given a list of local function specifications in the style of
;;; FLET, return lists of the function names and of the lambdas which
;;; are their definitions.
;;;
;;; The function names are checked for legality. CONTEXT is the name
;;; of the form, for error reporting.
(declaim (ftype (function (list symbol) (values list list))
		extract-flet-variables))
(defun extract-flet-variables (definitions context)
  (collect ((names)
	    (defs))
    (dolist (def definitions)
      (when (or (atom def) (< (length def) 2))
	(compiler-error "The ~S definition spec ~S is malformed." context def))

      (let ((name (check-function-name (first def))))
	(names name)
	(multiple-value-bind (forms decls) (sb!sys:parse-body (cddr def))
	  (defs `(lambda ,(second def)
		   ,@decls
		   (block ,(function-name-block-name name)
		     . ,forms))))))
    (values (names) (defs))))

(def-ir1-translator flet ((definitions &body body)
			  start cont)
  #!+sb-doc
  "FLET ({(Name Lambda-List Declaration* Form*)}*) Declaration* Body-Form*
  Evaluate the Body-Forms with some local function definitions. The bindings
  do not enclose the definitions; any use of Name in the Forms will refer to
  the lexically apparent function definition in the enclosing environment."
  (multiple-value-bind (forms decls) (sb!sys:parse-body body nil)
    (multiple-value-bind (names defs)
	(extract-flet-variables definitions 'flet)
      (let* ((fvars (mapcar (lambda (n d)
  			      (ir1-convert-lambda d n))
			    names defs))
	     (*lexenv* (make-lexenv
			:default (process-decls decls nil fvars cont)
			:functions (pairlis names fvars))))
	(ir1-convert-progn-body start cont forms)))))

;;; For LABELS, we have to create dummy function vars and add them to
;;; the function namespace while converting the functions. We then
;;; modify all the references to these leaves so that they point to
;;; the real functional leaves. We also backpatch the FENV so that if
;;; the lexical environment is used for inline expansion we will get
;;; the right functions.
(def-ir1-translator labels ((definitions &body body) start cont)
  #!+sb-doc
  "LABELS ({(Name Lambda-List Declaration* Form*)}*) Declaration* Body-Form*
  Evaluate the Body-Forms with some local function definitions. The bindings
  enclose the new definitions, so the defined functions can call themselves or
  each other."
  (multiple-value-bind (forms decls) (sb!sys:parse-body body nil)
    (multiple-value-bind (names defs)
	(extract-flet-variables definitions 'labels)
      (let* ((new-fenv (loop for name in names
			     collect (cons name (make-functional :name name))))
	     (real-funs
	      (let ((*lexenv* (make-lexenv :functions new-fenv)))
		(mapcar (lambda (n d)
			  (ir1-convert-lambda d n))
			names defs))))

	(loop for real in real-funs and env in new-fenv do
	      (let ((dum (cdr env)))
		(substitute-leaf real dum)
		(setf (cdr env) real)))

	(let ((*lexenv* (make-lexenv
			 :default (process-decls decls nil real-funs cont)
			 :functions (pairlis names real-funs))))
	  (ir1-convert-progn-body start cont forms))))))

;;;; THE

;;; Do stuff to recognize a THE or VALUES declaration. CONT is the
;;; continuation that the assertion applies to, TYPE is the type
;;; specifier and Lexenv is the current lexical environment. NAME is
;;; the name of the declaration we are doing, for use in error
;;; messages.
;;;
;;; This is somewhat involved, since a type assertion may only be made
;;; on a continuation, not on a node. We can't just set the
;;; continuation asserted type and let it go at that, since there may
;;; be parallel THE's for the same continuation, i.e.:
;;;     (if ...
;;;	 (the foo ...)
;;;	 (the bar ...))
;;;
;;; In this case, our representation can do no better than the union
;;; of these assertions. And if there is a branch with no assertion,
;;; we have nothing at all. We really need to recognize scoping, since
;;; we need to be able to discern between parallel assertions (which
;;; we union) and nested ones (which we intersect).
;;;
;;; We represent the scoping by throwing our innermost (intersected)
;;; assertion on CONT into the TYPE-RESTRICTIONS. As we go down, we
;;; intersect our assertions together. If CONT has no uses yet, we
;;; have not yet bottomed out on the first COND branch; in this case
;;; we optimistically assume that this type will be the one we end up
;;; with, and set the ASSERTED-TYPE to it. We can never get better
;;; than the type that we have the first time we bottom out. Later
;;; THE's (or the absence thereof) can only weaken this result.
;;;
;;; We make this work by getting USE-CONTINUATION to do the unioning
;;; across COND branches. We can't do it here, since we don't know how
;;; many branches there are going to be.
(defun do-the-stuff (type cont lexenv name)
  (declare (type continuation cont) (type lexenv lexenv))
  (let* ((ctype (values-specifier-type type))
	 (old-type (or (lexenv-find cont type-restrictions)
		       *wild-type*))
	 (intersects (values-types-equal-or-intersect old-type ctype))
	 (int (values-type-intersection old-type ctype))
	 (new (if intersects int old-type)))
    (when (null (find-uses cont))
      (setf (continuation-asserted-type cont) new))
    (when (and (not intersects)
	       (not (policy *lexenv*
			    (= inhibit-warnings 3)))) ;FIXME: really OK to suppress?
      (compiler-warning
       "The type ~S in ~S declaration conflicts with an enclosing assertion:~%   ~S"
       (type-specifier ctype)
       name
       (type-specifier old-type)))
    (make-lexenv :type-restrictions `((,cont . ,new))
		 :default lexenv)))

;;; Assert that FORM evaluates to the specified type (which may be a
;;; VALUES type).
;;;
;;; FIXME: In a version of CMU CL that I used at Cadabra ca. 20000101,
;;; this didn't seem to expand into an assertion, at least for ALIEN
;;; values. Check that SBCL doesn't have this problem.
(def-ir1-translator the ((type value) start cont)
  (let ((*lexenv* (do-the-stuff type cont *lexenv* 'the)))
    (ir1-convert start cont value)))

;;; This is like the THE special form, except that it believes
;;; whatever you tell it. It will never generate a type check, but
;;; will cause a warning if the compiler can prove the assertion is
;;; wrong.
;;;
;;; Since the CONTINUATION-DERIVED-TYPE is computed as the union of
;;; its uses's types, setting it won't work. Instead we must intersect
;;; the type with the uses's DERIVED-TYPE.
(def-ir1-translator truly-the ((type value) start cont)
  #!+sb-doc
  (declare (inline member))
  (let ((type (values-specifier-type type))
	(old (find-uses cont)))
    (ir1-convert start cont value)
    (do-uses (use cont)
      (unless (member use old :test #'eq)
	(derive-node-type use type)))))

;;;; SETQ

;;; If there is a definition in LEXENV-VARIABLES, just set that,
;;; otherwise look at the global information. If the name is for a
;;; constant, then error out.
(def-ir1-translator setq ((&whole source &rest things) start cont)
  (let ((len (length things)))
    (when (oddp len)
      (compiler-error "odd number of args to SETQ: ~S" source))
    (if (= len 2)
	(let* ((name (first things))
	       (leaf (or (lexenv-find name variables)
			 (find-free-variable name))))
	  (etypecase leaf
	    (leaf
	     (when (or (constant-p leaf)
		       (and (global-var-p leaf)
			    (eq (global-var-kind leaf) :constant)))
	       (compiler-error "~S is a constant and thus can't be set." name))
	     (when (and (lambda-var-p leaf)
			(lambda-var-ignorep leaf))
	       ;; ANSI's definition of "Declaration IGNORE, IGNORABLE"
	       ;; requires that this be a STYLE-WARNING, not a full warning.
	       (compiler-style-warning
		"~S is being set even though it was declared to be ignored."
		name))
	     (set-variable start cont leaf (second things)))
	    (cons
	     (aver (eq (car leaf) 'MACRO))
	     (ir1-convert start cont `(setf ,(cdr leaf) ,(second things))))
	    (heap-alien-info
	     (ir1-convert start cont
			  `(%set-heap-alien ',leaf ,(second things))))))
	(collect ((sets))
	  (do ((thing things (cddr thing)))
	      ((endp thing)
	       (ir1-convert-progn-body start cont (sets)))
	    (sets `(setq ,(first thing) ,(second thing))))))))

;;; This is kind of like REFERENCE-LEAF, but we generate a SET node.
;;; This should only need to be called in SETQ.
(defun set-variable (start cont var value)
  (declare (type continuation start cont) (type basic-var var))
  (let ((dest (make-continuation)))
    (setf (continuation-asserted-type dest) (leaf-type var))
    (ir1-convert start dest value)
    (let ((res (make-set :var var :value dest)))
      (setf (continuation-dest dest) res)
      (setf (leaf-ever-used var) t)
      (push res (basic-var-sets var))
      (prev-link res dest)
      (use-continuation res cont))))

;;;; CATCH, THROW and UNWIND-PROTECT

;;; We turn THROW into a multiple-value-call of a magical function,
;;; since as as far as IR1 is concerned, it has no interesting
;;; properties other than receiving multiple-values.
(def-ir1-translator throw ((tag result) start cont)
  #!+sb-doc
  "Throw Tag Form
  Do a non-local exit, return the values of Form from the CATCH whose tag
  evaluates to the same thing as Tag."
  (ir1-convert start cont
	       `(multiple-value-call #'%throw ,tag ,result)))

;;; This is a special special form used to instantiate a cleanup as
;;; the current cleanup within the body. KIND is a the kind of cleanup
;;; to make, and MESS-UP is a form that does the mess-up action. We
;;; make the MESS-UP be the USE of the MESS-UP form's continuation,
;;; and introduce the cleanup into the lexical environment. We
;;; back-patch the ENTRY-CLEANUP for the current cleanup to be the new
;;; cleanup, since this inner cleanup is the interesting one.
(def-ir1-translator %within-cleanup ((kind mess-up &body body) start cont)
  (let ((dummy (make-continuation))
	(dummy2 (make-continuation)))
    (ir1-convert start dummy mess-up)
    (let* ((mess-node (continuation-use dummy))
	   (cleanup (make-cleanup :kind kind
				  :mess-up mess-node))
	   (old-cup (lexenv-cleanup *lexenv*))
	   (*lexenv* (make-lexenv :cleanup cleanup)))
      (setf (entry-cleanup (cleanup-mess-up old-cup)) cleanup)
      (ir1-convert dummy dummy2 '(%cleanup-point))
      (ir1-convert-progn-body dummy2 cont body))))

;;; This is a special special form that makes an "escape function"
;;; which returns unknown values from named block. We convert the
;;; function, set its kind to :ESCAPE, and then reference it. The
;;; :Escape kind indicates that this function's purpose is to
;;; represent a non-local control transfer, and that it might not
;;; actually have to be compiled.
;;;
;;; Note that environment analysis replaces references to escape
;;; functions with references to the corresponding NLX-INFO structure.
(def-ir1-translator %escape-function ((tag) start cont)
  (let ((fun (ir1-convert-lambda
	      `(lambda ()
		 (return-from ,tag (%unknown-values))))))
    (setf (functional-kind fun) :escape)
    (reference-leaf start cont fun)))

;;; Yet another special special form. This one looks up a local
;;; function and smashes it to a :CLEANUP function, as well as
;;; referencing it.
(def-ir1-translator %cleanup-function ((name) start cont)
  (let ((fun (lexenv-find name functions)))
    (aver (lambda-p fun))
    (setf (functional-kind fun) :cleanup)
    (reference-leaf start cont fun)))

;;; We represent the possibility of the control transfer by making an
;;; "escape function" that does a lexical exit, and instantiate the
;;; cleanup using %WITHIN-CLEANUP.
(def-ir1-translator catch ((tag &body body) start cont)
  #!+sb-doc
  "Catch Tag Form*
  Evaluates Tag and instantiates it as a catcher while the body forms are
  evaluated in an implicit PROGN. If a THROW is done to Tag within the dynamic
  scope of the body, then control will be transferred to the end of the body
  and the thrown values will be returned."
  (ir1-convert
   start cont
   (let ((exit-block (gensym "EXIT-BLOCK-")))
     `(block ,exit-block
	(%within-cleanup
	    :catch
	    (%catch (%escape-function ,exit-block) ,tag)
	  ,@body)))))

;;; UNWIND-PROTECT is similar to CATCH, but more hairy. We make the
;;; cleanup forms into a local function so that they can be referenced
;;; both in the case where we are unwound and in any local exits. We
;;; use %CLEANUP-FUNCTION on this to indicate that reference by
;;; %UNWIND-PROTECT ISN'T "real", and thus doesn't cause creation of
;;; an XEP.
(def-ir1-translator unwind-protect ((protected &body cleanup) start cont)
  #!+sb-doc
  "Unwind-Protect Protected Cleanup*
  Evaluate the form Protected, returning its values. The cleanup forms are
  evaluated whenever the dynamic scope of the Protected form is exited (either
  due to normal completion or a non-local exit such as THROW)."
  (ir1-convert
   start cont
   (let ((cleanup-fun (gensym "CLEANUP-FUN-"))
	 (drop-thru-tag (gensym "DROP-THRU-TAG-"))
	 (exit-tag (gensym "EXIT-TAG-"))
	 (next (gensym "NEXT"))
	 (start (gensym "START"))
	 (count (gensym "COUNT")))
     `(flet ((,cleanup-fun () ,@cleanup nil))
	;; FIXME: If we ever get DYNAMIC-EXTENT working, then
	;; ,CLEANUP-FUN should probably be declared DYNAMIC-EXTENT,
	;; and something can be done to make %ESCAPE-FUNCTION have
	;; dynamic extent too.
	(block ,drop-thru-tag
	  (multiple-value-bind (,next ,start ,count)
	      (block ,exit-tag
		(%within-cleanup
		    :unwind-protect
		    (%unwind-protect (%escape-function ,exit-tag)
				     (%cleanup-function ,cleanup-fun))
		  (return-from ,drop-thru-tag ,protected)))
	    (,cleanup-fun)
	    (%continue-unwind ,next ,start ,count)))))))

;;;; multiple-value stuff

;;; If there are arguments, MULTIPLE-VALUE-CALL turns into an
;;; MV-COMBINATION.
;;;
;;; If there are no arguments, then we convert to a normal
;;; combination, ensuring that a MV-COMBINATION always has at least
;;; one argument. This can be regarded as an optimization, but it is
;;; more important for simplifying compilation of MV-COMBINATIONS.
(def-ir1-translator multiple-value-call ((fun &rest args) start cont)
  #!+sb-doc
  "MULTIPLE-VALUE-CALL Function Values-Form*
  Call Function, passing all the values of each Values-Form as arguments,
  values from the first Values-Form making up the first argument, etc."
  (let* ((fun-cont (make-continuation))
	 (node (if args
		   (make-mv-combination fun-cont)
		   (make-combination fun-cont))))
    (ir1-convert start fun-cont
		 (if (and (consp fun) (eq (car fun) 'function))
		     fun
		     `(%coerce-callable-to-function ,fun)))
    (setf (continuation-dest fun-cont) node)
    (assert-continuation-type fun-cont
			      (specifier-type '(or function symbol)))
    (collect ((arg-conts))
      (let ((this-start fun-cont))
	(dolist (arg args)
	  (let ((this-cont (make-continuation node)))
	    (ir1-convert this-start this-cont arg)
	    (setq this-start this-cont)
	    (arg-conts this-cont)))
	(prev-link node this-start)
	(use-continuation node cont)
	(setf (basic-combination-args node) (arg-conts))))))

;;; MULTIPLE-VALUE-PROG1 is represented implicitly in IR1 by having a
;;; the result code use result continuation (CONT), but transfer
;;; control to the evaluation of the body. In other words, the result
;;; continuation isn't IMMEDIATELY-USED-P by the nodes that compute
;;; the result.
;;;
;;; In order to get the control flow right, we convert the result with
;;; a dummy result continuation, then convert all the uses of the
;;; dummy to be uses of CONT. If a use is an EXIT, then we also
;;; substitute CONT for the dummy in the corresponding ENTRY node so
;;; that they are consistent. Note that this doesn't amount to
;;; changing the exit target, since the control destination of an exit
;;; is determined by the block successor; we are just indicating the
;;; continuation that the result is delivered to.
;;;
;;; We then convert the body, using another dummy continuation in its
;;; own block as the result. After we are done converting the body, we
;;; move all predecessors of the dummy end block to CONT's block.
;;;
;;; Note that we both exploit and maintain the invariant that the CONT
;;; to an IR1 convert method either has no block or starts the block
;;; that control should transfer to after completion for the form.
;;; Nested MV-PROG1's work because during conversion of the result
;;; form, we use dummy continuation whose block is the true control
;;; destination.
(def-ir1-translator multiple-value-prog1 ((result &rest forms) start cont)
  #!+sb-doc
  "MULTIPLE-VALUE-PROG1 Values-Form Form*
  Evaluate Values-Form and then the Forms, but return all the values of
  Values-Form."
  (continuation-starts-block cont)
  (let* ((dummy-result (make-continuation))
	 (dummy-start (make-continuation))
	 (cont-block (continuation-block cont)))
    (continuation-starts-block dummy-start)
    (ir1-convert start dummy-start result)

    (substitute-continuation-uses cont dummy-start)

    (continuation-starts-block dummy-result)
    (ir1-convert-progn-body dummy-start dummy-result forms)
    (let ((end-block (continuation-block dummy-result)))
      (dolist (pred (block-pred end-block))
	(unlink-blocks pred end-block)
	(link-blocks pred cont-block))
      (aver (not (continuation-dest dummy-result)))
      (delete-continuation dummy-result)
      (remove-from-dfo end-block))))

;;;; interface to defining macros

;;;; FIXME:
;;;;   classic CMU CL comment:
;;;;     DEFMACRO and DEFUN expand into calls to %DEFxxx functions
;;;;     so that we get a chance to see what is going on. We define
;;;;     IR1 translators for these functions which look at the
;;;;     definition and then generate a call to the %%DEFxxx function.
;;;; Alas, this implementation doesn't do the right thing for
;;;; non-toplevel uses of these forms, so this should probably
;;;; be changed to use EVAL-WHEN instead.

;;; Return a new source path with any stuff intervening between the
;;; current path and the first form beginning with NAME stripped off.
;;; This is used to hide the guts of DEFmumble macros to prevent
;;; annoying error messages.
(defun revert-source-path (name)
  (do ((path *current-path* (cdr path)))
      ((null path) *current-path*)
    (let ((first (first path)))
      (when (or (eq first name)
		(eq first 'original-source-start))
	(return path)))))

;;; Warn about incompatible or illegal definitions and add the macro
;;; to the compiler environment.
;;;
;;; Someday we could check for macro arguments being incompatibly
;;; redefined. Doing this right will involve finding the old macro
;;; lambda-list and comparing it with the new one.
(def-ir1-translator %defmacro ((qname qdef lambda-list doc) start cont
			       :kind :function)
  (let (;; QNAME is typically a quoted name. I think the idea is to
	;; let %DEFMACRO work as an ordinary function when
	;; interpreting. Whatever the reason the quote is there, we
	;; don't want it any more. -- WHN 19990603
	(name (eval qname))
	;; QDEF should be a sharp-quoted definition. We don't want to
	;; make a function of it just yet, so we just drop the
	;; sharp-quote.
	(def (progn
	       (aver (eq 'function (first qdef)))
	       (aver (proper-list-of-length-p qdef 2))
	       (second qdef))))

    (/show "doing IR1 translator for %DEFMACRO" name)

    (unless (symbolp name)
      (compiler-error "The macro name ~S is not a symbol." name))

    (ecase (info :function :kind name)
      ((nil))
      (:function
       (remhash name *free-functions*)
       (undefine-function-name name)
       (compiler-warning
	"~S is being redefined as a macro when it was ~
         previously ~(~A~) to be a function."
	name
	(info :function :where-from name)))
      (:macro)
      (:special-form
       (compiler-error "The special form ~S can't be redefined as a macro."
		       name)))

    (setf (info :function :kind name) :macro
	  (info :function :where-from name) :defined
	  (info :function :macro-function name) (coerce def 'function))

    (let* ((*current-path* (revert-source-path 'defmacro))
	   (fun (ir1-convert-lambda def name)))
      (setf (leaf-name fun)
	    (concatenate 'string "DEFMACRO " (symbol-name name)))
      (setf (functional-arg-documentation fun) (eval lambda-list))

      (ir1-convert start cont `(%%defmacro ',name ,fun ,doc)))

    (when sb!xc:*compile-print*
      ;; FIXME: It would be nice to convert this, and the other places
      ;; which create compiler diagnostic output prefixed by
      ;; semicolons, to use some common utility which automatically
      ;; prefixes all its output with semicolons. (The addition of
      ;; semicolon prefixes was introduced ca. sbcl-0.6.8.10 as the
      ;; "MNA compiler message patch", and implemented by modifying a
      ;; bunch of output statements on a case-by-case basis, which
      ;; seems unnecessarily error-prone and unclear, scattering
      ;; implicit information about output style throughout the
      ;; system.) Starting by rewriting COMPILER-MUMBLE to add
      ;; semicolon prefixes would be a good start, and perhaps also:
      ;;   * Add semicolon prefixes for "FOO assembled" messages emitted 
      ;;     when e.g. src/assembly/x86/assem-rtns.lisp is processed.
      ;;   * At least some debugger output messages deserve semicolon
      ;;     prefixes too:
      ;;     ** restarts table
      ;;     ** "Within the debugger, you can type HELP for help."
      (compiler-mumble "~&; converted ~S~%" name))))

(def-ir1-translator %define-compiler-macro ((name def lambda-list doc)
					    start cont
					    :kind :function)
  (let ((name (eval name))
	(def (second def))) ; We don't want to make a function just yet...

    (when (eq (info :function :kind name) :special-form)
      (compiler-error "attempt to define a compiler-macro for special form ~S"
		      name))

    (setf (info :function :compiler-macro-function name)
	  (coerce def 'function))

    (let* ((*current-path* (revert-source-path 'define-compiler-macro))
	   (fun (ir1-convert-lambda def name)))
      (setf (leaf-name fun)
	    (let ((*print-case* :upcase))
	      (format nil "DEFINE-COMPILER-MACRO ~S" name)))
      (setf (functional-arg-documentation fun) (eval lambda-list))

      (ir1-convert start cont `(%%define-compiler-macro ',name ,fun ,doc)))

    (when sb!xc:*compile-print*
      (compiler-mumble "~&; converted ~S~%" name))))

;;;; defining global functions

;;; Convert FUN as a lambda in the null environment, but use the
;;; current compilation policy. Note that FUN may be a
;;; LAMBDA-WITH-LEXENV, so we may have to augment the environment to
;;; reflect the state at the definition site.
(defun ir1-convert-inline-lambda (fun &optional name)
  (destructuring-bind (decls macros symbol-macros &rest body)
		      (if (eq (car fun) 'lambda-with-lexenv)
			  (cdr fun)
			  `(() () () . ,(cdr fun)))
    (let ((*lexenv* (make-lexenv
		     :default (process-decls decls nil nil
					     (make-continuation)
					     (make-null-lexenv))
		     :variables (copy-list symbol-macros)
		     :functions
		     (mapcar (lambda (x)
			       `(,(car x) .
				 (macro . ,(coerce (cdr x) 'function))))
			     macros)
		     :policy (lexenv-policy *lexenv*))))
      (ir1-convert-lambda `(lambda ,@body) name))))

;;; Get a DEFINED-FUNCTION object for a function we are about to
;;; define. If the function has been forward referenced, then
;;; substitute for the previous references.
(defun get-defined-function (name)
  (let* ((name (proclaim-as-function-name name))
	 (found (find-free-function name "Eh?")))
    (note-name-defined name :function)
    (cond ((not (defined-function-p found))
	   (aver (not (info :function :inlinep name)))
	   (let* ((where-from (leaf-where-from found))
		  (res (make-defined-function
			:name name
			:where-from (if (eq where-from :declared)
					:declared :defined)
			:type (leaf-type found))))
	     (substitute-leaf res found)
	     (setf (gethash name *free-functions*) res)))
	  ;; If *FREE-FUNCTIONS* has a previously converted definition for this
	  ;; name, then blow it away and try again.
	  ((defined-function-functional found)
	   (remhash name *free-functions*)
	   (get-defined-function name))
	  (t found))))

;;; Check a new global function definition for consistency with
;;; previous declaration or definition, and assert argument/result
;;; types if appropriate. This assertion is suppressed by the
;;; EXPLICIT-CHECK attribute, which is specified on functions that
;;; check their argument types as a consequence of type dispatching.
;;; This avoids redundant checks such as NUMBERP on the args to +, etc.
(defun assert-new-definition (var fun)
  (let ((type (leaf-type var))
	(for-real (eq (leaf-where-from var) :declared))
	(info (info :function :info (leaf-name var))))
    (assert-definition-type
     fun type
     ;; KLUDGE: Common Lisp is such a dynamic language that in general
     ;; all we can do here in general is issue a STYLE-WARNING. It
     ;; would be nice to issue a full WARNING in the special case of
     ;; of type mismatches within a compilation unit (as in section
     ;; 3.2.2.3 of the spec) but at least as of sbcl-0.6.11, we don't
     ;; keep track of whether the mismatched data came from the same
     ;; compilation unit, so we can't do that. -- WHN 2001-02-11
     :error-function #'compiler-style-warning
     :warning-function (cond (info #'compiler-style-warning)
			     (for-real #'compiler-note)
			     (t nil))
     :really-assert
     (and for-real
	  (not (and info
		    (ir1-attributep (function-info-attributes info)
				    explicit-check))))
     :where (if for-real
		"previous declaration"
		"previous definition"))))

;;; Convert a lambda doing all the basic stuff we would do if we were
;;; converting a DEFUN. This is used both by the %DEFUN translator and
;;; for global inline expansion.
;;;
;;; Unless a :INLINE function, we temporarily clobber the inline
;;; expansion. This prevents recursive inline expansion of
;;; opportunistic pseudo-inlines.
(defun ir1-convert-lambda-for-defun (lambda var expansion converter)
  (declare (cons lambda) (function converter) (type defined-function var))
  (let ((var-expansion (defined-function-inline-expansion var)))
    (unless (eq (defined-function-inlinep var) :inline)
      (setf (defined-function-inline-expansion var) nil))
    (let* ((name (leaf-name var))
	   (fun (funcall converter lambda name))
	   (function-info (info :function :info name)))
      (setf (functional-inlinep fun) (defined-function-inlinep var))
      (assert-new-definition var fun)
      (setf (defined-function-inline-expansion var) var-expansion)
      ;; If definitely not an interpreter stub, then substitute for any
      ;; old references.
      (unless (or (eq (defined-function-inlinep var) :notinline)
		  (not *block-compile*)
		  (and function-info
		       (or (function-info-transforms function-info)
			   (function-info-templates function-info)
			   (function-info-ir2-convert function-info))))
	(substitute-leaf fun var)
	;; If in a simple environment, then we can allow backward
	;; references to this function from following top-level forms.
	(when expansion (setf (defined-function-functional var) fun)))
      fun)))

;;; the even-at-compile-time part of DEFUN
;;;
;;; The INLINE-EXPANSION is a LAMBDA-WITH-LEXENV, or NIL if there is
;;; no inline expansion.
(defun %compiler-defun (name lambda-with-lexenv)

  (let ((defined-function nil)) ; will be set below if we're in the compiler
    
    ;; when in the compiler
    (when (boundp '*lexenv*) 
      (when sb!xc:*compile-print*
	(compiler-mumble "~&; recognizing DEFUN ~S~%" name))
      (remhash name *free-functions*)
      (setf defined-function (get-defined-function name)))

    (become-defined-function-name name)

    (cond (lambda-with-lexenv
	   (setf (info :function :inline-expansion name) lambda-with-lexenv)
	   (when defined-function 
	     (setf (defined-function-inline-expansion defined-function)
		   lambda-with-lexenv)))
	  (t
	   (clear-info :function :inline-expansion name)))

    ;; old CMU CL comment:
    ;;   If there is a type from a previous definition, blast it,
    ;;   since it is obsolete.
    (when (and defined-function
	       (eq (leaf-where-from defined-function) :defined))
      (setf (leaf-type defined-function)
	    ;; FIXME: If this is a block compilation thing, shouldn't
	    ;; we be setting the type to the full derived type for the
	    ;; definition, instead of this most general function type?
	    (specifier-type 'function))))

  (values))

;;;; hacking function names

;;; This is like LAMBDA, except the result is tweaked so that
;;; %FUNCTION-NAME or BYTE-FUNCTION-NAME can extract a name. (Also
;;; possibly the name could also be used at compile time to emit
;;; more-informative name-based compiler diagnostic messages as well.)
(defmacro-mundanely named-lambda (name args &body body)

  ;; FIXME: For now, in this stub version, we just discard the name. A
  ;; non-stub version might use either macro-level LOAD-TIME-VALUE
  ;; hackery or customized IR1-transform level magic to actually put
  ;; the name in place.
  (aver (legal-function-name-p name))
  `(lambda ,args ,@body))
