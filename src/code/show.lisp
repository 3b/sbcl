;;;; some stuff for displaying information for debugging/experimenting
;;;; with the system, mostly conditionalized with #!+SB-SHOW

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!INT")

;;;; various SB-SHOW-dependent forms
;;;;
;;;; In general, macros named /FOO
;;;;   * are for debugging/tracing
;;;;   * expand into nothing unless :SB-SHOW is in the target
;;;;     features list
;;;; Often, they also do nothing at runtime if */SHOW* is NIL, but
;;;; this is not always true for some very-low-level ones.
;;;;
;;;; (I follow the "/FOO for debugging/tracing expressions" naming
;;;; rule and several other naming conventions in all my Lisp
;;;; programming when possible, and then set Emacs to display comments
;;;; in one shade of blue, tracing expressions in another shade of
;;;; blue, and declarations and assertions in a yellowish shade, so
;;;; that it's easy to separate them from the "real code" which
;;;; actually does the work of the program. -- WHN 2001-05-07)

;;; Set this to NIL to suppress output from /SHOW-related forms.
#!+sb-show (defvar */show* t)

;;; shorthand for a common idiom in output statements used in debugging:
;;; (/SHOW "Case 2:" X Y) becomes a pretty-printed version of
;;; (FORMAT .. "~&/Case 2: X=~S Y=~S~%" X Y).
(defmacro /show (&rest xlist)
  #!-sb-show (declare (ignore xlist))
  #!+sb-show
  (flet (;; Is X something we want to just show literally by itself?
	 ;; (instead of showing it as NAME=VALUE)
	 (literal-p (x) (or (stringp x) (numberp x))))
    ;; We build a FORMAT statement out of what we find in XLIST.
    (let ((format-stream (make-string-output-stream)) ; string arg to FORMAT
	  (format-reverse-rest)	 ; reversed &REST argument to FORMAT
	  (first-p t))		  ; first pass through loop?
      (write-string "~&~<~;/" format-stream)
      (dolist (x xlist)
	(if first-p
	    (setq first-p nil)
	    (write-string #+ansi-cl " ~_"
			  #-ansi-cl " " ; for CLISP (CLTL1-ish)
			  format-stream))
	(if (literal-p x)
	    (princ x format-stream)
	    (progn (let ((*print-pretty* nil))
		     (format format-stream "~S=~~S" x))
		   (push x format-reverse-rest))))
      (write-string "~;~:>~%" format-stream)
      (let ((format-string (get-output-stream-string format-stream))
	    (format-rest (reverse format-reverse-rest)))
	`(locally
	   (declare (optimize (speed 1) (space 2) (safety 3)))
	   ;; For /SHOW to work, we need *TRACE-OUTPUT* of course, but
	   ;; also *READTABLE* (used by the printer to decide what
	   ;; case convention to use when outputting symbols).
	   (if (every #'boundp '(*trace-output* *readtable*))
	       (when */show*
		 (format *trace-output*
			 ,format-string
			 #+ansi-cl (list ,@format-rest)
			 #-ansi-cl ,@format-rest)) ; for CLISP (CLTL1-ish)
	       #+sb-xc-host (error "can't /SHOW, unbound vars")
	       ;; We end up in this situation when we execute /SHOW
	       ;; too early in cold init. That happens often enough
	       ;; that it's really annoying for it to cause a hard
	       ;; failure -- which at that point is hard to recover
	       ;; from -- instead of just diagnostic output.
	       #-sb-xc-host (sb!sys:%primitive
			     print
			     "/(can't /SHOW, unbound vars)"))
	   (values))))))

;;; a disabled-at-compile-time /SHOW, implemented as a macro instead
;;; of a function so that leaving occasionally-useful /SHOWs in place
;;; but disabled incurs no run-time overhead and works even when the
;;; arguments can't be evaluated (e.g. because they're only meaningful
;;; in a debugging version of the system, or just due to bit rot..)
(defmacro /noshow (&rest rest)
  (declare (ignore rest)))

;;; like /SHOW, except displaying values in hexadecimal
(defmacro /xhow (&rest rest)
  `(let ((*print-base* 16))
     (/show ,@rest)))
(defmacro /noxhow (&rest rest)
  (declare (ignore rest)))

;;; a trivial version of /SHOW which only prints a constant string,
;;; implemented at a sufficiently low level that it can be used early
;;; in cold init
;;;
;;; Unlike the other /SHOW-related functions, this one doesn't test
;;; */SHOW* at runtime, because messing with special variables early
;;; in cold load is too much trouble to be worth it.
(defmacro /show0 (&rest string-designators)
  ;; We can't use inline MAPCAR here because, at least in 0.6.11.x,
  ;; this code gets compiled before DO-ANONYMOUS is defined.
  (declare (notinline mapcar))
  (let ((s (apply #'concatenate
		  'simple-string
		  (mapcar #'string string-designators))))
    (declare (ignorable s)) ; (for when #!-SB-SHOW)
    #+sb-xc-host `(/show ,s)
    #-sb-xc-host `(progn
		    #!+sb-show
		    (sb!sys:%primitive print
				       ,(concatenate 'simple-string "/" s)))))
(defmacro /noshow0 (&rest rest)
  (declare (ignore rest)))

;;; low-level display of a string, works even early in cold init
(defmacro /primitive-print (thing)
  (declare (ignorable thing)) ; (for when #!-SB-SHOW)
  #!+sb-show
  (progn
    #+sb-xc-host `(/show "(/primitive-print)" ,thing)
    #-sb-xc-host `(sb!sys:%primitive print (the simple-string ,thing))))

;;; low-level display of a system word, works even early in cold init
(defmacro /hexstr (thing)
  (declare (ignorable thing)) ; (for when #!-SB-SHOW)
  #!+sb-show
  (progn
    #+sb-xc-host `(/show "(/hexstr)" ,thing)
    #-sb-xc-host `(sb!sys:%primitive print (hexstr ,thing))))

(defmacro /nohexstr (thing)
  (declare (ignore thing)))

(/show0 "done with show.lisp")
