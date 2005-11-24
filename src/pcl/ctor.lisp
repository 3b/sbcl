;;;; This file contains the optimization machinery for make-instance.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

;;;; This software is derived from software originally released by
;;;; Gerd Moellmann.  Copyright and release statements follow.  Later
;;;; modifications to the software are in the public domain and are
;;;; provided with absolutely no warranty.  See the COPYING and
;;;; CREDITS files for more information.

;;; Copyright (C) 2002 Gerd Moellmann <gerd.moellmann@t-online.de>
;;; All rights reserved.
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;; 1. Redistributions of source code must retain the above copyright
;;;    notice, this list of conditions and the following disclaimer.
;;; 2. Redistributions in binary form must reproduce the above copyright
;;;    notice, this list of conditions and the following disclaimer in the
;;;    documentation and/or other materials provided with the distribution.
;;; 3. The name of the author may not be used to endorse or promote
;;;    products derived from this software without specific prior written
;;;    permission.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
;;; OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
;;; BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;; LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
;;; USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
;;; DAMAGE.

;;; ***************
;;; Overview  *****
;;; ***************
;;;
;;; Compiler macro for MAKE-INSTANCE, and load-time generation of
;;; optimized instance constructor functions.
;;;
;;; ********************
;;; Entry Points  ******
;;; ********************
;;;
;;; UPDATE-CTORS must be called when methods are added/removed,
;;; classes are changed, etc., which affect instance creation.
;;;
;;; PRECOMPILE-CTORS can be called to precompile constructor functions
;;; for classes whose definitions are known at the time the function
;;; is called.

(in-package "SB-PCL")

;;; ******************
;;; Utilities  *******
;;; ******************

