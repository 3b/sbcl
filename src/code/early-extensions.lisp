;;;; various extensions (including SB-INT "internal extensions")
;;;; available both in the cross-compilation host Lisp and in the
;;;; target SBCL

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; Lots of code wants to get to the KEYWORD package or the
;;; COMMON-LISP package without a lot of fuss, so we cache them in
;;; variables. TO DO: How much does this actually buy us? It sounds
;;; sensible, but I don't know for sure that it saves space or time..
;;; -- WHN 19990521
;;;
;;; (The initialization forms here only matter on the cross-compilation
;;; host; In the target SBCL, these variables are set in cold init.)
(declaim (type package *cl-package* *keyword-package*))
(defvar *cl-package*      (find-package "COMMON-LISP"))
(defvar *keyword-package* (find-package "KEYWORD"))

;;; something not EQ to anything we might legitimately READ
(defparameter *eof-object* (make-symbol "EOF-OBJECT"))

;;; a type used for indexing into arrays, and for related quantities
;;; like lengths of lists
;;;
;;; It's intentionally limited to one less than the
;;; ARRAY-DIMENSION-LIMIT for efficiency reasons, because in SBCL
;;; ARRAY-DIMENSION-LIMIT is MOST-POSITIVE-FIXNUM, and staying below
;;; that lets the system know it can increment a value of this type
;;; without having to worry about using a bignum to represent the
;;; result.
;;;
;;; (It should be safe to use ARRAY-DIMENSION-LIMIT as an exclusive
;;; bound because ANSI specifies it as an exclusive bound.)
(def!type index () `(integer 0 (,sb!xc:array-dimension-limit)))

;;; like INDEX, but augmented with -1 (useful when using the index
;;; to count downwards to 0, e.g. LOOP FOR I FROM N DOWNTO 0, with
;;; an implementation which terminates the loop by testing for the
;;; index leaving the loop range)
(def!type index-or-minus-1 () `(integer -1 (,sb!xc:array-dimension-limit)))

;;; the default value used for initializing character data. The ANSI
;;; spec says this is arbitrary. CMU CL used #\NULL, which we avoid
;;; because it's not in the ANSI table of portable characters.
(defconstant default-init-char #\space)

;;; CHAR-CODE values for ASCII characters which we care about but
;;; which aren't defined in section "2.1.3 Standard Characters" of the
;;; ANSI specification for Lisp
;;;
;;; KLUDGE: These are typically used in the idiom (CODE-CHAR
;;; FOO-CHAR-CODE). I suspect that the current implementation is
;;; expanding this idiom into a full call to CODE-CHAR, which is an
;;; annoying overhead. I should check whether this is happening, and
;;; if so, perhaps implement a DEFTRANSFORM or something to stop it.
;;; (or just find a nicer way of expressing characters portably?) --
;;; WHN 19990713
(defconstant bell-char-code 7)
(defconstant tab-char-code 9)
(defconstant form-feed-char-code 12)
(defconstant return-char-code 13)
(defconstant escape-char-code 27)
(defconstant rubout-char-code 127)

;;;; type-ish predicates

;;; a helper function for various macros which expect clauses of a
;;; given length, etc.
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Return true if X is a proper list whose length is between MIN and
  ;; MAX (inclusive).
  (defun proper-list-of-length-p (x min &optional (max min))
    ;; FIXME: This implementation will hang on circular list
    ;; structure. Since this is an error-checking utility, i.e. its
    ;; job is to deal with screwed-up input, it'd be good style to fix
    ;; it so that it can deal with circular list structure.
    (cond ((minusp max)
	   nil)
	  ((null x)
	   (zerop min))
	  ((consp x)
	   (and (plusp max)
		(proper-list-of-length-p (cdr x)
					 (if (plusp (1- min))
					   (1- min)
					   0)
					 (1- max))))
	  (t nil))))

;;; Is X a circular list?
(defun circular-list-p (x)
  (and (listp x)
       (labels ((safe-cddr (x) (if (listp (cdr x)) (cddr x)))) 
	 (do ((y x (safe-cddr y))
	      (started-p nil t)
	      (z x (cdr z)))
	     ((not (and (consp z) (consp y))) nil)
	   (when (and started-p (eq y z))
	     (return t))))))

;;; Is X a (possibly-improper) list of at least N elements?
(declaim (ftype (function (t index)) list-of-length-at-least-p))
(defun list-of-length-at-least-p (x n)
  (or (zerop n) ; since anything can be considered an improper list of length 0
      (and (consp x)
	   (list-of-length-at-least-p (cdr x) (1- n)))))

