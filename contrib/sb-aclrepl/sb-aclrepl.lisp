;;;; Replicate much of the ACL toplevel functionality in SBCL. Mostly
;;;; this is portable code, but fundamentally it all hangs from a few
;;;; SBCL-specific hooks like SB-INT:*REPL-READ-FUN* and
;;;; SB-INT:*REPL-PROMPT-FUN*.
;;;;
;;;; The documentation, which may or may not apply in its entirety at
;;;; any given time, for this functionality is on the ACL website:
;;;;   <http://www.franz.com/support/documentation/6.2/doc/top-level.htm>.

(cl:defpackage :sb-aclrepl
  (:use :cl :sb-ext)
  ;; FIXME: should we be exporting anything else?
  (:export #:*prompt* #:*exit-on-eof* #:*max-history*
	   #:*use-short-package-name* #:*command-char*
	   #:alias))

(cl:in-package :sb-aclrepl)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *default-prompt* "~A(~d): "
    "The default prompt."))
(defparameter *prompt* #.*default-prompt*
  "The current prompt string or formatter function.")
(defparameter *use-short-package-name* t
  "when T, use the shortnest package nickname in a prompt")
(defparameter *dir-stack* nil
  "The top-level directory stack")
(defparameter *command-char* #\:
  "Prefix character for a top-level command")
(defvar *max-history* 24
  "Maximum number of history commands to remember")
(defvar *exit-on-eof* t
  "If T, then exit when the EOF character is entered.")
(defparameter *history* nil
  "History list")
(defparameter *cmd-number* 0
  "Number of the current command")

(defstruct user-cmd
  (input nil) ; input, maybe a string or form
  (func nil)  ; cmd func entered, overloaded (:eof :null-cmd))
  (args nil)  ; args for cmd func
  (hnum nil)) ; history number

(defvar *eof-marker* (cons :eof nil))
(defvar *eof-cmd* (make-user-cmd :func :eof))
(defvar *null-cmd* (make-user-cmd :func :null-cmd))

