;;;; most of the DESCRIBE mechanism -- that part which isn't derived
;;;; from PCL code

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-IMPL") ;(SB-IMPL, not SB!IMPL, since we're built in warm load.)

(declaim (ftype (function (t stream)) describe-object))
(defgeneric describe-object (x stream))

(defun describe (x &optional (stream-designator *standard-output*))
  #+sb-doc
  "Print a description of the object X."
  (let ((stream (out-synonym-of stream-designator)))
    (fresh-line stream)
    (pprint-logical-block (stream nil)
      (describe-object x stream)
      (pprint-newline :mandatory stream)))
  (values))

;;;; miscellaneous DESCRIBE-OBJECT methods

(defmethod describe-object ((x t) s)
  (format s "~@<~S ~_is a ~S.~:>" x (type-of x)))

(defmethod describe-object ((x cons) s)
  (call-next-method)
  (when (and (legal-fun-name-p x)
	     (fboundp x))
    (%describe-fun (fdefinition x) s :function x)
    ;;was: (format s "~@:_Its FDEFINITION is ~S.~@:_" (fdefinition x))
    ;; TO DO: should check for SETF documentation.
    ;; TO DO: should make it clear whether the definition is a
    ;; DEFUN (SETF FOO) or DEFSETF FOO or what.
    ))

(defmethod describe-object ((x array) s)
  (let ((rank (array-rank x)))
    (cond ((= rank 1)
	   (format s
		   "~@:_~S is a ~:[~;displaced ~]vector of length ~S." x
		   (and (array-header-p x) (%array-displaced-p x)) (length x))
	   (when (array-has-fill-pointer-p x)
	     (format s "~@:_It has a fill pointer, currently ~S."
		     (fill-pointer x))))
	  (t
	   (format s "~S ~_is " x)
	   (write-string (if (%array-displaced-p x) "a displaced" "an") s)
	   (format s " array of rank ~S." rank)
	   (format s "~@:_Its dimensions are ~S." (array-dimensions x)))))
  (let ((array-element-type (array-element-type x)))
    (unless (eq array-element-type t)
      (format s
	      "~@:_Its element type is specialized to ~S."
	      array-element-type))))

