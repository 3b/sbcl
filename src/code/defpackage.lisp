;;;; the DEFPACKAGE macro

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; the list of packages to use by default when no :USE argument is
;;; supplied to MAKE-PACKAGE or other package creation forms
;;;
;;; ANSI specifies (1) that MAKE-PACKAGE and DEFPACKAGE use the same
;;; value, and (2) that it (as an implementation-defined value) should
;;; be documented, which we do in the doc string. So for OAOO reasons
;;; we represent this value as a variable only at compile time, and
;;; then use #. readmacro hacks to splice it into the target code as a
;;; constant.
(eval-when (:compile-toplevel)
  (defparameter *default-package-use-list*
    ;; ANSI says this is implementation-defined. So we make it NIL,
    ;; the way God intended. Anyone who actually wants a random value
    ;; is free to :USE (PACKAGE-USE-LIST :CL-USER) anyway.:-|
    nil))

(defmacro defpackage (package &rest options)
  #!+sb-doc 
  #.(format nil 
  "Defines a new package called PACKAGE. Each of OPTIONS should be one of the 
   following: ~{~&~4T~A~}
   All options except ~{~A, ~}and :DOCUMENTATION can be used multiple 
   times."
  '((:nicknames "{package-name}*")
    (:size "<integer>")
    (:shadow "{symbol-name}*")
    (:shadowing-import-from "<package-name> {symbol-name}*")
    (:use "{package-name}*")
    (:import-from "<package-name> {symbol-name}*")
    (:intern "{symbol-name}*")
    (:export "{symbol-name}*")
    #!+sb-package-locks (:implement "{package-name}*")
    #!+sb-package-locks (:lock "boolean")
    (:documentation "doc-string"))
  '(:size #!+sb-package-locks :lock))
  (let ((nicknames nil)
	(size nil)
	(shadows nil)
	(shadowing-imports nil)
	(use nil)
	(use-p nil)
	(imports nil)
	(interns nil)
	(exports nil)
	(implement (stringify-names (list package) "package"))
	(implement-p nil)
	(lock nil)
	(doc nil))
    #!-sb-package-locks    
    (declare (ignore implement-p))
    (dolist (option options)
      (unless (consp option)
	(error 'simple-program-error
	       :format-control "bogus DEFPACKAGE option: ~S"
	       :format-arguments (list option)))
      (case (car option)
	(:nicknames
	 (setf nicknames (stringify-names (cdr option) "package")))
	(:size
	 (cond (size
		(error 'simple-program-error
		       :format-control "can't specify :SIZE twice."))
	       ((and (consp (cdr option))
		     (typep (second option) 'unsigned-byte))
		(setf size (second option)))
	       (t
		(error
		 'simple-program-error
		 :format-control ":SIZE is not a positive integer: ~S"
		 :format-arguments (list (second option))))))
	(:shadow
	 (let ((new (stringify-names (cdr option) "symbol")))
	   (setf shadows (append shadows new))))
	(:shadowing-import-from
	 (let ((package-name (stringify-name (second option) "package"))
	       (names (stringify-names (cddr option) "symbol")))
	   (let ((assoc (assoc package-name shadowing-imports
			       :test #'string=)))
	     (if assoc
		 (setf (cdr assoc) (append (cdr assoc) names))
		 (setf shadowing-imports
		       (acons package-name names shadowing-imports))))))
	(:use
	 (setf use (append use (stringify-names (cdr option) "package") )
	       use-p t))
	(:import-from
	 (let ((package-name (stringify-name (second option) "package"))
	       (names (stringify-names (cddr option) "symbol")))
	   (let ((assoc (assoc package-name imports
			       :test #'string=)))
	     (if assoc
		 (setf (cdr assoc) (append (cdr assoc) names))
		 (setf imports (acons package-name names imports))))))
	(:intern
	 (let ((new (stringify-names (cdr option) "symbol")))
	   (setf interns (append interns new))))
	(:export
	 (let ((new (stringify-names (cdr option) "symbol")))
	   (setf exports (append exports new))))
	#!+sb-package-locks
	(:implement
	 (unless implement-p 
	   (setf implement nil))
	 (let ((new (stringify-names (cdr option) "package")))
	   (setf implement (append implement new)
		 implement-p t)))
	#!+sb-package-locks
	(:lock
	 (when lock
	   (error 'simple-program-error
		  :format-control "multiple :LOCK options"))
	 (setf lock (coerce (second option) 'boolean)))
	(:documentation
	 (when doc
	   (error 'simple-program-error
		  :format-control "multiple :DOCUMENTATION options"))
	 (setf doc (coerce (second option) 'simple-string)))
	(t
	 (error 'simple-program-error
		:format-control "bogus DEFPACKAGE option: ~S"
		:format-arguments (list option)))))
    (check-disjoint `(:intern ,@interns) `(:export  ,@exports))
    (check-disjoint `(:intern ,@interns)
		    `(:import-from
		      ,@(apply #'append (mapcar #'rest imports)))
		    `(:shadow ,@shadows)
		    `(:shadowing-import-from
		      ,@(apply #'append (mapcar #'rest shadowing-imports))))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (%defpackage ,(stringify-name package "package") ',nicknames ',size
		    ',shadows ',shadowing-imports ',(if use-p use :default)
		    ',imports ',interns ',exports ',implement ',lock ',doc))))

(defun check-disjoint (&rest args)
  ;; An arg is (:key . set)
  (do ((list args (cdr list)))
      ((endp list))
    (loop
      with x = (car list)
      for y in (rest list)
      for z = (remove-duplicates (intersection (cdr x)(cdr y) :test #'string=))
      when z do (error 'simple-program-error
		       :format-control "Parameters ~S and ~S must be disjoint ~
                                        but have common elements ~%   ~S"
		       :format-arguments (list (car x)(car y) z)))))

(defun stringify-name (name kind)
  (typecase name
    (simple-string name)
    (string (coerce name 'simple-string))
    (symbol (symbol-name name))
    (character (string name))
    (t
     (error "bogus ~A name: ~S" kind name))))

(defun stringify-names (names kind)
  (mapcar (lambda (name)
	    (stringify-name name kind))
	  names))

(defun %defpackage (name nicknames size shadows shadowing-imports
		    use imports interns exports implement lock doc-string)
  (declare (type simple-string name)
	   (type list nicknames shadows shadowing-imports
		 imports interns exports)
	   (type (or list (member :default)) use)
	   (type (or simple-string null) doc-string)
	   #!-sb-package-locks
	   (ignore implement lock))
  (let ((package (or (find-package name)
		     (progn
		       (when (eq use :default)
			 (setf use '#.*default-package-use-list*))
		       (make-package name
				     :use nil
				     :internal-symbols (or size 10)
				     :external-symbols (length exports))))))
    (unless (string= (the string (package-name package)) name)
      (error 'simple-package-error
	     :package name
	     :format-control "~A is a nickname for the package ~A"
	     :format-arguments (list name (package-name name))))
    (enter-new-nicknames package nicknames)
    ;; Handle shadows and shadowing-imports.
    (let ((old-shadows (package-%shadowing-symbols package)))
      (shadow shadows package)
      (dolist (sym-name shadows)
	(setf old-shadows (remove (find-symbol sym-name package) old-shadows)))
      (dolist (simports-from shadowing-imports)
	(let ((other-package (find-undeleted-package-or-lose
			      (car simports-from))))
	  (dolist (sym-name (cdr simports-from))
	    (let ((sym (find-or-make-symbol sym-name other-package)))
	      (shadowing-import sym package)
	      (setf old-shadows (remove sym old-shadows))))))
      (when old-shadows
	(warn 'package-at-variance
	      :format-control "~A also shadows the following symbols:~%  ~S"
	      :format-arguments (list name old-shadows))))
    ;; Handle USE.
    (unless (eq use :default)
      (let ((old-use-list (package-use-list package))
	    (new-use-list (mapcar #'find-undeleted-package-or-lose use)))
	(use-package (set-difference new-use-list old-use-list) package)
	(let ((laterize (set-difference old-use-list new-use-list)))
	  (when laterize
	    (unuse-package laterize package)
	    (warn 'package-at-variance
		  :format-control "~A used to use the following packages:~%  ~S"
		  :format-arguments (list name laterize))))))
    ;; Handle IMPORT and INTERN.
    (dolist (sym-name interns)
      (intern sym-name package))
    (dolist (imports-from imports)
      (let ((other-package (find-undeleted-package-or-lose (car
							    imports-from))))
	(dolist (sym-name (cdr imports-from))
	  (import (list (find-or-make-symbol sym-name other-package))
		  package))))
    ;; Handle exports.
    (let ((old-exports nil)
	  (exports (mapcar (lambda (sym-name) (intern sym-name package))
			   exports)))
      (do-external-symbols (sym package)
	(push sym old-exports))
      (export exports package)
      (let ((diff (set-difference old-exports exports)))
	(when diff
	  (warn 'package-at-variance
		:format-control "~A also exports the following symbols:~%  ~S" 
		:format-arguments (list name diff)))))
    #!+sb-package-locks
    (progn
      ;; Handle packages this is an implementation package of
      (dolist (p implement)
	(add-implementation-package package p))
      ;; Handle lock
      (setf (package-lock package) lock))
    ;; Handle documentation.
    (setf (package-doc-string package) doc-string)
    package))

(defun find-or-make-symbol (name package)
  (multiple-value-bind (symbol how) (find-symbol name package)
    (cond (how
	   symbol)
	  (t
	   (with-simple-restart (continue "INTERN it.")
	     (error 'simple-package-error
		    :package package
		    :format-control "no symbol named ~S in ~S"
		    :format-arguments (list name (package-name package))))
	   (intern name package)))))
