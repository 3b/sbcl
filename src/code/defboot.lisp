;;;; bootstrapping fundamental machinery (e.g. DEFUN, DEFCONSTANT,
;;;; DEFVAR) from special forms and primitive functions
;;;;
;;;; KLUDGE: The bootstrapping aspect of this is now obsolete. It was
;;;; originally intended that this file file would be loaded into a
;;;; Lisp image which had Common Lisp primitives defined, and DEFMACRO
;;;; defined, and little else. Since then that approach has been
;;;; dropped and this file has been modified somewhat to make it work
;;;; more cleanly when used to predefine macros at
;;;; build-the-cross-compiler time.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;;; IN-PACKAGE

(defmacro-mundanely in-package (package-designator)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setq *package* (find-undeleted-package-or-lose ',package-designator))))

;;;; MULTIPLE-VALUE-FOO

(defun list-of-symbols-p (x)
  (and (listp x)
       (every #'symbolp x)))

(defmacro-mundanely multiple-value-bind (vars value-form &body body)
  (if (list-of-symbols-p vars)
    ;; It's unclear why it would be important to special-case the LENGTH=1 case
    ;; at this level, but the CMU CL code did it, so.. -- WHN 19990411
    (if (= (length vars) 1)
      `(let ((,(car vars) ,value-form))
	 ,@body)
      (let ((ignore (gensym)))
	`(multiple-value-call #'(lambda (&optional ,@vars &rest ,ignore)
				  (declare (ignore ,ignore))
				  ,@body)
			      ,value-form)))
    (error "Vars is not a list of symbols: ~S" vars)))

(defmacro-mundanely multiple-value-setq (vars value-form)
  (unless (list-of-symbols-p vars)
    (error "Vars is not a list of symbols: ~S" vars))
  `(values (setf (values ,@vars) ,value-form)))

(defmacro-mundanely multiple-value-list (value-form)
  `(multiple-value-call #'list ,value-form))

;;;; various conditional constructs

;;; COND defined in terms of IF
(defmacro-mundanely cond (&rest clauses)
  (if (endp clauses)
      nil
      (let ((clause (first clauses)))
	(if (atom clause)
	    (error "COND clause is not a list: ~S" clause)
	    (let ((test (first clause))
		  (forms (rest clause)))
	      (if (endp forms)
		  (let ((n-result (gensym)))
		    `(let ((,n-result ,test))
		       (if ,n-result
			   ,n-result
			   (cond ,@(rest clauses)))))
		  `(if ,test
		       (progn ,@forms)
		       (cond ,@(rest clauses)))))))))

;;; other things defined in terms of COND
(defmacro-mundanely when (test &body forms)
  #!+sb-doc
  "If the first argument is true, the rest of the forms are
  evaluated as a PROGN."
  `(cond (,test nil ,@forms)))
(defmacro-mundanely unless (test &body forms)
  #!+sb-doc
  "If the first argument is not true, the rest of the forms are
  evaluated as a PROGN."
  `(cond ((not ,test) nil ,@forms)))
(defmacro-mundanely and (&rest forms)
  (cond ((endp forms) t)
	((endp (rest forms)) (first forms))
	(t
	 `(if ,(first forms)
	      (and ,@(rest forms))
	      nil))))
(defmacro-mundanely or (&rest forms)
  (cond ((endp forms) nil)
	((endp (rest forms)) (first forms))
	(t
	 (let ((n-result (gensym)))
	   `(let ((,n-result ,(first forms)))
	      (if ,n-result
		  ,n-result
		  (or ,@(rest forms))))))))

;;;; various sequencing constructs

(defmacro-mundanely prog (varlist &body body-decls)
  (multiple-value-bind (body decls) (parse-body body-decls nil)
    `(block nil
       (let ,varlist
	 ,@decls
	 (tagbody ,@body)))))

(defmacro-mundanely prog* (varlist &body body-decls)
  (multiple-value-bind (body decls) (parse-body body-decls nil)
    `(block nil
       (let* ,varlist
	 ,@decls
	 (tagbody ,@body)))))

(defmacro-mundanely prog1 (result &body body)
  (let ((n-result (gensym)))
    `(let ((,n-result ,result))
       ,@body
       ,n-result)))

(defmacro-mundanely prog2 (form1 result &body body)
  `(prog1 (progn ,form1 ,result) ,@body))

;;;; DEFUN

;;; Should we save the inline expansion of the function named NAME?
(defun inline-fun-name-p (name)
  (or
   ;; the normal reason for saving the inline expansion
   (info :function :inlinep name)
   ;; another reason for saving the inline expansion: If the
   ;; ANSI-recommended idiom
   ;;   (DECLAIM (INLINE FOO))
   ;;   (DEFUN FOO ..)
   ;;   (DECLAIM (NOTINLINE FOO))
   ;; has been used, and then we later do another
   ;;   (DEFUN FOO ..)
   ;; without a preceding
   ;;   (DECLAIM (INLINE FOO))
   ;; what should we do with the old inline expansion when we see the
   ;; new DEFUN? Overwriting it with the new definition seems like
   ;; the only unsurprising choice.
   (info :function :inline-expansion-designator name)))

(defmacro-mundanely defun (&environment env name args &body body)
  "Define a function at top level."
  #+sb-xc-host
  (unless (symbol-package (fun-name-block-name name))
    (warn "DEFUN of uninterned symbol ~S (tricky for GENESIS)" name))
  (multiple-value-bind (forms decls doc) (parse-body body)
    (let* (;; stuff shared between LAMBDA and INLINE-LAMBDA and NAMED-LAMBDA
	   (lambda-guts `(,args
			  ,@decls
			  (block ,(fun-name-block-name name)
			    ,@forms)))
	   (lambda `(lambda ,@lambda-guts))
           #-sb-xc-host
	   (named-lambda `(named-lambda ,name ,@lambda-guts))
	   (inline-lambda
	    (when (inline-fun-name-p name)
	      ;; we want to attempt to inline, so complain if we can't
	      (or (sb!c:maybe-inline-syntactic-closure lambda env)
		  (progn
		    (#+sb-xc-host warn
		     #-sb-xc-host sb!c:maybe-compiler-note
		     "lexical environment too hairy, can't inline DEFUN ~S"
		     name)
		    nil)))))
      `(progn

	 ;; In cross-compilation of toplevel DEFUNs, we arrange
	 ;; for the LAMBDA to be statically linked by GENESIS.
	 ;;
	 ;; It may seem strangely inconsistent not to use NAMED-LAMBDA
	 ;; here instead of LAMBDA. The reason is historical:
	 ;; COLD-FSET was written before NAMED-LAMBDA, and has special
	 ;; logic of its own to notify the compiler about NAME.
	 #+sb-xc-host
	 (cold-fset ,name ,lambda)

	 (eval-when (:compile-toplevel :load-toplevel :execute)
	   (sb!c:%compiler-defun ',name ',inline-lambda))

	 (%defun ',name
		 ;; In normal compilation (not for cold load) this is
		 ;; where the compiled LAMBDA first appears. In
		 ;; cross-compilation, we manipulate the
		 ;; previously-statically-linked LAMBDA here.
		 #-sb-xc-host ,named-lambda
		 #+sb-xc-host (fdefinition ',name)
		 ,doc)))))
#-sb-xc-host
(defun %defun (name def doc)
  (declare (type function def))
  (declare (type (or null simple-string doc)))
  (aver (legal-fun-name-p name)) ; should've been checked by DEFMACRO DEFUN
  (when (fboundp name)
    (/show0 "redefining NAME in %DEFUN")
    (style-warn "redefining ~S in DEFUN" name))
  (setf (sb!xc:fdefinition name) def)
  
  ;; FIXME: I want to do this here (and fix bug 137), but until the
  ;; breathtaking CMU CL function name architecture is converted into
  ;; something sane, (1) doing so doesn't really fix the bug, and 
  ;; (2) doing probably isn't even really safe.
  #+nil (setf (%fun-name def) name)

  (when doc
    (setf (fdocumentation name 'function) doc))
  name)

;;;; DEFVAR and DEFPARAMETER

(defmacro-mundanely defvar (var &optional (val nil valp) (doc nil docp))
  #!+sb-doc
  "Define a global variable at top level. Declare the variable
  SPECIAL and, optionally, initialize it. If the variable already has a
  value, the old value is not clobbered. The third argument is an optional
  documentation string for the variable."
  `(progn
     (declaim (special ,var))
     ,@(when valp
	 `((unless (boundp ',var)
	     (set ',var ,val))))
     ,@(when docp
	 `((setf (fdocumentation ',var 'variable) ',doc )))
     ',var))

(defmacro-mundanely defparameter (var val &optional (doc nil docp))
  #!+sb-doc
  "Define a parameter that is not normally changed by the program,
  but that may be changed without causing an error. Declare the
  variable special and sets its value to VAL, overwriting any
  previous value. The third argument is an optional documentation
  string for the parameter."
  `(progn
     (declaim (special ,var))
     (set ',var ,val)
     ,@(when docp
	 `((setf (fdocumentation ',var 'variable) ',doc)))
     ',var))

;;;; iteration constructs

;;; (These macros are defined in terms of a function FROB-DO-BODY which
;;; is also used by SB!INT:DO-ANONYMOUS. Since these macros should not
;;; be loaded on the cross-compilation host, but SB!INT:DO-ANONYMOUS
;;; and FROB-DO-BODY should be, these macros can't conveniently be in
;;; the same file as FROB-DO-BODY.)
(defmacro-mundanely do (varlist endlist &body body)
  #!+sb-doc
  "DO ({(Var [Init] [Step])}*) (Test Exit-Form*) Declaration* Form*
  Iteration construct. Each Var is initialized in parallel to the value of the
  specified Init form. On subsequent iterations, the Vars are assigned the
  value of the Step form (if any) in parallel. The Test is evaluated before
  each evaluation of the body Forms. When the Test is true, the Exit-Forms
  are evaluated as a PROGN, with the result being the value of the DO. A block
  named NIL is established around the entire expansion, allowing RETURN to be
  used as an alternate exit mechanism."
  (frob-do-body varlist endlist body 'let 'psetq 'do nil))
(defmacro-mundanely do* (varlist endlist &body body)
  #!+sb-doc
  "DO* ({(Var [Init] [Step])}*) (Test Exit-Form*) Declaration* Form*
  Iteration construct. Each Var is initialized sequentially (like LET*) to the
  value of the specified Init form. On subsequent iterations, the Vars are
  sequentially assigned the value of the Step form (if any). The Test is
  evaluated before each evaluation of the body Forms. When the Test is true,
  the Exit-Forms are evaluated as a PROGN, with the result being the value
  of the DO. A block named NIL is established around the entire expansion,
  allowing RETURN to be used as an laternate exit mechanism."
  (frob-do-body varlist endlist body 'let* 'setq 'do* nil))

;;; DOTIMES and DOLIST could be defined more concisely using
;;; destructuring macro lambda lists or DESTRUCTURING-BIND, but then
;;; it'd be tricky to use them before those things were defined.
;;; They're used enough times before destructuring mechanisms are
;;; defined that it looks as though it's worth just implementing them
;;; ASAP, at the cost of being unable to use the standard
;;; destructuring mechanisms.
(defmacro-mundanely dotimes ((var count &optional (result nil)) &body body)
  (cond ((numberp count)
	 `(do ((,var 0 (1+ ,var)))
	   ((>= ,var ,count) ,result)
	   (declare (type unsigned-byte ,var))
	   ,@body))
	(t (let ((v1 (gensym)))
	     `(do ((,var 0 (1+ ,var)) (,v1 ,count))
	       ((>= ,var ,v1) ,result)
	       (declare (type unsigned-byte ,var))
	       ,@body)))))

(defmacro-mundanely dolist ((var list &optional (result nil)) &body body)
  ;; We repeatedly bind the var instead of setting it so that we never
  ;; have to give the var an arbitrary value such as NIL (which might
  ;; conflict with a declaration). If there is a result form, we
  ;; introduce a gratuitous binding of the variable to NIL without the
  ;; declarations, then evaluate the result form in that
  ;; environment. We spuriously reference the gratuitous variable,
  ;; since we don't want to use IGNORABLE on what might be a special
  ;; var.
  (multiple-value-bind (forms decls) (parse-body body nil)
    (let ((n-list (gensym)))
      `(do* ((,n-list ,list (cdr ,n-list)))
	((endp ,n-list)
	 ,@(if result
	       `((let ((,var nil))
		   ,var
		   ,result))
	       '(nil)))
	(let ((,var (car ,n-list)))
	  ,@decls
	  (tagbody
	     ,@forms))))))

;;;; miscellaneous

(defmacro-mundanely return (&optional (value nil))
  `(return-from nil ,value))

(defmacro-mundanely psetq (&rest pairs)
  #!+sb-doc
  "PSETQ {var value}*
   Set the variables to the values, like SETQ, except that assignments
   happen in parallel, i.e. no assignments take place until all the
   forms have been evaluated."
  ;; Given the possibility of symbol-macros, we delegate to PSETF
  ;; which knows how to deal with them, after checking that syntax is
  ;; compatible with PSETQ.
  (do ((pair pairs (cddr pair)))
      ((endp pair) `(psetf ,@pairs))
    (unless (symbolp (car pair))
      (error 'simple-program-error
	     :format-control "variable ~S in PSETQ is not a SYMBOL"
	     :format-arguments (list (car pair))))))

(defmacro-mundanely lambda (&whole whole args &body body)
  (declare (ignore args body))
  `#',whole)

(defmacro-mundanely named-lambda (&whole whole name args &body body)
  (declare (ignore name args body))
  `#',whole)

(defmacro-mundanely lambda-with-lexenv (&whole whole
					declarations macros symbol-macros
					&body body)
  (declare (ignore declarations macros symbol-macros body))
  `#',whole)