(defmethod describe-object ((x hash-table) s)
  (declare (type stream s))
  (format s "~@<~S ~_is an ~S hash table.~:>" x (hash-table-test x))
  (format s "~_Its SIZE is ~S." (hash-table-size x))
  (format s
	  "~@:_~@<Its REHASH-SIZE is ~S. ~_Its REHASH-THRESHOLD is ~S.~:>"
	  (hash-table-rehash-size x)
	  (hash-table-rehash-threshold x))
  (let ((count (hash-table-count x)))
    (format s "~@:_It holds ~S key/value pair~:P~:[: ~2I~_~;.~]"
	    count (zerop count))
    (let ((n 0))
      (declare (type index n))
      (dohash (k v x)
	(unless (zerop n)
	  (write-char #\space s))
	(incf n)
	(when (and *print-length* (> n *print-length*))
	  (format s "~:_...")
	  (return))
	(format s "~:_(~@<~S ~:_~S~:>)" k v)))))

(defmethod describe-object ((condition condition) s)
  (sb-kernel:describe-condition condition s))

;;;; DESCRIBE-OBJECT methods for symbols and functions, including all
;;;; sorts of messy stuff about documentation, type information,
;;;; packaging, function implementation, etc..

;;; Print the specified kind of documentation about the given NAME. If
;;; NAME is null, or not a valid name, then don't print anything.
(declaim (ftype (function (t stream t t) (values)) %describe-doc))
(defun %describe-doc (name s kind kind-doc)
  (when (and name (typep name '(or symbol cons)))
    (let ((doc (fdocumentation name kind)))
      (when doc
	(format s "~_~@(~A documentation:~)~@:_  ~A"
		(or kind-doc kind) doc))))
  (values))

;;; Describe various stuff about the functional semantics attached to
;;; the specified NAME, if NAME is the kind of thing you can look
;;; up as a name. (In the case of anonymous closures and other
;;; things, it might not be.) TYPE-SPEC is the function type specifier
;;; extracted from the definition, or NIL if none.
(declaim (ftype (function (t stream t)) %describe-fun-name))
(defun %describe-fun-name (name s type-spec) 
  (when (and name (typep name '(or symbol cons)))
    (multiple-value-bind (type where)
	(if (legal-fun-name-p name)
	    (values (type-specifier (info :function :type name))
		    (info :function :where-from name))
	    (values type-spec :defined))
      (when (consp type)
	(format s "~@:_Its ~(~A~) argument types are:~@:_  ~S"
		where (second type))
	(format s "~@:_Its result type is:~@:_  ~S" (third type))))
    (let ((inlinep (info :function :inlinep name)))
      (when inlinep
	(format s
		"~@:_It is currently declared ~(~A~);~
		 ~:[no~;~] expansion is available."
		inlinep (info :function :inline-expansion-designator name))))))

;;; Print information from the debug-info about where CODE-OBJ was
;;; compiled from.
(defun %describe-compiled-from (code-obj s)
  (declare (type stream s))
  (let ((info (sb-kernel:%code-debug-info code-obj)))
    (when info
      (let ((sources (sb-c::debug-info-source info)))
	(when sources
	  (format s "~@:_On ~A it was compiled from:"
		  ;; FIXME: The FORMAT-UNIVERSAL-TIME calls in the system
		  ;; should become more consistent, probably not using
		  ;; any nondefault options.
		  (format-universal-time nil
					 (sb-c::debug-source-compiled
					  (first sources))
					 :style :abbreviated))
	  (dolist (source sources)
	    (let ((name (sb-c::debug-source-name source)))
	      (ecase (sb-c::debug-source-from source)
		(:file
		 (format s "~@:_~A~@:_  Created: " (namestring name))
		 (format-universal-time s (sb-c::debug-source-created
					   source)))
		(:lisp (format s "~@:_~S" name))))))))))

;;; Describe a compiled function. The closure case calls us to print
;;; the guts.
(defun %describe-fun-compiled (x s kind name)
  (declare (type stream s))
  (let ((args (%simple-fun-arglist x)))
    (cond ((not args)
	   (write-string "  There are no arguments." s))
	  (t
           (format s "~@:_~@(The ~@[~A's ~]arguments are:~@:_~)" kind)
	   (write-string "  " s)
            (let ((*print-pretty* t)
                  (*print-escape* t)
                  (*print-base* 10)
                  (*print-radix* nil))
              (pprint-logical-block (s nil)
                 (pprint-indent :current 2)
                 (format s "~A" args))))))
  (let ((name (or name (%simple-fun-name x))))
    (%describe-doc name s 'function kind)
    (unless (eq kind :macro)
      (%describe-fun-name name s (%simple-fun-type x))))
  (%describe-compiled-from (sb-kernel:fun-code-header x) s))

;;; Describe a function object. KIND and NAME provide some information
;;; about where the function came from.
(defun %describe-fun (x s &optional (kind :function) (name nil))
  (declare (type function x))
  (declare (type stream s))
  (declare (type (member :macro :function) kind))
  (fresh-line s)
  (ecase kind
    (:macro (format s "Macro-function: ~S" x))
    (:function (if name
		   (format s "Function: ~S" x)
		   (format s "~S is a function." x))))
  (format s "~@:_~@<Its associated name (as in ~S) is ~2I~_~S.~:>"
	  'function-lambda-expression
	  (%fun-name x))
  (case (widetag-of x)
    (#.sb-vm:closure-header-widetag
     (%describe-fun-compiled (%closure-fun x) s kind name)
     (format s "~@:_Its closure environment is:")
     (pprint-logical-block (s nil)
       (pprint-indent :current 8)
       (dotimes (i (- (get-closure-length x) (1- sb-vm:closure-info-offset)))
	 (format s "~@:_~S: ~S" i (%closure-index-ref x i)))))
    ((#.sb-vm:simple-fun-header-widetag #.sb-vm:closure-fun-header-widetag)
     (%describe-fun-compiled x s kind name))
    (#.sb-vm:funcallable-instance-header-widetag
     ;; Only STANDARD-GENERIC-FUNCTION would be handled here, but
     ;; since it has its own DESCRIBE-OBJECT method, it should've been
     ;; picked off before getting here. So hopefully we never get here.
     (format s "~@:_It is an unknown type of funcallable instance."))
    (t
     (format s "~@:_It is an unknown type of function."))))

(defmethod describe-object ((x function) s)
  (%describe-fun x s :function))

(defgeneric describe-symbol-fdefinition (function stream &key name))

(defmethod describe-symbol-fdefinition ((fun function) stream &key name)
  (%describe-fun fun stream :function name))

(defmethod describe-symbol-fdefinition ((fun standard-generic-function) stream
                                        &key name)
  (declare (ignore name))
  ;; just delegate
  (describe-object fun stream))

(defmethod describe-object ((x symbol) s)
  (declare (type stream s))

  ;; Describe the packaging.
  (let ((package (symbol-package x)))
    (if package
	(multiple-value-bind (symbol status)
	    (find-symbol (symbol-name x) package)
	  (declare (ignore symbol))
	  (format s "~@<~S is ~_an ~(~A~) symbol ~_in ~S.~:>"
		  x status (symbol-package x)))
	(format s "~@<~S is ~_an uninterned symbol.~:>" x)))
  ;; TO DO: We could grovel over all packages looking for and
  ;; reporting other phenomena, e.g. IMPORT and SHADOW, or
  ;; availability in some package even after (SYMBOL-PACKAGE X) has
  ;; been set to NIL.

  ;; Describe the value cell.
  (let* ((kind (info :variable :kind x))
	 (wot (ecase kind
		(:special "special variable")
                (:macro "symbol macro")
		(:constant "constant")
		(:global "undefined variable")
		(:alien nil))))
    (cond
     ((eq kind :alien)
      (let ((info (info :variable :alien-info x)))
	(format s "~@:_~@<It is an alien at #X~8,'0X of type ~3I~:_~S.~:>~@:_"
		(sap-int (eval (sb-alien::heap-alien-info-sap-form info)))
		(sb-alien-internals:unparse-alien-type
		 (sb-alien::heap-alien-info-type info)))
	(format s "~@<Its current value is ~3I~:_~S.~:>"
		(eval x))))
     ((eq kind :macro)
      (let ((expansion (info :variable :macro-expansion x)))
        (format s "~@:_It is a ~A with expansion ~S." wot expansion)))
     ((boundp x)
      (format s "~@:_~@<It is a ~A; its ~_value is ~S.~:>"
	      wot (symbol-value x)))
     ((not (eq kind :global))
      (format s "~@:_~@<It is a ~A; no current value.~:>" wot)))

    (when (eq (info :variable :where-from x) :declared)
      (format s "~@:_~@<Its declared type ~_is ~S.~:>"
	      (type-specifier (info :variable :type x))))

    (%describe-doc x s 'variable kind))

  ;; Print out properties.
  (format s "~@[~@:_Its SYMBOL-PLIST is ~@<~2I~_~S~:>.~]" (symbol-plist x))

  ;; Describe the function cell.
  (cond ((macro-function x)
	 (%describe-fun (macro-function x) s :macro x))
	((special-operator-p x)
	 (%describe-doc x s :function "Special form"))
	((fboundp x)
         (describe-symbol-fdefinition (fdefinition x) s :name x)))

  ;; Print other documentation.
  (%describe-doc x s 'structure "Structure")
  (%describe-doc x s 'type "Type")
  (%describe-doc x s 'setf "Setf macro")
  (dolist (assoc (info :random-documentation :stuff x))
    (format s
	    "~@:_Documentation on the ~(~A~):~@:_~A"
	    (car assoc)
	    (cdr assoc)))
  
  ;; Mention the associated type information, if any.
  ;;
  ;; As of sbcl-0.7.2, (INFO :TYPE :KIND X) might be
  ;;   * :PRIMITIVE, which is handled by the FIND-CLASS case.
  ;;   * :DEFINED, which is handled specially.
  ;;   * :INSTANCE, which is handled by the FIND-CLASS case.
  ;;   * :FORTHCOMING-DEFCLASS-TYPE, which is an internal-to-the-compiler
  ;;     note that we don't try to report.
  ;;   * NIL, in which case there's nothing to see here, move along.
  (when (eq (info :type :kind x) :defined)
    (format s "~@:_It names a type specifier."))
  (let ((symbol-named-class (cl:find-class x nil)))
    (when symbol-named-class
      (format s "~@:_It names a class ~A." symbol-named-class)
      (describe symbol-named-class s))))
