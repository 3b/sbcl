;;; -*-  Lisp -*-

(cl:defpackage #:sb-rotate-byte-system 
  (:use #:asdf #:cl))
(cl:in-package #:sb-rotate-byte-system)

(defsystem sb-rotate-byte
  :version "0.1"
  :components ((:file "package")
	       (:file "compiler" :depends-on ("package"))
	       (:module "vm"
			:depends-on ("compiler")
			:components ((:file "x86-vm"
					    :in-order-to ((compile-op (feature :x86)))))
			:pathname #.(make-pathname :directory '(:relative))
			:if-component-dep-fails :ignore)
	       (:file "rotate-byte" :depends-on ("compiler"))))
