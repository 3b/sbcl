;;;; character functions
;;;;
;;;; This implementation assumes the use of ASCII codes and the
;;;; specific character formats used in SBCL (and its ancestor, CMU
;;;; CL). It is optimized for performance rather than for portability
;;;; and elegance, and may have to be rewritten if the character
;;;; representation is changed.
;;;;
;;;; KLUDGE: As of sbcl-0.6.11.25, at least, the ASCII-dependence is
;;;; not confined to this file. E.g. there are DEFTRANSFORMs in
;;;; srctran.lisp for CHAR-UPCASE, CHAR-EQUAL, and CHAR-DOWNCASE, and
;;;; they assume ASCII. -- WHN 2001-03-25

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; We compile some trivial character operations via inline expansion.
#!-sb-fluid
(declaim (inline standard-char-p graphic-char-p alpha-char-p
		 upper-case-p lower-case-p both-case-p alphanumericp
		 char-int))
(declaim (maybe-inline digit-char-p digit-weight))

(deftype char-code ()
  `(integer 0 (,char-code-limit)))

(defvar *character-database*)

(macrolet ((frob ()
             (with-open-file (stream (merge-pathnames
                                      (make-pathname
                                       :directory
                                       '(:relative :up :up "output")
                                       :name "ucd"
                                       :type "dat")
                                      sb!xc:*compile-file-pathname*)
                                     :direction :input
                                     :element-type '(unsigned-byte 8))
               (let* ((length (file-length stream))
                      (array (make-array length
                                         :element-type '(unsigned-byte 8))))
                 (read-sequence array stream)
                 `(defun !character-database-cold-init ()
		    (setq *character-database* ',array))))))
  (frob))
#+sb-xc-host (!character-database-cold-init)

;;; This is the alist of (character-name . character) for characters
;;; with long names. The first name in this list for a given character
;;; is used on typeout and is the preferred form for input.
(macrolet ((frob (char-names-list)
	     (collect ((results))
	       (dolist (code char-names-list)
		 (destructuring-bind (ccode names) code
		   (dolist (name names)
		     (results (cons name ccode)))))
	       `(defparameter *char-name-alist*
                 (mapcar (lambda (x) (cons (car x) (code-char (cdr x))))
                         ',(results))))))
  ;; Note: The *** markers here indicate character names which are
  ;; required by the ANSI specification of #'CHAR-NAME. For the others,
  ;; we prefer the ASCII standard name.
  (frob ((#x00 ("Nul" "Null" "^@"))
	 (#x01 ("Soh" "^a"))
	 (#x02 ("Stx" "^b"))
	 (#x03 ("Etx" "^c"))
	 (#x04 ("Eot" "^d"))
	 (#x05 ("Enq" "^e"))
	 (#x06 ("Ack" "^f"))
	 (#x07 ("Bel" "Bell" "^g"))
	 (#x08 ("Backspace" "^h" "Bs")) ; *** See Note above.
	 (#x09 ("Tab" "^i" "Ht")) ; *** See Note above.
	 (#x0A ("Newline" "Linefeed" "^j" "Lf" "Nl" )) ; *** See Note above.
	 (#x0B ("Vt" "^k"))
	 (#x0C ("Page" "^l" "Form" "Formfeed" "Ff" "Np")) ; *** See Note above.
	 (#x0D ("Return" "^m" "Cr")) ; *** See Note above.
	 (#x0E ("So" "^n"))
	 (#x0F ("Si" "^o"))
	 (#x10 ("Dle" "^p"))
	 (#x11 ("Dc1" "^q"))
	 (#x12 ("Dc2" "^r"))
	 (#x13 ("Dc3" "^s"))
	 (#x14 ("Dc4" "^t"))
	 (#x15 ("Nak" "^u"))
	 (#x16 ("Syn" "^v"))
	 (#x17 ("Etb" "^w"))
	 (#x18 ("Can" "^x"))
	 (#x19 ("Em" "^y"))
	 (#x1A ("Sub" "^z"))
	 (#x1B ("Esc" "Escape" "^[" "Altmode" "Alt"))
	 (#x1C ("Fs" "^\\"))
	 (#x1D ("Gs" "^]"))
	 (#x1E ("Rs" "^^"))
	 (#x1F ("Us" "^_"))
	 (#x20 ("Space" "Sp")) ; *** See Note above.
	 (#x7f ("Rubout" "Delete" "Del"))
	 (#x80 ("C80"))
	 (#x81 ("C81"))
	 (#x82 ("Break-Permitted"))
	 (#x83 ("No-Break-Permitted"))
	 (#x84 ("C84"))
	 (#x85 ("Next-Line"))
	 (#x86 ("Start-Selected-Area"))
	 (#x87 ("End-Selected-Area"))
	 (#x88 ("Character-Tabulation-Set"))
	 (#x89 ("Character-Tabulation-With-Justification"))
	 (#x8A ("Line-Tabulation-Set"))
	 (#x8B ("Partial-Line-Forward"))
	 (#x8C ("Partial-Line-Backward"))
	 (#x8D ("Reverse-Linefeed"))
	 (#x8E ("Single-Shift-Two"))
	 (#x8F ("Single-Shift-Three"))
	 (#x90 ("Device-Control-String"))
	 (#x91 ("Private-Use-One"))
	 (#x92 ("Private-Use-Two"))
	 (#x93 ("Set-Transmit-State"))
	 (#x94 ("Cancel-Character"))
	 (#x95 ("Message-Waiting"))
	 (#x96 ("Start-Guarded-Area"))
	 (#x97 ("End-Guarded-Area"))
	 (#x98 ("Start-String"))
	 (#x99 ("C99"))
	 (#x9A ("Single-Character-Introducer"))
	 (#x9B ("Control-Sequence-Introducer"))
	 (#x9C ("String-Terminator"))
	 (#x9D ("Operating-System-Command"))
	 (#x9E ("Privacy-Message"))
	 (#x9F ("Application-Program-Command"))))) ; *** See Note above.

;;;; accessor functions

;; (* 8 186) => 1488
;; (+ 1488 (ash #x110000 -8)) => 5840
(defun ucd-index (char)
  (let* ((cp (char-code char))
	 (cp-high (ash cp -8))
	 (page (aref *character-database* (+ 1488 cp-high))))
    (+ 5840 (ash page 10) (ash (ldb (byte 8 0) cp) 2))))

(defun ucd-value-0 (char)
  (aref *character-database* (ucd-index char)))

(defun ucd-value-1 (char)
  (let ((index (ucd-index char)))
    (dpb (aref *character-database* (+ index 3))
	 (byte 8 16)
	 (dpb (aref *character-database* (+ index 2))
	      (byte 8 8)
	      (aref *character-database* (1+ index))))))

(defun ucd-general-category (char)
  (aref *character-database* (* 8 (ucd-value-0 char))))

(defun ucd-decimal-digit (char)
  (let ((decimal-digit (aref *character-database*
			     (+ 3 (* 8 (ucd-value-0 char))))))
    (when (< decimal-digit 10)
      decimal-digit)))

(defun char-code (char)
  #!+sb-doc
  "Return the integer code of CHAR."
  ;; FIXME: do we actually need this?
  (etypecase char
    (character (char-code (truly-the character char)))))

(defun char-int (char)
  #!+sb-doc
  "Return the integer code of CHAR. (In SBCL this is the same as CHAR-CODE, as
   there are no character bits or fonts.)"
  (char-code char))

(defun code-char (code)
  #!+sb-doc
  "Return the character with the code CODE."
  (code-char code))

(defun character (object)
  #!+sb-doc
  "Coerce OBJECT into a CHARACTER if possible. Legal inputs are 
  characters, strings and symbols of length 1."
  (flet ((do-error (control args)
	   (error 'simple-type-error
		  :datum object
		  ;;?? how to express "symbol with name of length 1"?
		  :expected-type '(or character (string 1))
		  :format-control control
		  :format-arguments args)))
    (typecase object
      (character object)
      (string (if (= 1 (length (the string object)))
		  (char object 0)
		  (do-error
		   "String is not of length one: ~S" (list object))))
      (symbol (if (= 1 (length (symbol-name object)))
		  (schar (symbol-name object) 0)
		  (do-error
		   "Symbol name is not of length one: ~S" (list object))))
      (t (do-error "~S cannot be coerced to a character." (list object))))))

(defun char-name (char)
  #!+sb-doc
  "Return the name (a STRING) for a CHARACTER object."
  (car (rassoc char *char-name-alist*)))

(defun name-char (name)
  #!+sb-doc
  "Given an argument acceptable to STRING, NAME-CHAR returns a character
  whose name is that string, if one exists. Otherwise, NIL is returned."
  (cdr (assoc (string name) *char-name-alist* :test #'string-equal)))

;;;; predicates

(defun standard-char-p (char)
  #!+sb-doc
  "The argument must be a character object. STANDARD-CHAR-P returns T if the
   argument is a standard character -- one of the 95 ASCII printing characters
   or <return>."
  (and (typep char 'base-char)
       (let ((n (char-code (the base-char char))))
	 (or (< 31 n 127)
	     (= n 10)))))

(defun %standard-char-p (thing)
  #!+sb-doc
  "Return T if and only if THING is a standard-char. Differs from
  STANDARD-CHAR-P in that THING doesn't have to be a character."
  (and (characterp thing) (standard-char-p thing)))

(defun graphic-char-p (char)
  #!+sb-doc
  "The argument must be a character object. GRAPHIC-CHAR-P returns T if the
  argument is a printing character (space through ~ in ASCII), otherwise
  returns NIL."
  (let ((n (char-code char)))
    (or (< 31 n 127)
	(< 159 n))))

(defun alpha-char-p (char)
  #!+sb-doc
  "The argument must be a character object. ALPHA-CHAR-P returns T if the
   argument is an alphabetic character, A-Z or a-z; otherwise NIL."
  (< (ucd-general-category char) 5))

(defun upper-case-p (char)
  #!+sb-doc
  "The argument must be a character object; UPPER-CASE-P returns T if the
   argument is an upper-case character, NIL otherwise."
  (= (ucd-value-0 char) 0))

(defun lower-case-p (char)
  #!+sb-doc
  "The argument must be a character object; LOWER-CASE-P returns T if the
   argument is a lower-case character, NIL otherwise."
  (= (ucd-value-0 char) 1))

(defun both-case-p (char)
  #!+sb-doc
  "The argument must be a character object. BOTH-CASE-P returns T if the
  argument is an alphabetic character and if the character exists in
  both upper and lower case. For ASCII, this is the same as ALPHA-CHAR-P."
  (< (ucd-value-0 char) 2))

(defun digit-char-p (char &optional (radix 10.))
  #!+sb-doc
  "If char is a digit in the specified radix, returns the fixnum for
  which that digit stands, else returns NIL."
  (let ((m (- (char-code char) 48)))
    (declare (fixnum m))
    (cond ((<= radix 10.)
	   ;; Special-case decimal and smaller radices.
	   (if (and (>= m 0) (< m radix))  m  nil))
	  ;; Digits 0 - 9 are used as is, since radix is larger.
	  ((and (>= m 0) (< m 10)) m)
	  ;; Check for upper case A - Z.
	  ((and (>= (setq m (- m 7)) 10) (< m radix)) m)
	  ;; Also check lower case a - z.
	  ((and (>= (setq m (- m 32)) 10) (< m radix)) m)
	  ;; Else, fail.
	  (t (let ((number (ucd-decimal-digit char)))
	       (when (and number (< number radix))
		 number))))))

(defun alphanumericp (char)
  #!+sb-doc
  "Given a character-object argument, ALPHANUMERICP returns T if the
   argument is either numeric or alphabetic."
  (let ((gc (ucd-general-category char)))
    (or (< gc 5)
	(= gc 12))))

(defun char= (character &rest more-characters)
  #!+sb-doc
  "Return T if all of the arguments are the same character."
  (dolist (c more-characters t)
    (declare (type character c))
    (unless (eq c character) (return nil))))

(defun char/= (character &rest more-characters)
  #!+sb-doc
  "Return T if no two of the arguments are the same character."
  (do* ((head character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (declare (type character head))
    (dolist (c list)
      (declare (type character c))
      (when (eq head c) (return-from char/= nil)))))

(defun char< (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly increasing alphabetic order."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (< (char-int c)
	       (char-int (car list)))
      (return nil))))

(defun char> (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly decreasing alphabetic order."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (> (char-int c)
	       (char-int (car list)))
      (return nil))))

(defun char<= (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly non-decreasing alphabetic order."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (<= (char-int c)
		(char-int (car list)))
      (return nil))))

(defun char>= (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly non-increasing alphabetic order."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (>= (char-int c)
		(char-int (car list)))
      (return nil))))

;;; EQUAL-CHAR-CODE is used by the following functions as a version of CHAR-INT
;;;  which loses font, bits, and case info.

(defmacro equal-char-code (character)
  (let ((ch (gensym)))
    `(let ((,ch ,character))
      (if (= (ucd-value-0 ,ch) 0)
	  (ucd-value-1 ,ch)
	  (char-code ,ch)))))

(defun char-equal (character &rest more-characters)
  #!+sb-doc
  "Return T if all of the arguments are the same character.
  Font, bits, and case are ignored."
  (do ((clist more-characters (cdr clist)))
      ((null clist) t)
    (unless (= (equal-char-code (car clist))
	       (equal-char-code character))
      (return nil))))

(defun char-not-equal (character &rest more-characters)
  #!+sb-doc
  "Return T if no two of the arguments are the same character.
   Font, bits, and case are ignored."
  (do* ((head character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (do* ((l list (cdr l)))
		 ((null l) t)
	      (if (= (equal-char-code head)
		     (equal-char-code (car l)))
		  (return nil)))
      (return nil))))

(defun char-lessp (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly increasing alphabetic order.
   Font, bits, and case are ignored."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (< (equal-char-code c)
	       (equal-char-code (car list)))
      (return nil))))

(defun char-greaterp (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly decreasing alphabetic order.
   Font, bits, and case are ignored."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (> (equal-char-code c)
	       (equal-char-code (car list)))
      (return nil))))

(defun char-not-greaterp (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly non-decreasing alphabetic order.
   Font, bits, and case are ignored."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (<= (equal-char-code c)
		(equal-char-code (car list)))
      (return nil))))