;;; Is X is a positive prime integer? 
(defun positive-primep (x)
  ;; This happens to be called only from one place in sbcl-0.7.0, and
  ;; only for fixnums, we can limit it to fixnums for efficiency. (And
  ;; if we didn't limit it to fixnums, we should use a cleverer
  ;; algorithm, since this one scales pretty badly for huge X.)
  (declare (fixnum x))
  (if (<= x 5)
      (and (>= x 2) (/= x 4))
      (and (not (evenp x))
	   (not (zerop (rem x 3)))
	   (do ((q 6)
		(r 1)
		(inc 2 (logxor inc 6)) ;; 2,4,2,4...
		(d 5 (+ d inc)))
	       ((or (= r 0) (> d q)) (/= r 0))
	     (declare (fixnum inc))
	     (multiple-value-setq (q r) (truncate x d))))))

;;;; the COLLECT macro
;;;;
;;;; comment from CMU CL: "the ultimate collection macro..."

;;; helper functions for COLLECT, which become the expanders of the
;;; MACROLET definitions created by COLLECT
;;;
;;; COLLECT-NORMAL-EXPANDER handles normal collection macros.
;;;
;;; COLLECT-LIST-EXPANDER handles the list collection case. N-TAIL
;;; is the pointer to the current tail of the list, or NIL if the list
;;; is empty.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun collect-normal-expander (n-value fun forms)
    `(progn
       ,@(mapcar (lambda (form) `(setq ,n-value (,fun ,form ,n-value))) forms)
       ,n-value))
  (defun collect-list-expander (n-value n-tail forms)
    (let ((n-res (gensym)))
      `(progn
	 ,@(mapcar (lambda (form)
		     `(let ((,n-res (cons ,form nil)))
			(cond (,n-tail
			       (setf (cdr ,n-tail) ,n-res)
			       (setq ,n-tail ,n-res))
			      (t
			       (setq ,n-tail ,n-res  ,n-value ,n-res)))))
		   forms)
	 ,n-value))))