(defun prompt-package-name ()
  (if *use-short-package-name*
      (car (sort (append
		  (package-nicknames cl:*package*)
		  (list (package-name cl:*package*)))
		 #'string-lessp))
      (package-name cl:*package*)))

(defun read-cmd (input-stream)
  (flet ((parse-args (parsing args-string)
	   (case parsing
	     (:string
	      (if (zerop (length args-string))
		  nil
		  (list args-string)))
 	     (t
	      (let ((string-stream (make-string-input-stream args-string)))
		(loop as arg = (read string-stream nil *eof-marker*)
		      until (eq arg *eof-marker*)
		      collect arg))))))
    (let ((next-char (peek-char-non-whitespace input-stream)))
      (cond
	((eql next-char *command-char*)
	 (let* ((line (string-trim-whitespace (read-line input-stream)))
		(first-space-pos (position #\space line))
		(cmd-string (subseq line 1 first-space-pos))
		(cmd-args-string
		 (if first-space-pos
		     (string-trim-whitespace (subseq line first-space-pos))
		     "")))
	   (if (numberp (read-from-string cmd-string))
	       (get-history (read-from-string cmd-string))
	       (let ((cmd-entry (find-cmd cmd-string)))
		 (if cmd-entry
		     (make-user-cmd :func (cmd-table-entry-func cmd-entry)
				    :input line
				    :args (parse-args
					   (cmd-table-entry-parsing cmd-entry)
					   cmd-args-string)
				    :hnum *cmd-number*)
		     (progn
		       (format t "Unknown top-level command: ~s.~%" cmd-string)
		       (format t "Type `:help' for the list of commands.~%")
		       *null-cmd*
		       ))))))
	((eql next-char #\newline)
	 (read-char input-stream)
	 *null-cmd*)
      (t
       (let ((form (read input-stream nil *eof-marker*)))
	 (if (eq form *eof-marker*)
	     *eof-cmd*
	     (make-user-cmd :input form :func nil :hnum *cmd-number*))))))))
 
(defparameter *cmd-table-hash*
  (make-hash-table :size 30 :test #'equal))

;;; cmd table entry
(defstruct cmd-table-entry
  (name nil) ; name of command
  (func nil) ; function handler
  (desc nil) ; short description
  (parsing nil) ; (:string :case-sensitive nil)
  (group nil)) ; command group (:cmd or :alias)
  
(defun make-cte (name-param func desc parsing group)
  (let ((name (etypecase name-param
		(string
		 name-param)
		(symbol
		 (string-downcase (write-to-string name-param))))))
    (make-cmd-table-entry :name name :func func :desc desc
			  :parsing parsing :group group)))

(defun %add-entry (cmd &optional abbr-len)
  (let* ((name (cmd-table-entry-name cmd))
	 (alen (if abbr-len
		   abbr-len
		   (length name))))
    (dotimes (i (length name))
      (when (>= i (1- alen))
	(setf (gethash (subseq name 0 (1+ i)) *cmd-table-hash*)
	      cmd)))))

(defun add-cmd-table-entry (cmd-string abbr-len func-name desc parsing)
  (%add-entry
   (make-cte cmd-string (symbol-function func-name) desc parsing :cmd)
   abbr-len))
   
(defun find-cmd (cmdstr)
  (gethash (string-downcase cmdstr) *cmd-table-hash*))

(defun user-cmd= (c1 c2)
  "Returns T if two user commands are equal"
  (if (or (not (user-cmd-p c1)) (not (user-cmd-p c2)))
      (progn
	(format t "Error: ~s or ~s is not a user-cmd" c1 c2)
	nil)
      (and (eq (user-cmd-func c1) (user-cmd-func c2))
	   (equal (user-cmd-args c1) (user-cmd-args c2))
	   (equal (user-cmd-input c1) (user-cmd-input c2)))))

(defun add-to-history (cmd)
  (unless (and *history* (user-cmd= cmd (car *history*)))
    (when (>= (length *history*) *max-history*)
      (setq *history* (nbutlast *history* (+ (length *history*) *max-history* 1))))
    (push cmd *history*)))

(defun get-history (n)
  (let ((cmd (find n *history* :key #'user-cmd-hnum :test #'eql)))
    (if cmd
	cmd
	(progn
	  (format t "Input numbered %d is not on the history list.." n)
	  *null-cmd*))))

(defun get-cmd-doc-list (&optional (group :cmd))
  "Return list of all commands"
  (let ((cmds '()))
    (maphash (lambda (k v)
	       (when (and
		      (eql (length k) (length (cmd-table-entry-name v)))
		      (eq (cmd-table-entry-group v) group))
		 (push (list k (cmd-table-entry-desc v)) cmds)))
	     *cmd-table-hash*)
    (sort cmds #'string-lessp :key #'car)))

(defun cd-cmd (&optional string-dir)
  (cond
    ((or (zerop (length string-dir))
	 (string= string-dir "~"))
     (setf cl:*default-pathname-defaults* (user-homedir-pathname)))
    (t
     (let ((new (truename string-dir)))
       (when (pathnamep new)
	 (setf cl:*default-pathname-defaults* new)))))
  (format t "~A~%" (namestring cl:*default-pathname-defaults*))
  (values))

(defun pwd-cmd ()
  (format t "Lisp's current working directory is ~s.~%"
	  (namestring cl:*default-pathname-defaults*))
  (values))

(defun trace-cmd (&rest args)
  (if args
      (format t "~A~%" (eval (apply #'sb-debug::expand-trace args)))
      (format t "~A~%" (sb-debug::%list-traced-funs)))
  (values))

(defun untrace-cmd (&rest args)
  (if args
      (format t "~A~%"
	      (eval
	       (sb-int:collect ((res))
		(let ((current args))
		  (loop
		   (unless current (return))
		   (let ((name (pop current)))
		     (res (if (eq name :function)
			      `(sb-debug::untrace-1 ,(pop current))
			      `(sb-debug::untrace-1 ',name))))))
		`(progn ,@(res) t))))
      (format t "~A~%" (eval (sb-debug::untrace-all))))
  (values))

(defun exit-cmd (&optional (status 0))
  (quit :unix-status status)
  (values))

(defun package-cmd (&optional pkg)
  (cond
    ((null pkg)
     (format t "The ~A package is current.~%" (package-name cl:*package*)))
    ((null (find-package (write-to-string pkg)))
     (format t "Unknown package: ~A.~%" pkg))
    (t
     (setf cl:*package* (find-package (write-to-string pkg)))))
  (values))

(defun string-to-list-skip-spaces (str)
  "Return a list of strings, delimited by spaces, skipping spaces."
  (loop for i = 0 then (1+ j)
	as j = (position #\space str :start i)
	when (not (char= (char str i) #\space))
	collect (subseq str i j) while j))

(defun ld-cmd (string-files)
  (dolist (arg (string-to-list-skip-spaces string-files))
    (format t "loading ~a~%" arg)
    (load arg))
  (values))

(defun cf-cmd (string-files)
  (dolist (arg (string-to-list-skip-spaces string-files))
    (compile-file arg))
  (values))

(defun >-num (x y)
  "Return if x and y are numbers, and x > y"
  (and (numberp x) (numberp y) (> x y)))

(defun newer-file-p (file1 file2)
  "Is file1 newer (written later than) file2?"
  (>-num (if (probe-file file1) (file-write-date file1))
	 (if (probe-file file2) (file-write-date file2))))

(defun compile-file-as-needed (src-path)
  "Compiles a file if needed, returns path."
  (let ((dest-path (compile-file-pathname src-path)))
    (when (or (not (probe-file dest-path))
	      (newer-file-p src-path dest-path))
      (ensure-directories-exist dest-path)
      (compile-file src-path :output-file dest-path))
    dest-path))

;;;; implementation of commands

(defun cload-cmd (string-files)
  (dolist (arg (string-to-list-skip-spaces string-files))
    (load (compile-file-as-needed arg)))
  (values))

(defun inspect-cmd (arg)
  (eval `(inspect ,arg))
  (values))

(defun describe-cmd (&rest args)
  (dolist (arg args)
    (eval `(describe ,arg)))
  (values))

(defun macroexpand-cmd (arg)
  (pprint (macroexpand arg))
  (values))

(defun history-cmd ()
  (let ((n (length *history*)))
    (declare (fixnum n))
    (dotimes (i n)
      (declare (fixnum i))
      (let ((hist (nth (- n i 1) *history*)))
	(format t "~3A ~A~%" (user-cmd-hnum hist) (user-cmd-input hist)))))
  (values))

(defun help-cmd (&optional cmd)
  (cond
    (cmd
     (let ((cmd-entry (find-cmd cmd)))
       (if cmd-entry
	   (format t "Documentation for ~A: ~A~%"
		   (cmd-table-entry-name cmd-entry)
		   (cmd-table-entry-desc cmd-entry)))))
    (t
     (format t "~13A ~a~%" "Command" "Description")
     (format t "------------- -------------~%")
     (dolist (doc-entry (get-cmd-doc-list :cmd))
       (format t "~13A ~A~%" (car doc-entry) (cadr doc-entry)))))
  (values))

(defun alias-cmd ()
  (let ((doc-entries (get-cmd-doc-list :alias)))
    (typecase doc-entries
      (cons
       (format t "~13A ~a~%" "Alias" "Description")
       (format t "------------- -------------~%")
       (dolist (doc-entry doc-entries)
	 (format t "~13A ~A~%" (car doc-entry) (cadr doc-entry))))
      (t
       (format t "No aliases are defined~%"))))
  (values))

(defun shell-cmd (string-arg)
  (sb-ext:run-program "/bin/sh" (list "-c" string-arg)
		      :input nil :output *trace-output*)
  (values))

(defun pushd-cmd (string-arg)
  (push string-arg *dir-stack*)
  (cd-cmd string-arg)
  (values))

(defun popd-cmd ()
  (if *dir-stack*
      (let ((dir (pop *dir-stack*)))
	(cd-cmd dir))
      (format t "No directory on stack to pop.~%"))
  (values))

(defun dirs-cmd ()
  (dolist (dir *dir-stack*)
    (format t "~a~%" dir))
  (values))

;;;; dispatch table for commands

(let ((cmd-table
       '(("aliases" 3 alias-cmd "show aliases")
	 ("cd" 2 cd-cmd "change default diretory" :parsing :string)
	 ("ld" 2 ld-cmd "load a file" :parsing :string)
	 ("cf" 2 cf-cmd "compile file" :parsing :string)
	 ("cload" 2 cload-cmd "compile if needed and load file"
	  :parsing :string)
	 ("describe" 2 describe-cmd "describe an object")
	 ("macroexpand" 2 macroexpand-cmd "macroexpand an expression")
	 ("package" 2 package-cmd "change current package")
	 ("exit" 2 exit-cmd "exit sbcl")
	 ("help" 2 help-cmd "print this help")
	 ("history" 3 history-cmd "print the recent history")
	 ("inspect" 2 inspect-cmd "inspect an object")
	 ("pwd" 3 pwd-cmd "print current directory")
	 ("pushd" 2 pushd-cmd "push directory on stack" :parsing :string)
	 ("popd" 2 popd-cmd "pop directory from stack")
	 ("trace" 2 trace-cmd "trace a function")
	 ("untrace" 4 untrace-cmd "untrace a function")
	 ("dirs" 2 dirs-cmd "show directory stack")
	 ("shell" 2 shell-cmd "execute a shell cmd" :parsing :string))))
  (dolist (cmd cmd-table)
    (destructuring-bind (cmd-string abbr-len func-name desc &key parsing) cmd
      (add-cmd-table-entry cmd-string abbr-len func-name desc parsing))))

;;;; machinery for aliases

(defsetf alias (name) (user-func)
  `(progn
    (%add-entry
     (make-cte (quote ,name) ,user-func "" nil :alias))
    (quote ,name)))

(defmacro alias (name-param args &rest body)
  (let ((parsing nil)
	(desc "")
	(abbr-index nil)
	(name (if (atom name-param)
		  name-param
		  (car name-param))))
    (when (consp name-param)
     (dolist (param (cdr name-param))
	(cond
	  ((or
	    (eq param :case-sensitive)
	    (eq param :string))
	   (setq parsing param))
	  ((stringp param)
	   (setq desc param))
	  ((numberp param)
	   (setq abbr-index param)))))
    `(progn
      (%add-entry
       (make-cte (quote ,name) (lambda ,args ,@body) ,desc ,parsing :alias)
       ,abbr-index)
      ,name)))
       
    
(defun remove-alias (&rest aliases)
  (let ((keys '())
	(remove-all (not (null (find :all aliases)))))
    (unless remove-all  ;; ensure all alias are strings
      (setq aliases
	    (loop for alias in aliases
		  collect
		  (etypecase alias
		    (string
		     alias)
		    (symbol
		     (symbol-name alias))))))
    (maphash
     (lambda (key cmd)
       (when (eq (cmd-table-entry-group cmd) :alias)
	 (if remove-all
	     (push key keys)
	     (when (some
		    (lambda (alias)
		      (let ((klen (length key)))
			(and (>= (length alias) klen)
			     (string-equal (subseq alias 0 klen)
					   (subseq key 0 klen)))))
		    aliases)
	       (push key keys)))))
     *cmd-table-hash*)
    (dolist (key keys)
      (remhash key *cmd-table-hash*))
    keys))

;;;; low-level reading/parsing functions

;;; Skip white space (but not #\NEWLINE), and peek at the next
;;; character.
(defun peek-char-non-whitespace (&optional stream)
  (do ((char (peek-char nil stream nil *eof-marker*)
	     (peek-char nil stream nil *eof-marker*)))
      ((not (whitespace-char-not-newline-p char)) char)
    (read-char stream)))

(defun string-trim-whitespace (str)
  (string-trim '(#\space #\tab #\return)
	       str))

(defun whitespace-char-not-newline-p (x)
  (and (characterp x)
       (or (char= x #\space)
	   (char= x #\tab)
	   (char= x #\return))))

;;;; linking into SBCL hooks

(defun repl-prompt-fun (stream)
  (incf *cmd-number*)
  (fresh-line stream)
  (if (functionp *prompt*)
      (write-string (funcall *prompt* (prompt-package-name) *cmd-number*)
		    stream)
      (format stream *prompt* (prompt-package-name) *cmd-number*)))
  
;;; If USER-CMD is to be processed as something magical (not an
;;; ordinary eval-and-print-me form) then do so and return non-NIL.
(defun execute-as-acl-magic (user-cmd input-stream output-stream)
  ;; kludgity kludge kludge kludge ("and then a miracle occurs")
  ;;
  ;; This is a really sloppy job of smashing KMR's code (what he
  ;; called DEFUN REP-ONE-CMD) onto DB's hook ideas, not even doing
  ;; the basics like passing INPUT-STREAM and OUTPUT-STREAM into the
  ;; KMR code. A real implementation might want to do rather better.
  (cond ((eq user-cmd *eof-cmd*)
	 (decf *cmd-number*)
	 (when *exit-on-eof*
	   (quit))
	 (format t "EOF~%")
	 t) ; Yup, we knew how to handle that.
	((eq user-cmd *null-cmd*)
	 (decf *cmd-number*)
	 t) ; Yup.
	((functionp (user-cmd-func user-cmd))
	 (apply (user-cmd-func user-cmd) (user-cmd-args user-cmd))
	 (add-to-history user-cmd)
	 (fresh-line)
	 t) ; Ayup.
	(t
	 (add-to-history user-cmd)
	 nil))) ; nope, not in my job description

(defun repl-read-form-fun (input-stream output-stream)
  ;; Pick off all the leading ACL magic commands, then return a normal
  ;; Lisp form.
  (loop for user-cmd = (read-cmd input-stream) do
	(if (execute-as-acl-magic user-cmd input-stream output-stream)
	    (progn
	      (repl-prompt-fun output-stream)
	      (force-output output-stream))
	    (return (user-cmd-input user-cmd)))))

(setf sb-int:*repl-prompt-fun* #'repl-prompt-fun
      sb-int:*repl-read-form-fun* #'repl-read-form-fun)