(defun char-not-lessp (character &rest more-characters)
  #!+sb-doc
  "Return T if the arguments are in strictly non-increasing alphabetic order.
   Font, bits, and case are ignored."
  (do* ((c character (car list))
	(list more-characters (cdr list)))
       ((null list) t)
    (unless (>= (equal-char-code c)
		(equal-char-code (car list)))
      (return nil))))

;;;; miscellaneous functions

(defun char-upcase (char)
  #!+sb-doc
  "Return CHAR converted to upper-case if that is possible.  Don't convert
   lowercase eszet (U+DF)."
  (if (= (ucd-value-0 char) 1)
      (code-char (ucd-value-1 char))
      char))

(defun char-downcase (char)
  #!+sb-doc
  "Return CHAR converted to lower-case if that is possible."
  (if (= (ucd-value-0 char) 0)
      (code-char (ucd-value-1 char))
      char))

(defun digit-char (weight &optional (radix 10))
  #!+sb-doc
  "All arguments must be integers. Returns a character object that
  represents a digit of the given weight in the specified radix. Returns
  NIL if no such character exists."
  (and (typep weight 'fixnum)
       (>= weight 0) (< weight radix) (< weight 36)
       (code-char (if (< weight 10) (+ 48 weight) (+ 55 weight)))))