(defun quote-plist-keys (plist)
  (loop for (key . more) on plist by #'cddr
        if (null more) do
          (error "Not a property list: ~S" plist)
        else
          collect `(quote ,key)
          and collect (car more)))

(defun plist-keys (plist &key test)
  (loop for (key . more) on plist by #'cddr
        if (null more) do
          (error "Not a property list: ~S" plist)
        else if (or (null test) (funcall test key))
          collect key))

(defun plist-values (plist &key test)
  (loop for (key . more) on plist by #'cddr
        if (null more) do
          (error "Not a property list: ~S" plist)
        else if (or (null test) (funcall test (car more)))
          collect (car more)))

(defun constant-symbol-p (form)
  (and (constantp form)
       (let ((constant (eval form)))
         (and (symbolp constant)
              (not (null (symbol-package constant)))))))

;;; somewhat akin to DEFAULT-INITARGS (SLOT-CLASS T T), but just
;;; collecting the defaulted initargs for the call.
(defun ctor-default-initkeys (supplied-initargs class-default-initargs)
  (loop for (key) in class-default-initargs
        when (eq (getf supplied-initargs key '.not-there.) '.not-there.)
        collect key))

;;; *****************
;;; CTORS   *********
;;; *****************
;;;
;;; Ctors are funcallable instances whose initial function is a
;;; function computing an optimized constructor function when called.
;;; When the optimized function is computed, the function of the
;;; funcallable instance is set to it.
;;;
(!defstruct-with-alternate-metaclass ctor
  :slot-names (function-name class-name class initargs)
  :boa-constructor %make-ctor
  :superclass-name function
  :metaclass-name random-pcl-classoid
  :metaclass-constructor make-random-pcl-classoid
  :dd-type funcallable-structure
  :runtime-type-checks-p nil)

;;; List of all defined ctors.

(defvar *all-ctors* ())

(defun make-ctor-parameter-list (ctor)
  (plist-values (ctor-initargs ctor) :test (complement #'constantp)))

;;; Reset CTOR to use a default function that will compute an
;;; optimized constructor function when called.
(defun install-initial-constructor (ctor &key force-p)
  (when (or force-p (ctor-class ctor))
    (setf (ctor-class ctor) nil)
    (setf (funcallable-instance-fun ctor)
          #'(lambda (&rest args)
              (install-optimized-constructor ctor)
              (apply ctor args)))
    (setf (%funcallable-instance-info ctor 1)
          (ctor-function-name ctor))))

(defun make-ctor-function-name (class-name initargs)
  (list* 'ctor class-name initargs))

;;; Keep this a separate function for testing.
(defun ensure-ctor (function-name class-name initargs)
  (unless (fboundp function-name)
    (make-ctor function-name class-name initargs)))

;;; Keep this a separate function for testing.
(defun make-ctor (function-name class-name initargs)
  (without-package-locks ; for (setf symbol-function)
   (let ((ctor (%make-ctor function-name class-name nil initargs)))
     (push ctor *all-ctors*)
     (setf (fdefinition function-name) ctor)
     (install-initial-constructor ctor :force-p t)
     ctor)))


;;; ***********************************************
;;; Compile-Time Expansion of MAKE-INSTANCE *******
;;; ***********************************************

(define-compiler-macro make-instance (&whole form &rest args)
  (declare (ignore args))
  (or (make-instance->constructor-call form)
      form))

(defun make-instance->constructor-call (form)
  (destructuring-bind (fn class-name &rest args) form
    (declare (ignore fn))
    (flet (;;
           ;; Return the name of parameter number I of a constructor
           ;; function.
           (parameter-name (i)
             (let ((ps #(.p0. .p1. .p2. .p3. .p4. .p5.)))
               (if (array-in-bounds-p ps i)
                   (aref ps i)
                   (format-symbol *pcl-package* ".P~D." i))))
           ;; Check if CLASS-NAME is a constant symbol.  Give up if
           ;; not.
           (check-class ()
             (unless (and class-name (constant-symbol-p class-name))
               (return-from make-instance->constructor-call nil)))
           ;; Check if ARGS are suitable for an optimized constructor.
           ;; Return NIL from the outer function if not.
           (check-args ()
             (loop for (key . more) on args by #'cddr do
                     (when (or (null more)
                               (not (constant-symbol-p key))
                               (eq :allow-other-keys (eval key)))
                       (return-from make-instance->constructor-call nil)))))
      (check-class)
      (check-args)
      ;; Collect a plist of initargs and constant values/parameter names
      ;; in INITARGS.  Collect non-constant initialization forms in
      ;; VALUE-FORMS.
      (multiple-value-bind (initargs value-forms)
          (loop for (key value) on args by #'cddr and i from 0
                collect (eval key) into initargs
                if (constantp value)
                  collect value into initargs
                else
                  collect (parameter-name i) into initargs
                  and collect value into value-forms
                finally
                  (return (values initargs value-forms)))
        (let* ((class-name (eval class-name))
               (function-name (make-ctor-function-name class-name initargs)))
          ;; Prevent compiler warnings for calling the ctor.
          (proclaim-as-fun-name function-name)
          (note-name-defined function-name :function)
          (when (eq (info :function :where-from function-name) :assumed)
            (setf (info :function :where-from function-name) :defined)
            (when (info :function :assumed-type function-name)
              (setf (info :function :assumed-type function-name) nil)))
          ;; Return code constructing a ctor at load time, which, when
          ;; called, will set its funcallable instance function to an
          ;; optimized constructor function.
          `(locally
               (declare (disable-package-locks ,function-name))
            (let ((.x. (load-time-value
                        (ensure-ctor ',function-name ',class-name ',initargs))))
              (declare (ignore .x.))
              ;; ??? check if this is worth it.
              (declare
               (ftype (or (function ,(make-list (length value-forms)
                                                :initial-element t)
                                    t)
                          (function (&rest t) t))
                      ,function-name))
              (funcall (function ,function-name) ,@value-forms))))))))


;;; **************************************************
;;; Load-Time Constructor Function Generation  *******
;;; **************************************************

;;; The system-supplied primary INITIALIZE-INSTANCE and
;;; SHARED-INITIALIZE methods.  One cannot initialize these variables
;;; to the right values here because said functions don't exist yet
;;; when this file is first loaded.
(defvar *the-system-ii-method* nil)
(defvar *the-system-si-method* nil)

(defun install-optimized-constructor (ctor)
  (let ((class (find-class (ctor-class-name ctor))))
    (unless (class-finalized-p class)
      (finalize-inheritance class))
    (setf (ctor-class ctor) class)
    (pushnew ctor (plist-value class 'ctors))
    (setf (funcallable-instance-fun ctor)
          (multiple-value-bind (form locations names)
              (constructor-function-form ctor)
            (apply (compile nil `(lambda ,names ,form)) locations)))))

(defun constructor-function-form (ctor)
  (let* ((class (ctor-class ctor))
         (proto (class-prototype class))
         (make-instance-methods
          (compute-applicable-methods #'make-instance (list class)))
         (allocate-instance-methods
          (compute-applicable-methods #'allocate-instance (list class)))
         ;; I stared at this in confusion for a while, thinking
         ;; carefully about the possibility of the class prototype not
         ;; being of sufficient discrimiating power, given the
         ;; possibility of EQL-specialized methods on
         ;; INITIALIZE-INSTANCE or SHARED-INITIALIZE.  However, given
         ;; that this is a constructor optimization, the user doesn't
         ;; yet have the instance to create a method with such an EQL
         ;; specializer.
         ;;
         ;; There remains the (theoretical) possibility of someone
         ;; coming along with code of the form
         ;;
         ;; (defmethod initialize-instance :before ((o foo) ...)
         ;;   (eval `(defmethod shared-initialize :before ((o foo) ...) ...)))
         ;;
         ;; but probably we can afford not to worry about this too
         ;; much for now.  -- CSR, 2004-07-12
         (ii-methods
          (compute-applicable-methods #'initialize-instance (list proto)))
         (si-methods
          (compute-applicable-methods #'shared-initialize (list proto t)))
         (setf-svuc-slots-methods
          (loop for slot in (class-slots class)
                collect (compute-applicable-methods
                         #'(setf slot-value-using-class)
                         (list nil class proto slot))))
         (sbuc-slots-methods
          (loop for slot in (class-slots class)
                collect (compute-applicable-methods
                         #'slot-boundp-using-class
                         (list class proto slot)))))
    ;; Cannot initialize these variables earlier because the generic
    ;; functions don't exist when PCL is built.
    (when (null *the-system-si-method*)
      (setq *the-system-si-method*
            (find-method #'shared-initialize
                         () (list *the-class-slot-object* *the-class-t*)))
      (setq *the-system-ii-method*
            (find-method #'initialize-instance
                         () (list *the-class-slot-object*))))
    ;; Note that when there are user-defined applicable methods on
    ;; MAKE-INSTANCE and/or ALLOCATE-INSTANCE, these will show up
    ;; together with the system-defined ones in what
    ;; COMPUTE-APPLICABLE-METHODS returns.
    (if (and (not (structure-class-p class))
             (not (condition-class-p class))
             (null (cdr make-instance-methods))
             (null (cdr allocate-instance-methods))
             (every (lambda (x)
                      (member (slot-definition-allocation x)
                              '(:instance :class)))
                    (class-slots class))
             (null (check-initargs-1
                    class
                    (append
                     (ctor-default-initkeys
                      (ctor-initargs ctor) (class-default-initargs class))
                     (plist-keys (ctor-initargs ctor)))
                    (append ii-methods si-methods) nil nil))
             (not (around-or-nonstandard-primary-method-p
                   ii-methods *the-system-ii-method*))
             (not (around-or-nonstandard-primary-method-p
                   si-methods *the-system-si-method*))
             ;; the instance structure protocol goes through
             ;; slot-value(-using-class) and friends (actually just
             ;; (SETF SLOT-VALUE-USING-CLASS) and
             ;; SLOT-BOUNDP-USING-CLASS), so if there are non-standard
             ;; applicable methods we can't shortcircuit them.
             (every (lambda (x) (= (length x) 1)) setf-svuc-slots-methods)
             (every (lambda (x) (= (length x) 1)) sbuc-slots-methods))
        (optimizing-generator ctor ii-methods si-methods)
        (fallback-generator ctor ii-methods si-methods))))

(defun around-or-nonstandard-primary-method-p
    (methods &optional standard-method)
  (loop with primary-checked-p = nil
        for method in methods
        as qualifiers = (method-qualifiers method)
        when (or (eq :around (car qualifiers))
                 (and (null qualifiers)
                      (not primary-checked-p)
                      (not (null standard-method))
                      (not (eq standard-method method))))
          return t
        when (null qualifiers) do
          (setq primary-checked-p t)))

(defun fallback-generator (ctor ii-methods si-methods)
  (declare (ignore ii-methods si-methods))
  `(lambda ,(make-ctor-parameter-list ctor)
     ;; The CTOR MAKE-INSTANCE optimization only kicks in when the
     ;; first argument to MAKE-INSTANCE is a constant symbol: by
     ;; calling it with a class, as here, we inhibit the optimization,
     ;; so removing the possibility of endless recursion.  -- CSR,
     ;; 2004-07-12
     (make-instance ,(ctor-class ctor) ,@(ctor-initargs ctor))))

(defun optimizing-generator (ctor ii-methods si-methods)
  (multiple-value-bind (locations names body before-method-p)
      (fake-initialization-emf ctor ii-methods si-methods)
    (values
     `(lambda ,(make-ctor-parameter-list ctor)
       (declare #.*optimize-speed*)
       ,(wrap-in-allocate-forms ctor body before-method-p))
     locations
     names)))

;;; Return a form wrapped around BODY that allocates an instance
;;; constructed by CTOR.  BEFORE-METHOD-P set means we have to run
;;; before-methods, in which case we initialize instance slots to
;;; +SLOT-UNBOUND+.  The resulting form binds the local variables
;;; .INSTANCE. to the instance, and .SLOTS. to the instance's slot
;;; vector around BODY.
(defun wrap-in-allocate-forms (ctor body before-method-p)
  (let* ((class (ctor-class ctor))
         (wrapper (class-wrapper class))
         (allocation-function (raw-instance-allocator class))
         (slots-fetcher (slots-fetcher class)))
    (if (eq allocation-function 'allocate-standard-instance)
        `(let ((.instance. (%make-standard-instance nil
                                                    (get-instance-hash-code)))
               (.slots. (make-array
                         ,(layout-length wrapper)
                         ,@(when before-method-p
                             '(:initial-element +slot-unbound+)))))
           (setf (std-instance-wrapper .instance.) ,wrapper)
           (setf (std-instance-slots .instance.) .slots.)
           ,body
           .instance.)
        `(let* ((.instance. (,allocation-function ,wrapper))
                (.slots. (,slots-fetcher .instance.)))
           ,body
           .instance.))))

;;; Return a form for invoking METHOD with arguments from ARGS.  As
;;; can be seen in METHOD-FUNCTION-FROM-FAST-FUNCTION, method
;;; functions look like (LAMBDA (ARGS NEXT-METHODS) ...).  We could
;;; call fast method functions directly here, but benchmarks show that
;;; there's no speed to gain, so lets avoid the hair here.
(defmacro invoke-method (method args)
  `(funcall ,(method-function method) ,args ()))

;;; Return a form that is sort of an effective method comprising all
;;; calls to INITIALIZE-INSTANCE and SHARED-INITIALIZE that would
;;; normally have taken place when calling MAKE-INSTANCE.
(defun fake-initialization-emf (ctor ii-methods si-methods)
  (multiple-value-bind (ii-around ii-before ii-primary ii-after)
      (standard-sort-methods ii-methods)
    (declare (ignore ii-primary))
    (multiple-value-bind (si-around si-before si-primary si-after)
        (standard-sort-methods si-methods)
      (declare (ignore si-primary))
      (aver (and (null ii-around) (null si-around)))
      (let ((initargs (ctor-initargs ctor)))
        (multiple-value-bind (locations names bindings vars defaulting-initargs body)
            (slot-init-forms ctor (or ii-before si-before))
        (values
         locations
         names
         `(let ,bindings
           (declare (ignorable ,@vars))
           (let (,@(when (or ii-before ii-after)
                     `((.ii-args.
                        (list .instance. ,@(quote-plist-keys initargs) ,@defaulting-initargs))))
                 ,@(when (or si-before si-after)
                     `((.si-args.
                        (list .instance. t ,@(quote-plist-keys initargs) ,@defaulting-initargs)))))
            ,@(loop for method in ii-before
                    collect `(invoke-method ,method .ii-args.))
            ,@(loop for method in si-before
                    collect `(invoke-method ,method .si-args.))
            ,@body
            ,@(loop for method in si-after
                    collect `(invoke-method ,method .si-args.))
            ,@(loop for method in ii-after
                    collect `(invoke-method ,method .ii-args.))))
         (or ii-before si-before)))))))

;;; Return four values from APPLICABLE-METHODS: around methods, before
;;; methods, the applicable primary method, and applicable after
;;; methods.  Before and after methods are sorted in the order they
;;; must be called.
(defun standard-sort-methods (applicable-methods)
  (loop for method in applicable-methods
        as qualifiers = (method-qualifiers method)
        if (null qualifiers)
          collect method into primary
        else if (eq :around (car qualifiers))
          collect method into around
        else if (eq :after (car qualifiers))
          collect method into after
        else if (eq :before (car qualifiers))
          collect method into before
        finally
          (return (values around before (first primary) (reverse after)))))

;;; Return as multiple values bindings for default initialization
;;; arguments, variable names, defaulting initargs and a body for
;;; initializing instance and class slots of an object costructed by
;;; CTOR.  The variable .SLOTS. is assumed to bound to the instance's
;;; slot vector.  BEFORE-METHOD-P T means before-methods will be
;;; called, which means that 1) other code will initialize instance
;;; slots to +SLOT-UNBOUND+ before the before-methods are run, and
;;; that we have to check if these before-methods have set slots.
(defun slot-init-forms (ctor before-method-p)
  (let* ((class (ctor-class ctor))
         (initargs (ctor-initargs ctor))
         (initkeys (plist-keys initargs))
         (slot-vector
          (make-array (layout-length (class-wrapper class))
                      :initial-element nil))
         (class-inits ())
         (default-inits ())
         (defaulting-initargs ())
         (default-initargs (class-default-initargs class))
         (initarg-locations
          (compute-initarg-locations
           class (append initkeys (mapcar #'car default-initargs)))))
    (labels ((initarg-locations (initarg)
               (cdr (assoc initarg initarg-locations :test #'eq)))
             (initializedp (location)
               (cond
                 ((consp location)
                  (assoc location class-inits :test #'eq))
                 ((integerp location)
                  (not (null (aref slot-vector location))))
                 (t (bug "Weird location in ~S" 'slot-init-forms))))
             (class-init (location kind val type)
               (aver (consp location))
               (unless (initializedp location)
                 (push (list location kind val type) class-inits)))
             (instance-init (location kind val type)
               (aver (integerp location))
               (unless (initializedp location)
                 (setf (aref slot-vector location) (list kind val type))))
             (default-init-var-name (i)
               (let ((ps #(.d0. .d1. .d2. .d3. .d4. .d5.)))
                 (if (array-in-bounds-p ps i)
                     (aref ps i)
                     (format-symbol *pcl-package* ".D~D." i))))
             (location-var-name (i)
               (let ((ls #(.l0. .l1. .l2. .l3. .l4. .l5.)))
                 (if (array-in-bounds-p ls i)
                     (aref ls i)
                     (format-symbol *pcl-package* ".L~D." i)))))
      ;; Loop over supplied initargs and values and record which
      ;; instance and class slots they initialize.
      (loop for (key value) on initargs by #'cddr
            as kind = (if (constantp value) 'constant 'param)
            as locations = (initarg-locations key)
            do (loop for (location . type) in locations
                     do (if (consp location)
                            (class-init location kind value type)
                            (instance-init location kind value type))))
      ;; Loop over default initargs of the class, recording
      ;; initializations of slots that have not been initialized
      ;; above.  Default initargs which are not in the supplied
      ;; initargs are treated as if they were appended to supplied
      ;; initargs, that is, their values must be evaluated even
      ;; if not actually used for initializing a slot.
      (loop for (key initform initfn) in default-initargs and i from 0
            unless (member key initkeys :test #'eq) do
            (let* ((kind (if (constantp initform) 'constant 'var))
                   (init (if (eq kind 'var) initfn initform)))
              (ecase kind
                (constant
                 (push key defaulting-initargs)
                 (push initform defaulting-initargs))
                (var
                 (push key defaulting-initargs)
                 (push (default-init-var-name i) defaulting-initargs)))
              (when (eq kind 'var)
                (let ((init-var (default-init-var-name i)))
                  (setq init init-var)
                  (push (cons init-var initfn) default-inits)))
              (loop for (location . type) in (initarg-locations key)
                    do (if (consp location)
                           (class-init location kind init type)
                           (instance-init location kind init type)))))
      ;; Loop over all slots of the class, filling in the rest from
      ;; slot initforms.
      (loop for slotd in (class-slots class)
            as location = (slot-definition-location slotd)
            as type = (slot-definition-type slotd)
            as allocation = (slot-definition-allocation slotd)
            as initfn = (slot-definition-initfunction slotd)
            as initform = (slot-definition-initform slotd) do
              (unless (or (eq allocation :class)
                          (null initfn)
                          (initializedp location))
                (if (constantp initform)
                    (instance-init location 'initform initform type)
                    (instance-init location 'initform/initfn initfn type))))
      ;; Generate the forms for initializing instance and class slots.
      (let ((instance-init-forms
             (loop for slot-entry across slot-vector and i from 0
                   as (kind value type) = slot-entry collect
                     (ecase kind
                       ((nil)
                        (unless before-method-p
                          `(setf (clos-slots-ref .slots. ,i) +slot-unbound+)))
                       ((param var)
                        `(setf (clos-slots-ref .slots. ,i)
                               (locally (declare (optimize (safety 3)))
                                 (the ,type ,value))))
                       (initfn
                        `(setf (clos-slots-ref .slots. ,i)
                               (locally (declare (optimize (safety 3)))
                                 (the ,type (funcall ,value)))))
                       (initform/initfn
                        (if before-method-p
                            `(when (eq (clos-slots-ref .slots. ,i)
                                       +slot-unbound+)
                               (setf (clos-slots-ref .slots. ,i)
                                     (locally (declare (optimize (safety 3)))
                                       (the ,type (funcall ,value)))))
                            `(setf (clos-slots-ref .slots. ,i)
                                   (locally (declare (optimize (safety 3)))
                                     (funcall ,value)))))
                       (initform
                        (if before-method-p
                            `(when (eq (clos-slots-ref .slots. ,i)
                                       +slot-unbound+)
                               (setf (clos-slots-ref .slots. ,i)
                                     (locally (declare (optimize (safety 3)))
                                       (the ,type ',(eval value)))))
                            `(setf (clos-slots-ref .slots. ,i)
                                   (locally (declare (optimize (safety 3)))
                                     (the ,type ',(eval value))))))
                       (constant
                        `(setf (clos-slots-ref .slots. ,i)
                               (locally (declare (optimize (safety 3)))
                                 (the ,type ',(eval value)))))))))
        ;; we are not allowed to modify QUOTEd locations, so we can't
        ;; generate code like (setf (cdr ',location) arg).  Instead,
        ;; we have to do (setf (cdr .L0.) arg) and arrange for .L0. to
        ;; be bound to the location.
        (multiple-value-bind (names locations class-init-forms)
            (loop for (location kind value type) in class-inits
                  for i upfrom 0
                  for name = (location-var-name i)
                  collect name into names
                  collect location into locations
                  collect `(setf (cdr ,name)
                                 (locally (declare (optimize (safety 3)))
                                   (the ,type
                                     ,(case kind
                                        (constant `',(eval value))
                                        ((param var) `,value)
                                        (initfn `(funcall ,value))))))
                  into class-init-forms
                  finally (return (values names locations class-init-forms)))
          (multiple-value-bind (vars bindings)
              (loop for (var . initfn) in (nreverse default-inits)
                    collect var into vars
                    collect `(,var (funcall ,initfn)) into bindings
                    finally (return (values vars bindings)))
            (values locations names
                    bindings vars
                    (nreverse defaulting-initargs)
                    `(,@(delete nil instance-init-forms)
                      ,@class-init-forms))))))))

;;; Return an alist of lists (KEY (LOCATION . TYPE-SPECIFIER) ...)
;;; telling, for each key in INITKEYS, which locations the initarg
;;; initializes and the associated type with the location.  CLASS is
;;; the class of the instance being initialized.
(defun compute-initarg-locations (class initkeys)
  (loop with slots = (class-slots class)
        for key in initkeys collect
          (loop for slot in slots
                if (memq key (slot-definition-initargs slot))
                  collect (cons (slot-definition-location slot)
                                (slot-definition-type slot))
                          into locations
                else
                  collect slot into remaining-slots
                finally
                  (setq slots remaining-slots)
                  (return (cons key locations)))))


;;; *******************************
;;; External Entry Points  ********
;;; *******************************

(defun update-ctors (reason &key class name generic-function method)
  (labels ((reset (class &optional ri-cache-p (ctorsp t))
             (when ctorsp
               (dolist (ctor (plist-value class 'ctors))
                 (install-initial-constructor ctor)))
             (when ri-cache-p
               (setf (plist-value class 'ri-initargs) ()))
             (dolist (subclass (class-direct-subclasses class))
               (reset subclass ri-cache-p ctorsp))))
    (ecase reason
      ;; CLASS must have been specified.
      (finalize-inheritance
       (reset class t))
      ;; NAME must have been specified.
      (setf-find-class
       (loop for ctor in *all-ctors*
             when (eq (ctor-class-name ctor) name) do
             (when (ctor-class ctor)
               (reset (ctor-class ctor)))
             (loop-finish)))
      ;; GENERIC-FUNCTION and METHOD must have been specified.
      ((add-method remove-method)
       (flet ((class-of-1st-method-param (method)
                (type-class (first (method-specializers method)))))
         (case (generic-function-name generic-function)
           ((make-instance allocate-instance
             initialize-instance shared-initialize)
            (reset (class-of-1st-method-param method) t t))
           ((reinitialize-instance)
            (reset (class-of-1st-method-param method) t nil))
           (t (when (or (eq (generic-function-name generic-function)
                            'slot-boundp-using-class)
                        (equal (generic-function-name generic-function)
                               '(setf slot-value-using-class)))
                ;; this looks awfully expensive, but given that one
                ;; can specialize on the SLOTD argument, nothing is
                ;; safe.  -- CSR, 2004-07-12
                (reset (find-class 'standard-object))))))))))

(defun precompile-ctors ()
  (dolist (ctor *all-ctors*)
    (when (null (ctor-class ctor))
      (let ((class (find-class (ctor-class-name ctor) nil)))
        (when (and class (class-finalized-p class))
          (install-optimized-constructor ctor))))))

(defun check-ri-initargs (instance initargs)
  (let* ((class (class-of instance))
         (keys (plist-keys initargs))
         (cached (assoc keys (plist-value class 'ri-initargs)
                        :test #'equal))
         (invalid-keys
          (if (consp cached)
              (cdr cached)
              (let ((invalid
                     ;; FIXME: give CHECK-INITARGS-1 and friends a
                     ;; more mnemonic name and (possibly) a nicer,
                     ;; more orthogonal interface.
                     (check-initargs-1
                      class initargs
                      (list (list* 'reinitialize-instance instance initargs)
                            (list* 'shared-initialize instance nil initargs))
                      t nil)))
                (setf (plist-value class 'ri-initargs)
                      (acons keys invalid cached))
                invalid))))
    (when invalid-keys
      (error 'initarg-error :class class :initargs invalid-keys))))

;;; end of ctor.lisp
