(in-package "SB!EVAL")

(defparameter *eval-level* -1)
(defparameter *eval-calls* 0)
(defparameter *eval-verbose* nil)
(defparameter *use-old-eval* nil)

(defun !full-eval-cold-init ()
  (setf *eval-level* -1
        *eval-calls* 0
        *eval-verbose* nil
        *use-old-eval* nil))

;; !defstruct-with-alternate-metaclass is unslammable and the
;; RECOMPILE restart doesn't work on it.  This is the main reason why
;; this stuff is split out into its own file.  Also, it lets the
;; INTERPRETED-FUNCTION type be declared before it is used in
;; compiler/main.
(sb!kernel::!defstruct-with-alternate-metaclass 
 interpreted-function
 :slot-names (name lambda-list env declarations documentation body)
 :boa-constructor %make-interpreted-function
 :superclass-name sb!kernel:funcallable-instance
 :metaclass-name sb!kernel:funcallable-structure-classoid
 :metaclass-constructor sb!kernel:make-funcallable-structure-classoid
 :dd-type sb!kernel:funcallable-structure
 :runtime-type-checks-p nil
 :inheritance-type :funcallable-instance)

(defun make-interpreted-function 
    (&key name lambda-list env declarations documentation body)
  (let ((function (%make-interpreted-function
                   name lambda-list env declarations documentation body)))
    (setf (sb!kernel:funcallable-instance-fun function)
          #'(sb!kernel:instance-lambda (&rest args)
              (interpreted-apply function args)))
    function))

(defun interpreted-function-p (function)
  (typep function 'interpreted-function))

(sb!int:def!method print-object ((obj interpreted-function) stream)
  (print-unreadable-object (obj stream
                            :identity (not (interpreted-function-name obj)))
    (format stream "~A ~A" '#:interpreted-function 
            (interpreted-function-name obj))))
