(in-package :sb-posix)

(define-designator filename c-string
  (pathname
   (sb-ext:native-namestring (translate-logical-pathname filename)))
  (string filename))

(define-designator file-descriptor (integer 32)
  (file-stream (sb-sys:fd-stream-fd file-descriptor))
  (fixnum file-descriptor))

(define-designator sap-or-nil sb-sys:system-area-pointer
  (null (sb-sys:int-sap 0))
  (sb-sys:system-area-pointer sap-or-nil))

(define-designator alien-pointer-to-anything-or-nil (* t)
  (null (sb-alien:sap-alien (sb-sys:int-sap 0) (* t)))
  ((alien (* t)) alien-pointer-to-anything-or-nil))

(defun lisp-for-c-symbol (s)
  (let ((root (if (eql #\_ (char s 0)) (subseq s 1) s)))
    (intern (substitute #\- #\_ (string-upcase root)) :sb-posix)))

(defmacro define-call-internally (lisp-name c-name return-type error-predicate
                                  &rest arguments)
  (if (sb-sys:find-foreign-symbol-address c-name)
      `(progn
        (declaim (inline ,lisp-name))
        (defun ,lisp-name ,(mapcar #'car arguments)
          (let ((r (alien-funcall
                    (extern-alien
                     ,c-name
                     (function ,return-type
                               ,@(mapcar
                                  (lambda (x)
                                    (gethash (cadr x)
                                             *designator-types*
                                             (cadr x)))
                                  arguments)))
                    ,@(mapcar (lambda (x)
                                (if (nth-value 1
                                               (gethash (cadr x)
                                                        *designator-types*))
                                    `(,(intern (symbol-name (cadr x))
                                               :sb-posix)
                                      ,(car x))
                                    (car x)))
                              arguments))))
            (if (,error-predicate r) (syscall-error) r))))
      `(sb-int:style-warn "Didn't find definition for ~S" ,c-name)))

(defmacro define-call (name return-type error-predicate &rest arguments)
  (let ((lisp-name (lisp-for-c-symbol name)))
    `(progn
       (export ',lisp-name :sb-posix)
       (define-call-internally ,lisp-name
           ,name
         ,return-type
         ,error-predicate
         ,@arguments))))

(defmacro define-entry-point (name arglist &body body)
  (let ((lisp-name (lisp-for-c-symbol name)))
    `(progn
      (export ',lisp-name :sb-posix)
      (declaim (inline ,lisp-name))
      (defun ,lisp-name ,arglist
        ,@body))))