;;; Collect some values somehow. Each of the collections specifies a
;;; bunch of things which collected during the evaluation of the body
;;; of the form. The name of the collection is used to define a local
;;; macro, a la MACROLET. Within the body, this macro will evaluate
;;; each of its arguments and collect the result, returning the
;;; current value after the collection is done. The body is evaluated
;;; as a PROGN; to get the final values when you are done, just call
;;; the collection macro with no arguments.
;;;
;;; INITIAL-VALUE is the value that the collection starts out with,
;;; which defaults to NIL. FUNCTION is the function which does the
;;; collection. It is a function which will accept two arguments: the
;;; value to be collected and the current collection. The result of
;;; the function is made the new value for the collection. As a
;;; totally magical special-case, FUNCTION may be COLLECT, which tells
;;; us to build a list in forward order; this is the default. If an
;;; INITIAL-VALUE is supplied for Collect, the stuff will be RPLACD'd
;;; onto the end. Note that FUNCTION may be anything that can appear
;;; in the functional position, including macros and lambdas.
(defmacro collect (collections &body body)
  (let ((macros ())
	(binds ()))
    (dolist (spec collections)
      (unless (proper-list-of-length-p spec 1 3)
	(error "malformed collection specifier: ~S." spec))
      (let* ((name (first spec))
	     (default (second spec))
	     (kind (or (third spec) 'collect))
	     (n-value (gensym (concatenate 'string
					   (symbol-name name)
					   "-N-VALUE-"))))
	(push `(,n-value ,default) binds)
	(if (eq kind 'collect)
	  (let ((n-tail (gensym (concatenate 'string
					     (symbol-name name)
					     "-N-TAIL-"))))
	    (if default
	      (push `(,n-tail (last ,n-value)) binds)
	      (push n-tail binds))
	    (push `(,name (&rest args)
		     (collect-list-expander ',n-value ',n-tail args))
		  macros))
	  (push `(,name (&rest args)
		   (collect-normal-expander ',n-value ',kind args))
		macros))))
    `(macrolet ,macros (let* ,(nreverse binds) ,@body))))

;;;; some old-fashioned functions. (They're not just for old-fashioned
;;;; code, they're also used as optimized forms of the corresponding
;;;; general functions when the compiler can prove that they're
;;;; equivalent.)

;;; like (MEMBER ITEM LIST :TEST #'EQ)
(defun memq (item list)
  #!+sb-doc
  "Returns tail of LIST beginning with first element EQ to ITEM."
  ;; KLUDGE: These could be and probably should be defined as
  ;;   (MEMBER ITEM LIST :TEST #'EQ)),
  ;; but when I try to cross-compile that, I get an error from
  ;; LTN-ANALYZE-KNOWN-CALL, "Recursive known function definition". The
  ;; comments for that error say it "is probably a botched interpreter stub".
  ;; Rather than try to figure that out, I just rewrote this function from
  ;; scratch. -- WHN 19990512
  (do ((i list (cdr i)))
      ((null i))
    (when (eq (car i) item)
      (return i))))

;;; like (ASSOC ITEM ALIST :TEST #'EQ):
;;;   Return the first pair of ALIST where ITEM is EQ to the key of
;;;   the pair.
(defun assq (item alist)
  ;; KLUDGE: CMU CL defined this with
  ;;   (DECLARE (INLINE ASSOC))
  ;;   (ASSOC ITEM ALIST :TEST #'EQ))
  ;; which is pretty, but which would have required adding awkward
  ;; build order constraints on SBCL (or figuring out some way to make
  ;; inline definitions installable at build-the-cross-compiler time,
  ;; which was too ambitious for now). Rather than mess with that, we
  ;; just define ASSQ explicitly in terms of more primitive
  ;; operations:
  (dolist (pair alist)
    (when (eq (car pair) item)
      (return pair))))

;;; like (DELETE .. :TEST #'EQ):
;;;   Delete all LIST entries EQ to ITEM (destructively modifying
;;;   LIST), and return the modified LIST.
(defun delq (item list)
  (let ((list list))
    (do ((x list (cdr x))
	 (splice '()))
	((endp x) list)
      (cond ((eq item (car x))
	     (if (null splice)
	       (setq list (cdr x))
	       (rplacd splice (cdr x))))
	    (t (setq splice x)))))) ; Move splice along to include element.


;;; like (POSITION .. :TEST #'EQ):
;;;   Return the position of the first element EQ to ITEM.
(defun posq (item list)
  (do ((i list (cdr i))
       (j 0 (1+ j)))
      ((null i))
    (when (eq (car i) item)
      (return j))))

(declaim (inline neq))
(defun neq (x y)
  (not (eq x y)))

;;;; miscellaneous iteration extensions

;;; "the ultimate iteration macro" 
;;;
;;; note for Schemers: This seems to be identical to Scheme's "named LET".
(defmacro named-let (name binds &body body)
  #!+sb-doc
  (dolist (x binds)
    (unless (proper-list-of-length-p x 2)
      (error "malformed NAMED-LET variable spec: ~S" x)))
  `(labels ((,name ,(mapcar #'first binds) ,@body))
     (,name ,@(mapcar #'second binds))))

;;; just like DOLIST, but with one-dimensional arrays
(defmacro dovector ((elt vector &optional result) &rest forms)
  (let ((index (gensym))
	(length (gensym))
	(vec (gensym)))
    `(let ((,vec ,vector))
       (declare (type vector ,vec))
       (do ((,index 0 (1+ ,index))
	    (,length (length ,vec)))
	   ((>= ,index ,length) ,result)
	 (let ((,elt (aref ,vec ,index)))
	   ,@forms)))))

;;; Iterate over the entries in a HASH-TABLE.
(defmacro dohash ((key-var value-var table &optional result) &body body)
  (multiple-value-bind (forms decls) (parse-body body nil)
    (let ((gen (gensym))
	  (n-more (gensym)))
      `(with-hash-table-iterator (,gen ,table)
	 (loop
	  (multiple-value-bind (,n-more ,key-var ,value-var) (,gen)
	    ,@decls
	    (unless ,n-more (return ,result))
	    ,@forms))))))

;;;; hash cache utility

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *profile-hash-cache* nil))

;;; a flag for whether it's too early in cold init to use caches so
;;; that we have a better chance of recovering so that we have a
;;; better chance of getting the system running so that we have a
;;; better chance of diagnosing the problem which caused us to use the
;;; caches too early
#!+sb-show
(defvar *hash-caches-initialized-p*)

;;; Define a hash cache that associates some number of argument values
;;; with a result value. The TEST-FUNCTION paired with each ARG-NAME
;;; is used to compare the value for that arg in a cache entry with a
;;; supplied arg. The TEST-FUNCTION must not error when passed NIL as
;;; its first arg, but need not return any particular value.
;;; TEST-FUNCTION may be any thing that can be placed in CAR position.
;;;
;;; NAME is used to define these functions:
;;; <name>-CACHE-LOOKUP Arg*
;;;   See whether there is an entry for the specified ARGs in the
;;;   cache. If not present, the :DEFAULT keyword (default NIL)
;;;   determines the result(s).
;;; <name>-CACHE-ENTER Arg* Value*
;;;   Encache the association of the specified args with VALUE.
;;; <name>-CACHE-CLEAR
;;;   Reinitialize the cache, invalidating all entries and allowing
;;;   the arguments and result values to be GC'd.
;;;
;;; These other keywords are defined:
;;; :HASH-BITS <n>
;;;   The size of the cache as a power of 2.
;;; :HASH-FUNCTION function
;;;   Some thing that can be placed in CAR position which will compute
;;;   a value between 0 and (1- (expt 2 <hash-bits>)).
;;; :VALUES <n>
;;;   the number of return values cached for each function call
;;; :INIT-WRAPPER <name>
;;;   The code for initializing the cache is wrapped in a form with
;;;   the specified name. (:INIT-WRAPPER is set to COLD-INIT-FORMS
;;;   in type system definitions so that caches will be created
;;;   before top-level forms run.)
(defmacro define-hash-cache (name args &key hash-function hash-bits default
				  (init-wrapper 'progn)
				  (values 1))
  (let* ((var-name (symbolicate "*" name "-CACHE-VECTOR*"))
	 (nargs (length args))
	 (entry-size (+ nargs values))
	 (size (ash 1 hash-bits))
	 (total-size (* entry-size size))
	 (default-values (if (and (consp default) (eq (car default) 'values))
			     (cdr default)
			     (list default)))
	 (n-index (gensym))
	 (n-cache (gensym)))

    (unless (= (length default-values) values)
      (error "The number of default values ~S differs from :VALUES ~D."
	     default values))

    (collect ((inlines)
	      (forms)
	      (inits)
	      (tests)
	      (sets)
	      (arg-vars)
	      (values-indices)
	      (values-names))
      (dotimes (i values)
	(values-indices `(+ ,n-index ,(+ nargs i)))
	(values-names (gensym)))
      (let ((n 0))
        (dolist (arg args)
          (unless (= (length arg) 2)
            (error "bad argument spec: ~S" arg))
          (let ((arg-name (first arg))
                (test (second arg)))
            (arg-vars arg-name)
            (tests `(,test (svref ,n-cache (+ ,n-index ,n)) ,arg-name))
            (sets `(setf (svref ,n-cache (+ ,n-index ,n)) ,arg-name)))
          (incf n)))

      (when *profile-hash-cache*
	(let ((n-probe (symbolicate "*" name "-CACHE-PROBES*"))
	      (n-miss (symbolicate "*" name "-CACHE-MISSES*")))
	  (inits `(setq ,n-probe 0))
	  (inits `(setq ,n-miss 0))
	  (forms `(defvar ,n-probe))
	  (forms `(defvar ,n-miss))
	  (forms `(declaim (fixnum ,n-miss ,n-probe)))))

      (let ((fun-name (symbolicate name "-CACHE-LOOKUP")))
	(inlines fun-name)
	(forms
	 `(defun ,fun-name ,(arg-vars)
	    ,@(when *profile-hash-cache*
		`((incf ,(symbolicate  "*" name "-CACHE-PROBES*"))))
	    (let ((,n-index (* (,hash-function ,@(arg-vars)) ,entry-size))
		  (,n-cache ,var-name))
	      (declare (type fixnum ,n-index))
	      (cond ((and ,@(tests))
		     (values ,@(mapcar (lambda (x) `(svref ,n-cache ,x))
				       (values-indices))))
		    (t
		     ,@(when *profile-hash-cache*
			 `((incf ,(symbolicate  "*" name "-CACHE-MISSES*"))))
		     ,default))))))

      (let ((fun-name (symbolicate name "-CACHE-ENTER")))
	(inlines fun-name)
	(forms
	 `(defun ,fun-name (,@(arg-vars) ,@(values-names))
	    (let ((,n-index (* (,hash-function ,@(arg-vars)) ,entry-size))
		  (,n-cache ,var-name))
	      (declare (type fixnum ,n-index))
	      ,@(sets)
	      ,@(mapcar #'(lambda (i val)
			    `(setf (svref ,n-cache ,i) ,val))
			(values-indices)
			(values-names))
	      (values)))))

      (let ((fun-name (symbolicate name "-CACHE-CLEAR")))
	(forms
	 `(defun ,fun-name ()
	    (do ((,n-index ,(- total-size entry-size) (- ,n-index ,entry-size))
		 (,n-cache ,var-name))
		((minusp ,n-index))
	      (declare (type fixnum ,n-index))
	      ,@(collect ((arg-sets))
		  (dotimes (i nargs)
		    (arg-sets `(setf (svref ,n-cache (+ ,n-index ,i)) nil)))
		  (arg-sets))
	      ,@(mapcar #'(lambda (i val)
			    `(setf (svref ,n-cache ,i) ,val))
			(values-indices)
			default-values))
	    (values)))
	(forms `(,fun-name)))

      (inits `(unless (boundp ',var-name)
		(setq ,var-name (make-array ,total-size))))
      #!+sb-show (inits `(setq *hash-caches-initialized-p* t))

      `(progn
	 (defvar ,var-name)
	 (declaim (type (simple-vector ,total-size) ,var-name))
	 #!-sb-fluid (declaim (inline ,@(inlines)))
	 (,init-wrapper ,@(inits))
	 ,@(forms)
	 ',name))))

;;; some syntactic sugar for defining a function whose values are
;;; cached by DEFINE-HASH-CACHE
(defmacro defun-cached ((name &rest options &key (values 1) default
			      &allow-other-keys)
			args &body body-decls-doc)
  (let ((default-values (if (and (consp default) (eq (car default) 'values))
			    (cdr default)
			    (list default)))
	(arg-names (mapcar #'car args)))
    (collect ((values-names))
      (dotimes (i values)
	(values-names (gensym)))
      (multiple-value-bind (body decls doc) (parse-body body-decls-doc)
	`(progn
	   (define-hash-cache ,name ,args ,@options)
	   (defun ,name ,arg-names
	     ,@decls
	     ,doc
	     (cond #!+sb-show
		   ((not (boundp '*hash-caches-initialized-p*))
		    ;; This shouldn't happen, but it did happen to me
		    ;; when revising the type system, and it's a lot
		    ;; easier to figure out what what's going on with
		    ;; that kind of problem if the system can be kept
		    ;; alive until cold boot is complete. The recovery
		    ;; mechanism should definitely be conditional on
		    ;; some debugging feature (e.g. SB-SHOW) because
		    ;; it's big, duplicating all the BODY code. -- WHN
		    (/show0 ,name " too early in cold init, uncached")
		    (/show0 ,(first arg-names) "=..")
		    (/hexstr ,(first arg-names))
		    ,@body)
		   (t
		    (multiple-value-bind ,(values-names)
			(,(symbolicate name "-CACHE-LOOKUP") ,@arg-names)
		      (if (and ,@(mapcar (lambda (val def)
					   `(eq ,val ,def))
					 (values-names) default-values))
			  (multiple-value-bind ,(values-names)
			      (progn ,@body)
			    (,(symbolicate name "-CACHE-ENTER") ,@arg-names
			     ,@(values-names))
			    (values ,@(values-names)))
			  (values ,@(values-names))))))))))))

;;;; package idioms

;;; Note: Almost always you want to use FIND-UNDELETED-PACKAGE-OR-LOSE
;;; instead of this function. (The distinction only actually matters when
;;; PACKAGE-DESIGNATOR is actually a deleted package, and in that case
;;; you generally do want to signal an error instead of proceeding.)
(defun %find-package-or-lose (package-designator)
  (or (find-package package-designator)
      (error 'sb!kernel:simple-package-error
	     :package package-designator
	     :format-control "The name ~S does not designate any package."
	     :format-arguments (list package-designator))))

;;; ANSI specifies (in the section for FIND-PACKAGE) that the
;;; consequences of most operations on deleted packages are
;;; unspecified. We try to signal errors in such cases.
(defun find-undeleted-package-or-lose (package-designator)
  (let ((maybe-result (%find-package-or-lose package-designator)))
    (if (package-name maybe-result)     ; if not deleted
	maybe-result
	(error 'sb!kernel:simple-package-error
	       :package maybe-result
	       :format-control "The package ~S has been deleted."
	       :format-arguments (list maybe-result)))))

;;;; various operations on names

;;; Is NAME a legal function name?
(defun legal-function-name-p (name)
  (or (symbolp name)
      (and (consp name)
           (eq (car name) 'setf)
           (consp (cdr name))
           (symbolp (cadr name))
           (null (cddr name)))))

;;; Given a function name, return the name for the BLOCK which
;;; encloses its body (e.g. in DEFUN, DEFINE-COMPILER-MACRO, or FLET).
(declaim (ftype (function ((or symbol cons)) symbol) function-name-block-name))
(defun function-name-block-name (function-name)
  (cond ((symbolp function-name)
	 function-name)
	((and (consp function-name)
	      (= (length function-name) 2)
	      (eq (first function-name) 'setf))
	 (second function-name))
	(t
	 (error "not legal as a function name: ~S" function-name))))

(defun looks-like-name-of-special-var-p (x)
  (and (symbolp x)
       (let ((name (symbol-name x)))
	 (and (> (length name) 2) ; to exclude '* and '**
	      (char= #\* (aref name 0))
	      (char= #\* (aref name (1- (length name))))))))

;;; ANSI guarantees that some symbols are self-evaluating. This
;;; function is to be called just before a change which would affect
;;; that. (We don't absolutely have to call this function before such
;;; changes, since such changes are given as undefined behavior. In
;;; particular, we don't if the runtime cost would be annoying. But
;;; otherwise it's nice to do so.)
(defun about-to-modify (symbol)
  (declare (type symbol symbol))
  (cond ((eq symbol t)
	 (error "Veritas aeterna. (can't change T)"))
	((eq symbol nil)
	 (error "Nihil ex nihil. (can't change NIL)"))
	((keywordp symbol)
	 (error "Keyword values can't be changed."))
	;; (Just because a value is CONSTANTP is not a good enough
	;; reason to complain here, because we want DEFCONSTANT to
	;; be able to use this function, and it's legal to DEFCONSTANT
	;; a constant as long as the new value is EQL to the old
	;; value.)
	))

;;; If COLD-FSET occurs not at top level, just treat it as an ordinary
;;; assignment. That way things like
;;;   (FLET ((FROB (X) ..))
;;;     (DEFUN FOO (X Y) (FROB X) ..)
;;;     (DEFUN BAR (Z) (AND (FROB X) ..)))
;;; can still "work" for cold init: they don't do magical static
;;; linking the way that true toplevel DEFUNs do, but at least they do
;;; the linking eventually, so as long as #'FOO and #'BAR aren't
;;; needed until "cold toplevel forms" have executed, it's OK.
(defmacro cold-fset (name lambda)
  (style-warn 
   "~@<COLD-FSET ~S not cross-compiled at top level: demoting to ~
(SETF FDEFINITION)~:@>"
   name)
  `(setf (fdefinition ',name) ,lambda))

;;;; ONCE-ONLY
;;;;
;;;; "The macro ONCE-ONLY has been around for a long time on various
;;;; systems [..] if you can understand how to write and when to use
;;;; ONCE-ONLY, then you truly understand macro." -- Peter Norvig,
;;;; _Paradigms of Artificial Intelligence Programming: Case Studies
;;;; in Common Lisp_, p. 853

;;; ONCE-ONLY is a utility useful in writing source transforms and
;;; macros. It provides a concise way to wrap a LET around some code
;;; to ensure that some forms are only evaluated once.
;;;
;;; Create a LET* which evaluates each value expression, binding a
;;; temporary variable to the result, and wrapping the LET* around the
;;; result of the evaluation of BODY. Within the body, each VAR is
;;; bound to the corresponding temporary variable.
(defmacro once-only (specs &body body)
  (named-let frob ((specs specs)
		   (body body))
    (if (null specs)
	`(progn ,@body)
	(let ((spec (first specs)))
	  ;; FIXME: should just be DESTRUCTURING-BIND of SPEC
	  (unless (proper-list-of-length-p spec 2)
	    (error "malformed ONCE-ONLY binding spec: ~S" spec))
	  (let* ((name (first spec))
		 (exp-temp (gensym (symbol-name name))))
	    `(let ((,exp-temp ,(second spec))
		   (,name (gensym "ONCE-ONLY-")))
	       `(let ((,,name ,,exp-temp))
		  ,,(frob (rest specs) body))))))))

;;;; various error-checking utilities

;;; This function can be used as the default value for keyword
;;; arguments that must be always be supplied. Since it is known by
;;; the compiler to never return, it will avoid any compile-time type
;;; warnings that would result from a default value inconsistent with
;;; the declared type. When this function is called, it signals an
;;; error indicating that a required &KEY argument was not supplied.
;;; This function is also useful for DEFSTRUCT slot defaults
;;; corresponding to required arguments.
(declaim (ftype (function () nil) required-argument))
(defun required-argument ()
  #!+sb-doc
  (/show0 "entering REQUIRED-ARGUMENT")
  (error "A required &KEY argument was not supplied."))

;;; like CL:ASSERT and CL:CHECK-TYPE, but lighter-weight
;;;
;;; (As of sbcl-0.6.11.20, we were using some 400 calls to CL:ASSERT.
;;; The CL:ASSERT restarts and whatnot expand into a significant
;;; amount of code when you multiply them by 400, so replacing them
;;; with this should reduce the size of the system by enough to be
;;; worthwhile. ENFORCE-TYPE is much less common, but might still be
;;; worthwhile, and since I don't really like CERROR stuff deep in the
;;; guts of complex systems anyway, I replaced it too.)
(defmacro aver (expr)
  `(unless ,expr
     (%failed-aver ,(let ((*package* (find-package :keyword)))
		      (format nil "~S" expr)))))
(defun %failed-aver (expr-as-string)
  (error "~@<internal error, failed AVER: ~2I~_~S~:>" expr-as-string))
(defmacro enforce-type (value type)
  (once-only ((value value))
    `(unless (typep ,value ',type)
       (%failed-enforce-type ,value ',type))))
(defun %failed-enforce-type (value type)
  (error 'simple-type-error
	 :value value
	 :expected-type type
	 :format-string "~@<~S ~_is not a ~_~S~:>"
	 :format-arguments (list value type)))

;;; Return a list of N gensyms. (This is a common suboperation in
;;; macros and other code-manipulating code.)
(declaim (ftype (function (index) list) make-gensym-list))
(defun make-gensym-list (n)
  (loop repeat n collect (gensym)))

;;; Return a function like FUN, but expecting its (two) arguments in
;;; the opposite order that FUN does.
(declaim (inline swapped-args-fun))
(defun swapped-args-fun (fun)
  (declare (type function fun))
  (lambda (x y)
    (funcall fun y x)))

;;; Return the numeric value of a type bound, i.e. an interval bound
;;; more or less in the format of bounds in ANSI's type specifiers,
;;; where a bare numeric value is a closed bound and a list of a
;;; single numeric value is an open bound.
;;;
;;; The "more or less" bit is that the no-bound-at-all case is
;;; represented by NIL (not by * as in ANSI type specifiers); and in
;;; this case we return NIL.
(defun type-bound-number (x)
  (if (consp x)
      (destructuring-bind (result) x result)
      x))

;;; some commonly-occuring CONSTANTLY forms
(macrolet ((def-constantly-fun (name constant-expr)
	     `(setf (symbol-function ',name)
		    (constantly ,constant-expr))))
  (def-constantly-fun constantly-t t)
  (def-constantly-fun constantly-nil nil)
  (def-constantly-fun constantly-0 0))

;;; If X is an atom, see whether it is present in *FEATURES*. Also
;;; handle arbitrary combinations of atoms using NOT, AND, OR.
(defun featurep (x)
  (if (consp x)
    (case (car x)
      ((:not not)
       (if (cddr x)
	 (error "too many subexpressions in feature expression: ~S" x)
	 (not (featurep (cadr x)))))
      ((:and and) (every #'featurep (cdr x)))
      ((:or or) (some #'featurep (cdr x)))
      (t
       (error "unknown operator in feature expression: ~S." x)))
    (not (null (memq x *features*)))))

;;; Given a list of keyword substitutions `(,OLD ,NEW), and a
;;; &KEY-argument-list-style list of alternating keywords and
;;; arbitrary values, return a new &KEY-argument-list-style list with
;;; all substitutions applied to it.
;;;
;;; Note: If efficiency mattered, we could do less consing. (But if
;;; efficiency mattered, why would we be using &KEY arguments at
;;; all, much less renaming &KEY arguments?)
;;;
;;; KLUDGE: It would probably be good to get rid of this. -- WHN 19991201
(defun rename-key-args (rename-list key-args)
  (declare (type list rename-list key-args))
  ;; Walk through RENAME-LIST modifying RESULT as per each element in
  ;; RENAME-LIST.
  (do ((result (copy-list key-args))) ; may be modified below
      ((null rename-list) result)
    (destructuring-bind (old new) (pop rename-list)
      ;; ANSI says &KEY arg names aren't necessarily KEYWORDs.
      (declare (type symbol old new))
      ;; Walk through RESULT renaming any OLD key argument to NEW.
      (do ((in-result result (cddr in-result)))
	  ((null in-result))
	(declare (type list in-result))
	(when (eq (car in-result) old)
	  (setf (car in-result) new))))))

;;; ANSI Common Lisp's READ-SEQUENCE function, unlike most of the
;;; other ANSI input functions, is defined to communicate end of file
;;; status with its return value, not by signalling. That is not the
;;; behavior that we usually want. This function is a wrapper which
;;; restores the behavior that we usually want, causing READ-SEQUENCE
;;; to communicate end-of-file status by signalling.
(defun read-sequence-or-die (sequence stream &key start end)
  ;; implementation using READ-SEQUENCE
  #-no-ansi-read-sequence
  (let ((read-end (read-sequence sequence
				 stream
				 :start start
				 :end end)))
    (unless (= read-end end)
      (error 'end-of-file :stream stream))
    (values))
  ;; workaround for broken READ-SEQUENCE
  #+no-ansi-read-sequence
  (progn
    (aver (<= start end))
    (let ((etype (stream-element-type stream)))
    (cond ((equal etype '(unsigned-byte 8))
	   (do ((i start (1+ i)))
	       ((>= i end)
		(values))
	     (setf (aref sequence i)
		   (read-byte stream))))
	  (t (error "unsupported element type ~S" etype))))))

;;;; utilities for two-VALUES predicates

;;; sort of like ANY and EVERY, except:
;;;   * We handle two-VALUES predicate functions, as SUBTYPEP does.
;;;     (And if the result is uncertain, then we return (VALUES NIL NIL),
;;;     as SUBTYPEP does.)
;;;   * THING is just an atom, and we apply OP (an arity-2 function)
;;;     successively to THING and each element of LIST.
(defun any/type (op thing list)
  (declare (type function op))
  (let ((certain? t))
    (dolist (i list (values nil certain?))
      (multiple-value-bind (sub-value sub-certain?) (funcall op thing i)
	(if sub-certain?
	    (when sub-value (return (values t t)))
	    (setf certain? nil))))))
(defun every/type (op thing list)
  (declare (type function op))
  (let ((certain? t))
    (dolist (i list (if certain? (values t t) (values nil nil)))
      (multiple-value-bind (sub-value sub-certain?) (funcall op thing i)
	(if sub-certain?
	    (unless sub-value (return (values nil t)))
	    (setf certain? nil))))))

;;;; DEFPRINTER

;;; These functions are called by the expansion of the DEFPRINTER
;;; macro to do the actual printing.
(declaim (ftype (function (symbol t stream) (values))
		defprinter-prin1 defprinter-princ))
(defun defprinter-prin1 (name value stream)
  (defprinter-prinx #'prin1 name value stream))
(defun defprinter-princ (name value stream)
  (defprinter-prinx #'princ name value stream))
(defun defprinter-prinx (prinx name value stream)
  (declare (type function prinx))
  (when *print-pretty*
    (pprint-newline :linear stream))
  (format stream ":~A " name)
  (funcall prinx value stream)
  (values))
(defun defprinter-print-space (stream)
  (write-char #\space stream))

;;; Define some kind of reasonable PRINT-OBJECT method for a
;;; STRUCTURE-OBJECT class.
;;;
;;; NAME is the name of the structure class, and CONC-NAME is the same
;;; as in DEFSTRUCT.
;;;
;;; The SLOT-DESCS describe how each slot should be printed. Each
;;; SLOT-DESC can be a slot name, indicating that the slot should
;;; simply be printed. A SLOT-DESC may also be a list of a slot name
;;; and other stuff. The other stuff is composed of keywords followed
;;; by expressions. The expressions are evaluated with the variable
;;; which is the slot name bound to the value of the slot. These
;;; keywords are defined:
;;;
;;; :PRIN1    Print the value of the expression instead of the slot value.
;;; :PRINC    Like :PRIN1, only PRINC the value
;;; :TEST     Only print something if the test is true.
;;;
;;; If no printing thing is specified then the slot value is printed
;;; as if by PRIN1.
;;;
;;; The structure being printed is bound to STRUCTURE and the stream
;;; is bound to STREAM.
(defmacro defprinter ((name
		       &key
		       (conc-name (concatenate 'simple-string
					       (symbol-name name)
					       "-"))
		       identity)
		      &rest slot-descs)
  (let ((first? t)
	maybe-print-space
	(reversed-prints nil)
	(stream (gensym "STREAM")))
    (flet ((sref (slot-name)
	     `(,(symbolicate conc-name slot-name) structure)))
      (dolist (slot-desc slot-descs)
	(if first?
	    (setf maybe-print-space nil
		  first? nil)
	    (setf maybe-print-space `(defprinter-print-space ,stream)))
	(cond ((atom slot-desc)
	       (push maybe-print-space reversed-prints)
	       (push `(defprinter-prin1 ',slot-desc ,(sref slot-desc) ,stream)
		     reversed-prints))
	      (t
	       (let ((sname (first slot-desc))
		     (test t))
		 (collect ((stuff))
		   (do ((option (rest slot-desc) (cddr option)))
		       ((null option)
			(push `(let ((,sname ,(sref sname)))
				 (when ,test
				   ,maybe-print-space
				   ,@(or (stuff)
					 `((defprinter-prin1
					     ',sname ,sname ,stream)))))
			      reversed-prints))
		     (case (first option)
		       (:prin1
			(stuff `(defprinter-prin1
				  ',sname ,(second option) ,stream)))
		       (:princ
			(stuff `(defprinter-princ
				  ',sname ,(second option) ,stream)))
		       (:test (setq test (second option)))
		       (t
			(error "bad option: ~S" (first option)))))))))))
    `(def!method print-object ((structure ,name) ,stream)
       ;; FIXME: should probably be byte-compiled
       (pprint-logical-block (,stream nil)
	 (print-unreadable-object (structure
				   ,stream
				   :type t
				   :identity ,identity)
	   ,@(nreverse reversed-prints))))))

;;;; etc.

;;; Given a pathname, return a corresponding physical pathname.
(defun physicalize-pathname (possibly-logical-pathname)
  (if (typep possibly-logical-pathname 'logical-pathname)
      (translate-logical-pathname possibly-logical-pathname)
      possibly-logical-pathname))
