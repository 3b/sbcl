;;;; "cold" core image builder: This is how we create a target Lisp
;;;; system from scratch, by converting from fasl files to an image
;;;; file in the cross-compilation host, without the help of the
;;;; target Lisp system.
;;;;
;;;; As explained by Rob MacLachlan on the CMU CL mailing list Wed, 06
;;;; Jan 1999 11:05:02 -0500, this cold load generator more or less
;;;; fakes up static function linking. I.e. it makes sure that all the
;;;; DEFUN-defined functions in the fasl files it reads are bound to the
;;;; corresponding symbols before execution starts. It doesn't do
;;;; anything to initialize variable values; instead it just arranges
;;;; for !COLD-INIT to be called at cold load time. !COLD-INIT is
;;;; responsible for explicitly initializing anything which has to be
;;;; initialized early before it transfers control to the ordinary
;;;; top-level forms.
;;;;
;;;; (In CMU CL, and in SBCL as of 0.6.9 anyway, functions not defined
;;;; by DEFUN aren't set up specially by GENESIS. In particular,
;;;; structure slot accessors are not set up. Slot accessors are
;;;; available at cold init time because they're usually compiled
;;;; inline. They're not available as out-of-line functions until the
;;;; toplevel forms installing them have run.)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!FASL")

;;; a magic number used to identify our core files
(defconstant core-magic
  (logior (ash (char-code #\S) 24)
	  (ash (char-code #\B) 16)
	  (ash (char-code #\C) 8)
	  (char-code #\L)))

;;; the current version of SBCL core files
;;;
;;; FIXME: This is left over from CMU CL, and not well thought out.
;;; It's good to make sure that the runtime doesn't try to run core
;;; files from the wrong version, but a single number is not the ideal
;;; way to do this in high level data like this (as opposed to e.g. in
;;; IP packets), and in fact the CMU CL version number never ended up
;;; being incremented past 0. A better approach might be to use a
;;; string which is set from CVS data.
;;;
;;; 0: inherited from CMU CL
;;; 1: rearranged static symbols for sbcl-0.6.8
;;; 2: eliminated non-ANSI %DEFCONSTANT/%%DEFCONSTANT support,
;;;    deleted a slot from DEBUG-SOURCE structure
(defconstant sbcl-core-version-integer 2)

(defun round-up (number size)
  #!+sb-doc
  "Round NUMBER up to be an integral multiple of SIZE."
  (* size (ceiling number size)))

;;;; representation of spaces in the core

;;; If there is more than one dynamic space in memory (i.e., if a
;;; copying GC is in use), then only the active dynamic space gets
;;; dumped to core.
(defvar *dynamic*)
(defconstant dynamic-space-id 1)

(defvar *static*)
(defconstant static-space-id 2)

(defvar *read-only*)
(defconstant read-only-space-id 3)

(defconstant descriptor-low-bits 16
  "the number of bits in the low half of the descriptor")
(defconstant target-space-alignment (ash 1 descriptor-low-bits)
  "the alignment requirement for spaces in the target.
  Must be at least (ASH 1 DESCRIPTOR-LOW-BITS)")

;;; a GENESIS-time representation of a memory space (e.g. read-only space,
;;; dynamic space, or static space)
(defstruct (gspace (:constructor %make-gspace)
		   (:copier nil))
  ;; name and identifier for this GSPACE
  (name (required-argument) :type symbol :read-only t)
  (identifier (required-argument) :type fixnum :read-only t)
  ;; the word address where the data will be loaded
  (word-address (required-argument) :type unsigned-byte :read-only t)
  ;; the data themselves. (Note that in CMU CL this was a pair
  ;; of fields SAP and WORDS-ALLOCATED, but that wasn't very portable.)
  (bytes (make-array target-space-alignment :element-type '(unsigned-byte 8))
	 :type (simple-array (unsigned-byte 8) 1))
  ;; the index of the next unwritten word (i.e. chunk of
  ;; SB!VM:WORD-BYTES bytes) in BYTES, or equivalently the number of
  ;; words actually written in BYTES. In order to convert to an actual
  ;; index into BYTES, thus must be multiplied by SB!VM:WORD-BYTES.
  (free-word-index 0))

(defun gspace-byte-address (gspace)
  (ash (gspace-word-address gspace) sb!vm:word-shift))

(def!method print-object ((gspace gspace) stream)
  (print-unreadable-object (gspace stream :type t)
    (format stream "~S" (gspace-name gspace))))

(defun make-gspace (name identifier byte-address)
  (unless (zerop (rem byte-address target-space-alignment))
    (error "The byte address #X~X is not aligned on a #X~X-byte boundary."
	   byte-address
	   target-space-alignment))
  (%make-gspace :name name
		:identifier identifier
		:word-address (ash byte-address (- sb!vm:word-shift))))

;;; KLUDGE: Doing it this way seems to partly replicate the
;;; functionality of Common Lisp adjustable arrays. Is there any way
;;; to do this stuff in one line of code by using standard Common Lisp
;;; stuff? -- WHN 19990816
(defun expand-gspace-bytes (gspace)
  (let* ((old-bytes (gspace-bytes gspace))
	 (old-length (length old-bytes))
	 (new-length (* 2 old-length))
	 (new-bytes (make-array new-length :element-type '(unsigned-byte 8))))
    (replace new-bytes old-bytes :end1 old-length)
    (setf (gspace-bytes gspace)
	  new-bytes))
  (values))

;;;; representation of descriptors

(defstruct (descriptor
	    (:constructor make-descriptor
			  (high low &optional gspace word-offset))
	    (:copier nil))
  ;; the GSPACE that this descriptor is allocated in, or NIL if not set yet.
  (gspace nil :type (or gspace null))
  ;; the offset in words from the start of GSPACE, or NIL if not set yet
  (word-offset nil :type (or (unsigned-byte #.sb!vm:word-bits) null))
  ;; the high and low halves of the descriptor
  ;;
  ;; KLUDGE: Judging from the comments in genesis.lisp of the CMU CL
  ;; old-rt compiler, this split dates back from a very early version
  ;; of genesis where 32-bit integers were represented as conses of
  ;; two 16-bit integers. In any system with nice (UNSIGNED-BYTE 32)
  ;; structure slots, like CMU CL >= 17 or any version of SBCL, there
  ;; seems to be no reason to persist in this. -- WHN 19990917
  high
  low)
(def!method print-object ((des descriptor) stream)
  (let ((lowtag (descriptor-lowtag des)))
    (print-unreadable-object (des stream :type t)
      (cond ((or (= lowtag sb!vm:even-fixnum-type)
		 (= lowtag sb!vm:odd-fixnum-type))
	     (let ((unsigned (logior (ash (descriptor-high des)
					  (1+ (- descriptor-low-bits
						 sb!vm:lowtag-bits)))
				     (ash (descriptor-low des)
					  (- 1 sb!vm:lowtag-bits)))))
	       (format stream
		       "for fixnum: ~D"
		       (if (> unsigned #x1FFFFFFF)
			   (- unsigned #x40000000)
			   unsigned))))
	    ((or (= lowtag sb!vm:other-immediate-0-type)
		 (= lowtag sb!vm:other-immediate-1-type))
	     (format stream
		     "for other immediate: #X~X, type #b~8,'0B"
		     (ash (descriptor-bits des) (- sb!vm:type-bits))
		     (logand (descriptor-low des) sb!vm:type-mask)))
	    (t
	     (format stream
		     "for pointer: #X~X, lowtag #b~3,'0B, ~A"
		     (logior (ash (descriptor-high des) descriptor-low-bits)
			     (logandc2 (descriptor-low des) sb!vm:lowtag-mask))
		     lowtag
		     (let ((gspace (descriptor-gspace des)))
		       (if gspace
			   (gspace-name gspace)
			   "unknown"))))))))

;;; Return a descriptor for a block of LENGTH bytes out of GSPACE. The
;;; free word index is boosted as necessary, and if additional memory
;;; is needed, we grow the GSPACE. The descriptor returned is a
;;; pointer of type LOWTAG.
(defun allocate-cold-descriptor (gspace length lowtag)
  (let* ((bytes (round-up length (ash 1 sb!vm:lowtag-bits)))
	 (old-free-word-index (gspace-free-word-index gspace))
	 (new-free-word-index (+ old-free-word-index
				 (ash bytes (- sb!vm:word-shift)))))
    ;; Grow GSPACE as necessary until it's big enough to handle
    ;; NEW-FREE-WORD-INDEX.
    (do ()
	((>= (length (gspace-bytes gspace))
	     (* new-free-word-index sb!vm:word-bytes)))
      (expand-gspace-bytes gspace))
    ;; Now that GSPACE is big enough, we can meaningfully grab a chunk of it.
    (setf (gspace-free-word-index gspace) new-free-word-index)
    (let ((ptr (+ (gspace-word-address gspace) old-free-word-index)))
      (make-descriptor (ash ptr (- sb!vm:word-shift descriptor-low-bits))
		       (logior (ash (logand ptr
					    (1- (ash 1
						     (- descriptor-low-bits
							sb!vm:word-shift))))
				    sb!vm:word-shift)
			       lowtag)
		       gspace
		       old-free-word-index))))

(defun descriptor-lowtag (des)
  #!+sb-doc
  "the lowtag bits for DES"
  (logand (descriptor-low des) sb!vm:lowtag-mask))

(defun descriptor-bits (des)
  (logior (ash (descriptor-high des) descriptor-low-bits)
	  (descriptor-low des)))

(defun descriptor-fixnum (des)
  (let ((bits (descriptor-bits des)))
    (if (logbitp (1- sb!vm:word-bits) bits)
      ;; KLUDGE: The (- SB!VM:WORD-BITS 2) term here looks right to
      ;; me, and it works, but in CMU CL it was (1- SB!VM:WORD-BITS),
      ;; and although that doesn't make sense for me, or work for me,
      ;; it's hard to see how it could have been wrong, since CMU CL
      ;; genesis worked. It would be nice to understand how this came
      ;; to be.. -- WHN 19990901
      (logior (ash bits -2) (ash -1 (- sb!vm:word-bits 2)))
      (ash bits -2))))

;;; common idioms
(defun descriptor-bytes (des)
  (gspace-bytes (descriptor-intuit-gspace des)))
(defun descriptor-byte-offset (des)
  (ash (descriptor-word-offset des) sb!vm:word-shift))

;;; If DESCRIPTOR-GSPACE is already set, just return that. Otherwise,
;;; figure out a GSPACE which corresponds to DES, set it into
;;; (DESCRIPTOR-GSPACE DES), set a consistent value into
;;; (DESCRIPTOR-WORD-OFFSET DES), and return the GSPACE.
(declaim (ftype (function (descriptor) gspace) descriptor-intuit-gspace))
(defun descriptor-intuit-gspace (des)
  (if (descriptor-gspace des)
    (descriptor-gspace des)
    ;; KLUDGE: It's not completely clear to me what's going on here;
    ;; this is a literal translation from of some rather mysterious
    ;; code from CMU CL's DESCRIPTOR-SAP function. Some explanation
    ;; would be nice. -- WHN 19990817
    (let ((lowtag (descriptor-lowtag des))
	  (high (descriptor-high des))
	  (low (descriptor-low des)))
      (if (or (eql lowtag sb!vm:function-pointer-type)
	      (eql lowtag sb!vm:instance-pointer-type)
	      (eql lowtag sb!vm:list-pointer-type)
	      (eql lowtag sb!vm:other-pointer-type))
	(dolist (gspace (list *dynamic* *static* *read-only*)
			(error "couldn't find a GSPACE for ~S" des))
	  ;; This code relies on the fact that GSPACEs are aligned such that
	  ;; the descriptor-low-bits low bits are zero.
	  (when (and (>= high (ash (gspace-word-address gspace)
				   (- sb!vm:word-shift descriptor-low-bits)))
		     (<= high (ash (+ (gspace-word-address gspace)
				      (gspace-free-word-index gspace))
				   (- sb!vm:word-shift descriptor-low-bits))))
	    (setf (descriptor-gspace des) gspace)
	    (setf (descriptor-word-offset des)
		  (+ (ash (- high (ash (gspace-word-address gspace)
				       (- sb!vm:word-shift
					  descriptor-low-bits)))
			  (- descriptor-low-bits sb!vm:word-shift))
		     (ash (logandc2 low sb!vm:lowtag-mask)
			  (- sb!vm:word-shift))))
	    (return gspace)))
	(error "don't even know how to look for a GSPACE for ~S" des)))))

(defun make-random-descriptor (value)
  (make-descriptor (logand (ash value (- descriptor-low-bits))
			   (1- (ash 1
				    (- sb!vm:word-bits descriptor-low-bits))))
		   (logand value (1- (ash 1 descriptor-low-bits)))))

(defun make-fixnum-descriptor (num)
  (when (>= (integer-length num)
	    (1+ (- sb!vm:word-bits sb!vm:lowtag-bits)))
    (error "~D is too big for a fixnum." num))
  (make-random-descriptor (ash num (1- sb!vm:lowtag-bits))))

(defun make-other-immediate-descriptor (data type)
  (make-descriptor (ash data (- sb!vm:type-bits descriptor-low-bits))
		   (logior (logand (ash data (- descriptor-low-bits
						sb!vm:type-bits))
				   (1- (ash 1 descriptor-low-bits)))
			   type)))

(defun make-character-descriptor (data)
  (make-other-immediate-descriptor data sb!vm:base-char-type))

(defun descriptor-beyond (des offset type)
  (let* ((low (logior (+ (logandc2 (descriptor-low des) sb!vm:lowtag-mask)
			 offset)
		      type))
	 (high (+ (descriptor-high des)
		  (ash low (- descriptor-low-bits)))))
    (make-descriptor high (logand low (1- (ash 1 descriptor-low-bits))))))

;;;; miscellaneous variables and other noise

;;; a numeric value to be returned for undefined foreign symbols, or NIL if
;;; undefined foreign symbols are to be treated as an error.
;;; (In the first pass of GENESIS, needed to create a header file before
;;; the C runtime can be built, various foreign symbols will necessarily
;;; be undefined, but we don't need actual values for them anyway, and
;;; we can just use 0 or some other placeholder. In the second pass of
;;; GENESIS, all foreign symbols should be defined, so any undefined
;;; foreign symbol is a problem.)
;;;
;;; KLUDGE: It would probably be cleaner to rewrite GENESIS so that it
;;; never tries to look up foreign symbols in the first place unless
;;; it's actually creating a core file (as in the second pass) instead
;;; of using this hack to allow it to go through the motions without
;;; causing an error. -- WHN 20000825
(defvar *foreign-symbol-placeholder-value*)

;;; a handle on the trap object
(defvar *unbound-marker*)
;; was:  (make-other-immediate-descriptor 0 sb!vm:unbound-marker-type)

;;; a handle on the NIL object
(defvar *nil-descriptor*)

;;; the head of a list of TOPLEVEL-THINGs describing stuff to be done
;;; when the target Lisp starts up
;;;
;;; Each TOPLEVEL-THING can be a function to be executed or a fixup or
;;; loadtime value, represented by (CONS KEYWORD ..). The FILENAME
;;; tells which fasl file each list element came from, for debugging
;;; purposes.
(defvar *current-reversed-cold-toplevels*)

;;; the name of the object file currently being cold loaded (as a string, not a
;;; pathname), or NIL if we're not currently cold loading any object file
(defvar *cold-load-filename* nil)
(declaim (type (or string null) *cold-load-filename*))

;;; This is vestigial support for the CMU CL byte-swapping code. CMU
;;; CL code tested for whether it needed to swap bytes in GENESIS by
;;; comparing the byte order of *BACKEND* to the byte order of
;;; *NATIVE-BACKEND*, a concept which doesn't exist in SBCL. Instead,
;;; in SBCL byte order swapping would need to be explicitly requested
;;; with a &KEY argument to GENESIS.
;;;
;;; I'm not sure whether this is a problem or not, and I don't have a
;;; machine with different byte order to test to find out for sure.
;;; The version of the system which is fed to the cross-compiler is
;;; now written in a subset of Common Lisp which doesn't require
;;; dumping a lot of things in such a way that machine byte order
;;; matters. (Mostly this is a matter of not using any specialized
;;; array type unless there's portable, high-level code to dump it.)
;;; If it *is* a problem, and you're trying to resurrect this code,
;;; please test particularly carefully, since I haven't had a chance
;;; to test the byte-swapping code at all. -- WHN 19990816
;;;
;;; When this variable is non-NIL, byte-swapping is enabled wherever
;;; classic GENESIS would have done it. I.e. the value of this variable
;;; is the logical complement of
;;;    (EQ (SB!C:BACKEND-BYTE-ORDER SB!C:*NATIVE-BACKEND*)
;;;	(SB!C:BACKEND-BYTE-ORDER SB!C:*BACKEND*))
;;; from CMU CL.
(defvar *genesis-byte-order-swap-p*)

;;;; miscellaneous stuff to read and write the core memory

;;; FIXME: should be DEFINE-MODIFY-MACRO
(defmacro cold-push (thing list)
  #!+sb-doc
  "Push THING onto the given cold-load LIST."
  `(setq ,list (cold-cons ,thing ,list)))

(defun maybe-byte-swap (word)
  (declare (type (unsigned-byte 32) word))
  (aver (= sb!vm:word-bits 32))
  (aver (= sb!vm:byte-bits 8))
  (if (not *genesis-byte-order-swap-p*)
      word
      (logior (ash (ldb (byte 8 0) word) 24)
	      (ash (ldb (byte 8 8) word) 16)
	      (ash (ldb (byte 8 16) word) 8)
	      (ldb (byte 8 24) word))))

(defun maybe-byte-swap-short (short)
  (declare (type (unsigned-byte 16) short))
  (aver (= sb!vm:word-bits 32))
  (aver (= sb!vm:byte-bits 8))
  (if (not *genesis-byte-order-swap-p*)
      short
      (logior (ash (ldb (byte 8 0) short) 8)
	      (ldb (byte 8 8) short))))

;;; BYTE-VECTOR-REF-32 and friends.  These are like SAP-REF-n, except
;;; that instead of a SAP we use a byte vector
(macrolet ((make-byte-vector-ref-n
            (n)
            (let* ((name (intern (format nil "BYTE-VECTOR-REF-~A" n)))
                   (number-octets (/ n 8))
                   (ash-list
                    (loop for i from 0 to (1- number-octets)
                          collect `(ash (aref byte-vector (+ byte-index ,i))
                                        ,(* i 8))))
                   (setf-list
                    (loop for i from 0 to (1- number-octets)
                          append
                          `((aref byte-vector (+ byte-index ,i))
                            (ldb (byte 8 ,(* i 8)) new-value)))))
              `(progn
                 (defun ,name (byte-vector byte-index)
  (aver (= sb!vm:word-bits 32))
  (aver (= sb!vm:byte-bits 8))
  (ecase sb!c:*backend-byte-order*
    (:little-endian
                      (logior ,@ash-list))
    (:big-endian
     (error "stub: no big-endian ports of SBCL (yet?)"))))
                 (defun (setf ,name) (new-value byte-vector byte-index)
  (aver (= sb!vm:word-bits 32))
  (aver (= sb!vm:byte-bits 8))
  (ecase sb!c:*backend-byte-order*
    (:little-endian
                      (setf ,@setf-list))
    (:big-endian
                      (error "stub: no big-endian ports of SBCL (yet?)"))))))))
  (make-byte-vector-ref-n 8)
  (make-byte-vector-ref-n 16)
  (make-byte-vector-ref-n 32))

(declaim (ftype (function (descriptor sb!vm:word) descriptor) read-wordindexed))
(defun read-wordindexed (address index)
  #!+sb-doc
  "Return the value which is displaced by INDEX words from ADDRESS."
  (let* ((gspace (descriptor-intuit-gspace address))
	 (bytes (gspace-bytes gspace))
	 (byte-index (ash (+ index (descriptor-word-offset address))
			  sb!vm:word-shift))
	 ;; KLUDGE: Do we really need to do byte swap here? It seems
	 ;; as though we shouldn't.. (This attempts to be a literal
	 ;; translation of CMU CL code, and I don't have a big-endian
	 ;; machine to test it.) -- WHN 19990817
	 (value (maybe-byte-swap (byte-vector-ref-32 bytes byte-index))))
    (make-random-descriptor value)))

(declaim (ftype (function (descriptor) descriptor) read-memory))
(defun read-memory (address)
  #!+sb-doc
  "Return the value at ADDRESS."
  (read-wordindexed address 0))

;;; (Note: In CMU CL, this function expected a SAP-typed ADDRESS
;;; value, instead of the SAPINT we use here.)
(declaim (ftype (function (sb!vm:word descriptor) (values)) note-load-time-value-reference))
(defun note-load-time-value-reference (address marker)
  (cold-push (cold-cons
	      (cold-intern :load-time-value-fixup)
	      (cold-cons (sapint-to-core address)
			 (cold-cons
			  (number-to-core (descriptor-word-offset marker))
			  *nil-descriptor*)))
	     *current-reversed-cold-toplevels*)
  (values))

(declaim (ftype (function (descriptor sb!vm:word descriptor)) write-wordindexed))
(defun write-wordindexed (address index value)
  #!+sb-doc
  "Write VALUE displaced INDEX words from ADDRESS."
  ;; KLUDGE: There is an algorithm (used in DESCRIPTOR-INTUIT-GSPACE)
  ;; for calculating the value of the GSPACE slot from scratch. It
  ;; doesn't work for all values, only some of them, but mightn't it
  ;; be reasonable to see whether it works on VALUE before we give up
  ;; because (DESCRIPTOR-GSPACE VALUE) isn't set? (Or failing that,
  ;; perhaps write a comment somewhere explaining why it's not a good
  ;; idea?) -- WHN 19990817
  (if (and (null (descriptor-gspace value))
	   (not (null (descriptor-word-offset value))))
    (note-load-time-value-reference (+ (logandc2 (descriptor-bits address)
						 sb!vm:lowtag-mask)
				       (ash index sb!vm:word-shift))
				    value)
    ;; Note: There's a MAYBE-BYTE-SWAP in here in CMU CL, which I
    ;; think is unnecessary now that we're doing the write
    ;; byte-by-byte at high level. (I can't test this, though..) --
    ;; WHN 19990817
    (let* ((bytes (gspace-bytes (descriptor-intuit-gspace address)))
	   (byte-index (ash (+ index (descriptor-word-offset address))
			       sb!vm:word-shift)))
      (setf (byte-vector-ref-32 bytes byte-index)
	    (maybe-byte-swap (descriptor-bits value))))))

(declaim (ftype (function (descriptor descriptor)) write-memory))
(defun write-memory (address value)
  #!+sb-doc
  "Write VALUE (a DESCRIPTOR) at ADDRESS (also a DESCRIPTOR)."
  (write-wordindexed address 0 value))

;;;; allocating images of primitive objects in the cold core

;;; There are three kinds of blocks of memory in the type system:
;;; * Boxed objects (cons cells, structures, etc): These objects have no
;;;   header as all slots are descriptors.
;;; * Unboxed objects (bignums): There is a single header word that contains
;;;   the length.
;;; * Vector objects: There is a header word with the type, then a word for
;;;   the length, then the data.
(defun allocate-boxed-object (gspace length lowtag)
  #!+sb-doc
  "Allocate LENGTH words in GSPACE and return a new descriptor of type LOWTAG
  pointing to them."
  (allocate-cold-descriptor gspace (ash length sb!vm:word-shift) lowtag))
(defun allocate-unboxed-object (gspace element-bits length type)
  #!+sb-doc
  "Allocate LENGTH units of ELEMENT-BITS bits plus a header word in GSPACE and
  return an ``other-pointer'' descriptor to them. Initialize the header word
  with the resultant length and TYPE."
  (let* ((bytes (/ (* element-bits length) sb!vm:byte-bits))
	 (des (allocate-cold-descriptor gspace
					(+ bytes sb!vm:word-bytes)
					sb!vm:other-pointer-type)))
    (write-memory des
		  (make-other-immediate-descriptor (ash bytes
							(- sb!vm:word-shift))
						   type))
    des))
(defun allocate-vector-object (gspace element-bits length type)
  #!+sb-doc
  "Allocate LENGTH units of ELEMENT-BITS size plus a header plus a length slot in
  GSPACE and return an ``other-pointer'' descriptor to them. Initialize the
  header word with TYPE and the length slot with LENGTH."
  ;; FIXME: Here and in ALLOCATE-UNBOXED-OBJECT, BYTES is calculated using
  ;; #'/ instead of #'CEILING, which seems wrong.
  (let* ((bytes (/ (* element-bits length) sb!vm:byte-bits))
	 (des (allocate-cold-descriptor gspace
					(+ bytes (* 2 sb!vm:word-bytes))
					sb!vm:other-pointer-type)))
    (write-memory des (make-other-immediate-descriptor 0 type))
    (write-wordindexed des
		       sb!vm:vector-length-slot
		       (make-fixnum-descriptor length))
    des))

;;;; copying simple objects into the cold core

(defun string-to-core (string &optional (gspace *dynamic*))
  #!+sb-doc
  "Copy string into the cold core and return a descriptor to it."
  ;; (Remember that the system convention for storage of strings leaves an
  ;; extra null byte at the end to aid in call-out to C.)
  (let* ((length (length string))
	 (des (allocate-vector-object gspace
				      sb!vm:byte-bits
				      (1+ length)
				      sb!vm:simple-string-type))
	 (bytes (gspace-bytes gspace))
	 (offset (+ (* sb!vm:vector-data-offset sb!vm:word-bytes)
		    (descriptor-byte-offset des))))
    (write-wordindexed des
		       sb!vm:vector-length-slot
		       (make-fixnum-descriptor length))
    (dotimes (i length)
      (setf (aref bytes (+ offset i))
	    ;; KLUDGE: There's no guarantee that the character
	    ;; encoding here will be the same as the character
	    ;; encoding on the target machine, so using CHAR-CODE as
	    ;; we do, or a bitwise copy as CMU CL code did, is sleazy.
	    ;; (To make this more portable, perhaps we could use
	    ;; indices into the sequence which is used to test whether
	    ;; a character is a STANDARD-CHAR?) -- WHN 19990817
	    (char-code (aref string i))))
    (setf (aref bytes (+ offset length))
	  0) ; null string-termination character for C
    des))

(defun bignum-to-core (n)
  #!+sb-doc
  "Copy a bignum to the cold core."
  (let* ((words (ceiling (1+ (integer-length n)) sb!vm:word-bits))
	 (handle (allocate-unboxed-object *dynamic*
					  sb!vm:word-bits
					  words
					  sb!vm:bignum-type)))
    (declare (fixnum words))
    (do ((index 1 (1+ index))
	 (remainder n (ash remainder (- sb!vm:word-bits))))
	((> index words)
	 (unless (zerop (integer-length remainder))
	   ;; FIXME: Shouldn't this be a fatal error?
	   (warn "~D words of ~D were written, but ~D bits were left over."
		 words n remainder)))
      (let ((word (ldb (byte sb!vm:word-bits 0) remainder)))
	(write-wordindexed handle index
			   (make-descriptor (ash word (- descriptor-low-bits))
					    (ldb (byte descriptor-low-bits 0)
						 word)))))
    handle))

(defun number-pair-to-core (first second type)
  #!+sb-doc
  "Makes a number pair of TYPE (ratio or complex) and fills it in."
  (let ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits 2 type)))
    (write-wordindexed des 1 first)
    (write-wordindexed des 2 second)
    des))

(defun float-to-core (x)
  (etypecase x
    (single-float
     (let ((des (allocate-unboxed-object *dynamic*
					 sb!vm:word-bits
					 (1- sb!vm:single-float-size)
					 sb!vm:single-float-type)))
       (write-wordindexed des
			  sb!vm:single-float-value-slot
			  (make-random-descriptor (single-float-bits x)))
       des))
    (double-float
     (let ((des (allocate-unboxed-object *dynamic*
					 sb!vm:word-bits
					 (1- sb!vm:double-float-size)
					 sb!vm:double-float-type))
	   (high-bits (make-random-descriptor (double-float-high-bits x)))
	   (low-bits (make-random-descriptor (double-float-low-bits x))))
       (ecase sb!c:*backend-byte-order*
	 (:little-endian
	  (write-wordindexed des sb!vm:double-float-value-slot low-bits)
	  (write-wordindexed des (1+ sb!vm:double-float-value-slot) high-bits))
	 (:big-endian
	  (write-wordindexed des sb!vm:double-float-value-slot high-bits)
	  (write-wordindexed des (1+ sb!vm:double-float-value-slot) low-bits)))
       des))
    #!+(and long-float x86)
    (long-float
     (let ((des (allocate-unboxed-object *dynamic*
					 sb!vm:word-bits
					 (1- sb!vm:long-float-size)
					 sb!vm:long-float-type))
	   (exp-bits (make-random-descriptor (long-float-exp-bits x)))
	   (high-bits (make-random-descriptor (long-float-high-bits x)))
	   (low-bits (make-random-descriptor (long-float-low-bits x))))
       (ecase sb!c:*backend-byte-order*
	 (:little-endian
	  (write-wordindexed des sb!vm:long-float-value-slot low-bits)
	  (write-wordindexed des (1+ sb!vm:long-float-value-slot) high-bits)
	  (write-wordindexed des (+ 2 sb!vm:long-float-value-slot) exp-bits))
	 (:big-endian
	  (error "LONG-FLOAT is not supported for big-endian byte order.")))
       des))))

(defun complex-single-float-to-core (num)
  (declare (type (complex single-float) num))
  (let ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits
				      (1- sb!vm:complex-single-float-size)
				      sb!vm:complex-single-float-type)))
    (write-wordindexed des sb!vm:complex-single-float-real-slot
		   (make-random-descriptor (single-float-bits (realpart num))))
    (write-wordindexed des sb!vm:complex-single-float-imag-slot
		   (make-random-descriptor (single-float-bits (imagpart num))))
    des))

(defun complex-double-float-to-core (num)
  (declare (type (complex double-float) num))
  (let ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits
				      (1- sb!vm:complex-double-float-size)
				      sb!vm:complex-double-float-type)))
    (let* ((real (realpart num))
	   (high-bits (make-random-descriptor (double-float-high-bits real)))
	   (low-bits (make-random-descriptor (double-float-low-bits real))))
      (ecase sb!c:*backend-byte-order*
	(:little-endian
	 (write-wordindexed des sb!vm:complex-double-float-real-slot low-bits)
	 (write-wordindexed des (1+ sb!vm:complex-double-float-real-slot) high-bits))
	(:big-endian
	 (write-wordindexed des sb!vm:complex-double-float-real-slot high-bits)
	 (write-wordindexed des (1+ sb!vm:complex-double-float-real-slot) low-bits))))
    (let* ((imag (imagpart num))
	   (high-bits (make-random-descriptor (double-float-high-bits imag)))
	   (low-bits (make-random-descriptor (double-float-low-bits imag))))
      (ecase sb!c:*backend-byte-order*
	(:little-endian
	 (write-wordindexed des sb!vm:complex-double-float-imag-slot low-bits)
	 (write-wordindexed des (1+ sb!vm:complex-double-float-imag-slot) high-bits))
	(:big-endian
	 (write-wordindexed des sb!vm:complex-double-float-imag-slot high-bits)
	 (write-wordindexed des (1+ sb!vm:complex-double-float-imag-slot) low-bits))))
    des))

(defun number-to-core (number)
  #!+sb-doc
  "Copy the given number to the core, or flame out if we can't deal with it."
  (typecase number
    (integer (if (< (integer-length number) 30)
		 (make-fixnum-descriptor number)
		 (bignum-to-core number)))
    (ratio (number-pair-to-core (number-to-core (numerator number))
				(number-to-core (denominator number))
				sb!vm:ratio-type))
    ((complex single-float) (complex-single-float-to-core number))
    ((complex double-float) (complex-double-float-to-core number))
    #!+long-float
    ((complex long-float)
     (error "~S isn't a cold-loadable number at all!" number))
    (complex (number-pair-to-core (number-to-core (realpart number))
				  (number-to-core (imagpart number))
				  sb!vm:complex-type))
    (float (float-to-core number))
    (t (error "~S isn't a cold-loadable number at all!" number))))

(declaim (ftype (function (sb!vm:word) descriptor) sap-to-core))
(defun sapint-to-core (sapint)
  (let ((des (allocate-unboxed-object *dynamic*
				      sb!vm:word-bits
				      (1- sb!vm:sap-size)
				      sb!vm:sap-type)))
    (write-wordindexed des
		       sb!vm:sap-pointer-slot
		       (make-random-descriptor sapint))
    des))

;;; Allocate a cons cell in GSPACE and fill it in with CAR and CDR.
(defun cold-cons (car cdr &optional (gspace *dynamic*))
  (let ((dest (allocate-boxed-object gspace 2 sb!vm:list-pointer-type)))
    (write-memory dest car)
    (write-wordindexed dest 1 cdr)
    dest))

;;; Make a simple-vector that holds the specified OBJECTS, and return its
;;; descriptor.
(defun vector-in-core (&rest objects)
  (let* ((size (length objects))
	 (result (allocate-vector-object *dynamic* sb!vm:word-bits size
					 sb!vm:simple-vector-type)))
    (dotimes (index size)
      (write-wordindexed result (+ index sb!vm:vector-data-offset)
			 (pop objects)))
    result))

;;;; symbol magic

;;; FIXME: This should be a &KEY argument of ALLOCATE-SYMBOL.
(defvar *cold-symbol-allocation-gspace* nil)

;;; Allocate (and initialize) a symbol.
(defun allocate-symbol (name)
  (declare (simple-string name))
  (let ((symbol (allocate-unboxed-object (or *cold-symbol-allocation-gspace*
					     *dynamic*)
					 sb!vm:word-bits
					 (1- sb!vm:symbol-size)
					 sb!vm:symbol-header-type)))
    (write-wordindexed symbol sb!vm:symbol-value-slot *unbound-marker*)
    #!+x86
    (write-wordindexed symbol
		       sb!vm:symbol-hash-slot
		       (make-fixnum-descriptor
			(1+ (random sb!vm:*target-most-positive-fixnum*))))
    (write-wordindexed symbol sb!vm:symbol-plist-slot *nil-descriptor*)
    (write-wordindexed symbol sb!vm:symbol-name-slot
		       (string-to-core name *dynamic*))
    (write-wordindexed symbol sb!vm:symbol-package-slot *nil-descriptor*)
    symbol))

;;; Set the cold symbol value of SYMBOL-OR-SYMBOL-DES, which can be either a
;;; descriptor of a cold symbol or (in an abbreviation for the
;;; most common usage pattern) an ordinary symbol, which will be
;;; automatically cold-interned.
(declaim (ftype (function ((or descriptor symbol) descriptor)) cold-set))
(defun cold-set (symbol-or-symbol-des value)
  (let ((symbol-des (etypecase symbol-or-symbol-des
		      (descriptor symbol-or-symbol-des)
		      (symbol (cold-intern symbol-or-symbol-des)))))
    (write-wordindexed symbol-des sb!vm:symbol-value-slot value)))

;;;; layouts and type system pre-initialization

;;; Since we want to be able to dump structure constants and
;;; predicates with reference layouts, we need to create layouts at
;;; cold-load time. We use the name to intern layouts by, and dump a
;;; list of all cold layouts in *!INITIAL-LAYOUTS* so that type system
;;; initialization can find them. The only thing that's tricky [sic --
;;; WHN 19990816] is initializing layout's layout, which must point to
;;; itself.

;;; a map from class names to lists of
;;;    `(,descriptor ,name ,length ,inherits ,depth)
;;; KLUDGE: It would be more understandable and maintainable to use
;;; DEFSTRUCT (:TYPE LIST) here. -- WHN 19990823
(defvar *cold-layouts* (make-hash-table :test 'equal))

;;; a map from DESCRIPTOR-BITS of cold layouts to the name, for inverting
;;; mapping
(defvar *cold-layout-names* (make-hash-table :test 'eql))

;;; FIXME: *COLD-LAYOUTS* and *COLD-LAYOUT-NAMES* should be
;;; initialized by binding in GENESIS.

;;; the descriptor for layout's layout (needed when making layouts)
(defvar *layout-layout*)

;;; FIXME: This information should probably be pulled out of the
;;; cross-compiler's tables at genesis time instead of inserted by
;;; hand here as a bare numeric constant.
(defconstant target-layout-length 16)

;;; Return a list of names created from the cold layout INHERITS data
;;; in X.
(defun listify-cold-inherits (x)
  (let ((len (descriptor-fixnum (read-wordindexed x
						  sb!vm:vector-length-slot))))
    (collect ((res))
      (dotimes (index len)
	(let* ((des (read-wordindexed x (+ sb!vm:vector-data-offset index)))
	       (found (gethash (descriptor-bits des) *cold-layout-names*)))
	  (if found
	    (res found)
	    (error "unknown descriptor at index ~S (bits = ~8,'0X)"
		   index
		   (descriptor-bits des)))))
      (res))))

(declaim (ftype (function (symbol descriptor descriptor descriptor) descriptor)
		make-cold-layout))
(defun make-cold-layout (name length inherits depthoid)
  (let ((result (allocate-boxed-object *dynamic*
				       ;; KLUDGE: Why 1+? -- WHN 19990901
				       (1+ target-layout-length)
				       sb!vm:instance-pointer-type)))
    (write-memory result
		  (make-other-immediate-descriptor target-layout-length
						   sb!vm:instance-header-type))

    ;; KLUDGE: The offsets into LAYOUT below should probably be pulled out
    ;; of the cross-compiler's tables at genesis time instead of inserted
    ;; by hand as bare numeric constants. -- WHN ca. 19990901

    ;; Set slot 0 = the layout of the layout.
    (write-wordindexed result sb!vm:instance-slots-offset *layout-layout*)

    ;; Set the immediately following slots = CLOS hash values.
    ;;
    ;; Note: CMU CL didn't set these in genesis, but instead arranged
    ;; for them to be set at cold init time. That resulted in slightly
    ;; kludgy-looking code, but there were at least two things to be
    ;; said for it:
    ;;   1. It put the hash values under the control of the target Lisp's
    ;;      RANDOM function, so that CLOS behavior would be nearly
    ;;      deterministic (instead of depending on the implementation of
    ;;      RANDOM in the cross-compilation host, and the state of its
    ;;      RNG when genesis begins).
    ;;   2. It automatically ensured that all hash values in the target Lisp
    ;;      were part of the same sequence, so that we didn't have to worry
    ;;      about the possibility of the first hash value set in genesis
    ;;      being precisely equal to the some hash value set in cold init time
    ;;      (because the target Lisp RNG has advanced to precisely the same
    ;;      state that the host Lisp RNG was in earlier).
    ;; Point 1 should not be an issue in practice because of the way we do our
    ;; build procedure in two steps, so that the SBCL that we end up with has
    ;; been created by another SBCL (whose RNG is under our control).
    ;; Point 2 is more of an issue. If ANSI had provided a way to feed
    ;; entropy into an RNG, we would have no problem: we'd just feed
    ;; some specialized genesis-time-only pattern into the RNG state
    ;; before using it. However, they didn't, so we have a slight
    ;; problem. We address it by generating the hash values using a
    ;; different algorithm than we use in ordinary operation.
    (dotimes (i sb!kernel:layout-clos-hash-length)
      (let (;; The expression here is pretty arbitrary, we just want
	    ;; to make sure that it's not something which is (1)
	    ;; evenly distributed and (2) not foreordained to arise in
	    ;; the target Lisp's (RANDOM-LAYOUT-CLOS-HASH) sequence
	    ;; and show up as the CLOS-HASH value of some other
	    ;; LAYOUT.
	    ;;
	    ;; FIXME: This expression here can generate a zero value,
	    ;; and the CMU CL code goes out of its way to generate
	    ;; strictly positive values (even though the field is
	    ;; declared as an INDEX). Check that it's really OK to
	    ;; have zero values in the CLOS-HASH slots.
	    (hash-value (mod (logxor (logand   (random-layout-clos-hash) 15253)
				     (logandc2 (random-layout-clos-hash) 15253)
				     1)
			     ;; (The MOD here is defensive programming
			     ;; to make sure we never write an
			     ;; out-of-range value even if some joker
			     ;; sets LAYOUT-CLOS-HASH-MAX to other
			     ;; than 2^n-1 at some time in the
			     ;; future.)
			     (1+ sb!kernel:layout-clos-hash-max))))
	(write-wordindexed result
			   (+ i sb!vm:instance-slots-offset 1)
			   (make-fixnum-descriptor hash-value))))

    ;; Set other slot values.
    (let ((base (+ sb!vm:instance-slots-offset
		   sb!kernel:layout-clos-hash-length
		   1)))
      ;; (Offset 0 is CLASS, "the class this is a layout for", which
      ;; is uninitialized at this point.)
      (write-wordindexed result (+ base 1) *nil-descriptor*) ; marked invalid
      (write-wordindexed result (+ base 2) inherits)
      (write-wordindexed result (+ base 3) depthoid)
      (write-wordindexed result (+ base 4) length)
      (write-wordindexed result (+ base 5) *nil-descriptor*) ; info
      (write-wordindexed result (+ base 6) *nil-descriptor*)) ; pure

    (setf (gethash name *cold-layouts*)
	  (list result
		name
		(descriptor-fixnum length)
		(listify-cold-inherits inherits)
		(descriptor-fixnum depthoid)))
    (setf (gethash (descriptor-bits result) *cold-layout-names*) name)

    result))

(defun initialize-layouts ()

  (clrhash *cold-layouts*)

  ;; We initially create the layout of LAYOUT itself with NIL as the LAYOUT and
  ;; #() as INHERITS,
  (setq *layout-layout* *nil-descriptor*)
  (setq *layout-layout*
	(make-cold-layout 'layout
			  (number-to-core target-layout-length)
			  (vector-in-core)
			  ;; FIXME: hard-coded LAYOUT-DEPTHOID of LAYOUT..
			  (number-to-core 4)))
  (write-wordindexed *layout-layout*
		     sb!vm:instance-slots-offset
		     *layout-layout*)

  ;; Then we create the layouts that we'll need to make a correct INHERITS
  ;; vector for the layout of LAYOUT itself..
  ;;
  ;; FIXME: The various LENGTH and DEPTHOID numbers should be taken from
  ;; the compiler's tables, not set by hand.
  (let* ((t-layout
	  (make-cold-layout 't
			    (number-to-core 0)
			    (vector-in-core)
			    (number-to-core 0)))
	 (i-layout
	  (make-cold-layout 'instance
			    (number-to-core 0)
			    (vector-in-core t-layout)
			    (number-to-core 1)))
	 (so-layout
	  (make-cold-layout 'structure-object
			    (number-to-core 1)
			    (vector-in-core t-layout i-layout)
			    (number-to-core 2)))
	 (bso-layout
	  (make-cold-layout 'structure!object
			    (number-to-core 1)
			    (vector-in-core t-layout i-layout so-layout)
			    (number-to-core 3)))
	 (layout-inherits (vector-in-core t-layout
					  i-layout
					  so-layout
					  bso-layout)))

    ;; ..and return to backpatch the layout of LAYOUT.
    (setf (fourth (gethash 'layout *cold-layouts*))
	  (listify-cold-inherits layout-inherits))
    (write-wordindexed *layout-layout*
		       ;; FIXME: hardcoded offset into layout struct
		       (+ sb!vm:instance-slots-offset
			  layout-clos-hash-length
			  1
			  2)
		       layout-inherits)))

;;;; interning symbols in the cold image

;;; In order to avoid having to know about the package format, we
;;; build a data structure in *COLD-PACKAGE-SYMBOLS* that holds all
;;; interned symbols along with info about their packages. The data
;;; structure is a list of sublists, where the sublists have the
;;; following format:
;;;   (<make-package-arglist>
;;;    <internal-symbols>
;;;    <external-symbols>
;;;    <imported-internal-symbols>
;;;    <imported-external-symbols>
;;;    <shadowing-symbols>)
;;;
;;; KLUDGE: It would be nice to implement the sublists as instances of
;;; a DEFSTRUCT (:TYPE LIST). (They'd still be lists, but at least we'd be
;;; using mnemonically-named operators to access them, instead of trying
;;; to remember what THIRD and FIFTH mean, and hoping that we never
;;; need to change the list layout..) -- WHN 19990825

;;; an alist from packages to lists of that package's symbols to be dumped
(defvar *cold-package-symbols*)
(declaim (type list *cold-package-symbols*))

;;; a map from descriptors to symbols, so that we can back up. The key is the
;;; address in the target core.
(defvar *cold-symbols*)
(declaim (type hash-table *cold-symbols*))

;;; Return a handle on an interned symbol. If necessary allocate the
;;; symbol and record which package the symbol was referenced in. When
;;; we allocate the symbol, make sure we record a reference to the
;;; symbol in the home package so that the package gets set.
(defun cold-intern (symbol &optional (package (symbol-package symbol)))

  ;; Anything on the cross-compilation host which refers to the target
  ;; machinery through the host SB-XC package can be translated to
  ;; something on the target which refers to the same machinery
  ;; through the target COMMON-LISP package.
  (let ((p (find-package "SB-XC")))
    (when (eq package p)
      (setf package *cl-package*))
    (when (eq (symbol-package symbol) p)
      (setf symbol (intern (symbol-name symbol) *cl-package*))))

  (let (;; Information about each cold-interned symbol is stored
	;; in COLD-INTERN-INFO.
	;;   (CAR COLD-INTERN-INFO) = descriptor of symbol
	;;   (CDR COLD-INTERN-INFO) = list of packages, other than symbol's
	;;			    own package, referring to symbol
	;; (*COLD-PACKAGE-SYMBOLS* and *COLD-SYMBOLS* store basically the
	;; same information, but with the mapping running the opposite way.)
	(cold-intern-info (get symbol 'cold-intern-info)))
    (unless cold-intern-info
      (cond ((eq (symbol-package symbol) package)
	     (let ((handle (allocate-symbol (symbol-name symbol))))
	       (setf (gethash (descriptor-bits handle) *cold-symbols*) symbol)
	       (when (eq package *keyword-package*)
		 (cold-set handle handle))
	       (setq cold-intern-info
		     (setf (get symbol 'cold-intern-info) (cons handle nil)))))
	    (t
	     (cold-intern symbol)
	     (setq cold-intern-info (get symbol 'cold-intern-info)))))
    (unless (or (null package)
		(member package (cdr cold-intern-info)))
      (push package (cdr cold-intern-info))
      (let* ((old-cps-entry (assoc package *cold-package-symbols*))
	     (cps-entry (or old-cps-entry
			    (car (push (list package)
				       *cold-package-symbols*)))))
	(unless old-cps-entry
	  (/show "created *COLD-PACKAGE-SYMBOLS* entry for" package symbol))
	(push symbol (rest cps-entry))))
    (car cold-intern-info)))

;;; Construct and return a value for use as *NIL-DESCRIPTOR*.
(defun make-nil-descriptor ()
  (let* ((des (allocate-unboxed-object
	       *static*
	       sb!vm:word-bits
	       sb!vm:symbol-size
	       0))
	 (result (make-descriptor (descriptor-high des)
				  (+ (descriptor-low des)
				     (* 2 sb!vm:word-bytes)
				     (- sb!vm:list-pointer-type
					sb!vm:other-pointer-type)))))
    (write-wordindexed des
		       1
		       (make-other-immediate-descriptor
			0
			sb!vm:symbol-header-type))
    (write-wordindexed des
		       (+ 1 sb!vm:symbol-value-slot)
		       result)
    (write-wordindexed des
		       (+ 2 sb!vm:symbol-value-slot)
		       result)
    (write-wordindexed des
		       (+ 1 sb!vm:symbol-plist-slot)
		       result)
    (write-wordindexed des
		       (+ 1 sb!vm:symbol-name-slot)
		       ;; This is *DYNAMIC*, and DES is *STATIC*,
		       ;; because that's the way CMU CL did it; I'm
		       ;; not sure whether there's an underlying
		       ;; reason. -- WHN 1990826
		       (string-to-core "NIL" *dynamic*))
    (write-wordindexed des
		       (+ 1 sb!vm:symbol-package-slot)
		       result)
    (setf (get nil 'cold-intern-info)
	  (cons result nil))
    (cold-intern nil)
    result))

;;; Since the initial symbols must be allocated before we can intern
;;; anything else, we intern those here. We also set the value of T.
(defun initialize-non-nil-symbols ()
  #!+sb-doc
  "Initialize the cold load symbol-hacking data structures."
  (let ((*cold-symbol-allocation-gspace* *static*))
    ;; Intern the others.
    (dolist (symbol sb!vm:*static-symbols*)
      (let* ((des (cold-intern symbol))
	     (offset-wanted (sb!vm:static-symbol-offset symbol))
	     (offset-found (- (descriptor-low des)
			      (descriptor-low *nil-descriptor*))))
	(unless (= offset-wanted offset-found)
	  ;; FIXME: should be fatal
	  (warn "Offset from ~S to ~S is ~D, not ~D"
		symbol
		nil
		offset-found
		offset-wanted))))
    ;; Establish the value of T.
    (let ((t-symbol (cold-intern t)))
      (cold-set t-symbol t-symbol))))

;;; a helper function for FINISH-SYMBOLS: Return a cold alist suitable
;;; to be stored in *!INITIAL-LAYOUTS*.
(defun cold-list-all-layouts ()
  (let ((result *nil-descriptor*))
    (maphash (lambda (key stuff)
	       (cold-push (cold-cons (cold-intern key)
				     (first stuff))
			  result))
	     *cold-layouts*)
    result))

;;; Establish initial values for magic symbols.
;;;
;;; Scan over all the symbols referenced in each package in
;;; *COLD-PACKAGE-SYMBOLS* making that for each one there's an
;;; appropriate entry in the *!INITIAL-SYMBOLS* data structure to
;;; intern it.
(defun finish-symbols ()

  ;; FIXME: Why use SETQ (setting symbol value) instead of just using
  ;; the function values for these things?? I.e. why do we need this
  ;; section at all? Is it because all the FDEFINITION stuff gets in
  ;; the way of reading function values and is too hairy to rely on at
  ;; cold boot? FIXME: Most of these are in *STATIC-SYMBOLS* in
  ;; parms.lisp, but %HANDLE-FUNCTION-END-BREAKPOINT is not. Why?
  ;; Explain.
  (macrolet ((frob (symbol)
	       `(cold-set ',symbol
			  (cold-fdefinition-object (cold-intern ',symbol)))))
    (frob maybe-gc)
    (frob internal-error)
    (frob sb!di::handle-breakpoint)
    (frob sb!di::handle-function-end-breakpoint))

  (cold-set '*current-catch-block*          (make-fixnum-descriptor 0))
  (cold-set '*current-unwind-protect-block* (make-fixnum-descriptor 0))
  (cold-set '*eval-stack-top*               (make-fixnum-descriptor 0))

  (cold-set '*free-interrupt-context-index* (make-fixnum-descriptor 0))

  (cold-set '*!initial-layouts* (cold-list-all-layouts))

  (/show "dumping packages" (mapcar #'car *cold-package-symbols*))
  (let ((initial-symbols *nil-descriptor*))
    (dolist (cold-package-symbols-entry *cold-package-symbols*)
      (let* ((cold-package (car cold-package-symbols-entry))
	     (symbols (cdr cold-package-symbols-entry))
	     (shadows (package-shadowing-symbols cold-package))
	     (internal *nil-descriptor*)
	     (external *nil-descriptor*)
	     (imported-internal *nil-descriptor*)
	     (imported-external *nil-descriptor*)
	     (shadowing *nil-descriptor*))
	(/show "dumping" cold-package symbols)

	;; FIXME: Add assertions here to make sure that inappropriate stuff
	;; isn't being dumped:
	;;   * the CL-USER package
	;;   * the SB-COLD package
	;;   * any internal symbols in the CL package
	;;   * basically any package other than CL, KEYWORD, or the packages
	;;     in package-data-list.lisp-expr
	;; and that the structure of the KEYWORD package (e.g. whether
	;; any symbols are internal to it) matches what we want in the
	;; target SBCL.

	;; FIXME: It seems possible that by looking at the contents of
	;; packages in the target SBCL we could find which symbols in
	;; package-data-lisp.lisp-expr are now obsolete. (If I
	;; understand correctly, only symbols which actually have
	;; definitions or which are otherwise referred to actually end
	;; up in the target packages.)

	(dolist (symbol symbols)
	  (let ((handle (car (get symbol 'cold-intern-info)))
		(imported-p (not (eq (symbol-package symbol) cold-package))))
	    (multiple-value-bind (found where)
		(find-symbol (symbol-name symbol) cold-package)
	      (unless (and where (eq found symbol))
		(error "The symbol ~S is not available in ~S."
		       symbol
		       cold-package))
	      (when (memq symbol shadows)
		(cold-push handle shadowing))
	      (case where
		(:internal (if imported-p
			       (cold-push handle imported-internal)
			       (cold-push handle internal)))
		(:external (if imported-p
			       (cold-push handle imported-external)
			       (cold-push handle external)))))))
	(let ((r *nil-descriptor*))
	  (cold-push shadowing r)
	  (cold-push imported-external r)
	  (cold-push imported-internal r)
	  (cold-push external r)
	  (cold-push internal r)
	  (cold-push (make-make-package-args cold-package) r)
	  ;; FIXME: It would be more space-efficient to use vectors
	  ;; instead of lists here, and space-efficiency here would be
	  ;; nice, since it would reduce the peak memory usage in
	  ;; genesis and cold init.
	  (cold-push r initial-symbols))))
    (cold-set '*!initial-symbols* initial-symbols))

  (cold-set '*!initial-fdefn-objects* (list-all-fdefn-objects))

  (cold-set '*!reversed-cold-toplevels* *current-reversed-cold-toplevels*)

  #!+x86
  (progn
    (cold-set 'sb!vm::*fp-constant-0d0* (number-to-core 0d0))
    (cold-set 'sb!vm::*fp-constant-1d0* (number-to-core 1d0))
    (cold-set 'sb!vm::*fp-constant-0s0* (number-to-core 0s0))
    (cold-set 'sb!vm::*fp-constant-1s0* (number-to-core 1s0))
    #!+long-float
    (progn
      (cold-set 'sb!vm::*fp-constant-0l0* (number-to-core 0L0))
      (cold-set 'sb!vm::*fp-constant-1l0* (number-to-core 1L0))
      ;; FIXME: Why is initialization of PI conditional on LONG-FLOAT?
      ;; (ditto LG2, LN2, L2E, etc.)
      (cold-set 'sb!vm::*fp-constant-pi* (number-to-core pi))
      (cold-set 'sb!vm::*fp-constant-l2t* (number-to-core (log 10L0 2L0)))
      (cold-set 'sb!vm::*fp-constant-l2e*
	    (number-to-core (log 2.718281828459045235360287471352662L0 2L0)))
      (cold-set 'sb!vm::*fp-constant-lg2* (number-to-core (log 2L0 10L0)))
      (cold-set 'sb!vm::*fp-constant-ln2*
	    (number-to-core
	     (log 2L0 2.718281828459045235360287471352662L0))))))

;;; Make a cold list that can be used as the arg list to MAKE-PACKAGE in order
;;; to make a package that is similar to PKG.
(defun make-make-package-args (pkg)
  (let* ((use *nil-descriptor*)
	 (cold-nicknames *nil-descriptor*)
	 (res *nil-descriptor*))
    (dolist (u (package-use-list pkg))
      (when (assoc u *cold-package-symbols*)
	(cold-push (string-to-core (package-name u)) use)))
    (let* ((pkg-name (package-name pkg))
	   ;; Make the package nickname lists for the standard packages
	   ;; be the minimum specified by ANSI, regardless of what value
	   ;; the cross-compilation host happens to use.
	   (warm-nicknames (cond ((string= pkg-name "COMMON-LISP")
				  '("CL"))
				 ((string= pkg-name "COMMON-LISP-USER")
				  '("CL-USER"))
				 ((string= pkg-name "KEYWORD")
				  '())
				 ;; For packages other than the
				 ;; standard packages, the nickname
				 ;; list was specified by our package
				 ;; setup code, not by properties of
				 ;; what cross-compilation host we
				 ;; happened to use, and we can just
				 ;; propagate it into the target.
				 (t
				  (package-nicknames pkg)))))
      (dolist (warm-nickname warm-nicknames)
	(cold-push (string-to-core warm-nickname) cold-nicknames)))

    (cold-push (number-to-core (truncate (package-internal-symbol-count pkg)
					 0.8))
	       res)
    (cold-push (cold-intern :internal-symbols) res)
    (cold-push (number-to-core (truncate (package-external-symbol-count pkg)
					 0.8))
	       res)
    (cold-push (cold-intern :external-symbols) res)

    (cold-push cold-nicknames res)
    (cold-push (cold-intern :nicknames) res)

    (cold-push use res)
    (cold-push (cold-intern :use) res)

    (cold-push (string-to-core (package-name pkg)) res)
    res))

;;;; functions and fdefinition objects

;;; a hash table mapping from fdefinition names to descriptors of cold
;;; objects
;;;
;;; Note: Since fdefinition names can be lists like '(SETF FOO), and
;;; we want to have only one entry per name, this must be an 'EQUAL
;;; hash table, not the default 'EQL.
(defvar *cold-fdefn-objects*)

(defvar *cold-fdefn-gspace* nil)

;;; Given a cold representation of a symbol, return a warm
;;; representation. 
(defun warm-symbol (des)
  ;; Note that COLD-INTERN is responsible for keeping the
  ;; *COLD-SYMBOLS* table up to date, so if DES happens to refer to an
  ;; uninterned symbol, the code below will fail. But as long as we
  ;; don't need to look up uninterned symbols during bootstrapping,
  ;; that's OK..
  (multiple-value-bind (symbol found-p)
      (gethash (descriptor-bits des) *cold-symbols*)
    (declare (type symbol symbol))
    (unless found-p
      (error "no warm symbol"))
    symbol))
  
;;; like CL:CAR, CL:CDR, and CL:NULL but for cold values
(defun cold-car (des)
  (aver (= (descriptor-lowtag des) sb!vm:list-pointer-type))
  (read-wordindexed des sb!vm:cons-car-slot))
(defun cold-cdr (des)
  (aver (= (descriptor-lowtag des) sb!vm:list-pointer-type))
  (read-wordindexed des sb!vm:cons-cdr-slot))
(defun cold-null (des)
  (= (descriptor-bits des)
     (descriptor-bits *nil-descriptor*)))
  
;;; Given a cold representation of a function name, return a warm
;;; representation.
(declaim (ftype (function (descriptor) (or symbol list)) warm-fun-name))
(defun warm-fun-name (des)
  (let ((result
	 (ecase (descriptor-lowtag des)
	   (#.sb!vm:list-pointer-type
	    (aver (not (cold-null des))) ; function named NIL? please no..
	    ;; Do cold (DESTRUCTURING-BIND (COLD-CAR COLD-CADR) DES ..).
	    (let* ((car-des (cold-car des))
		   (cdr-des (cold-cdr des))
		   (cadr-des (cold-car cdr-des))
		   (cddr-des (cold-cdr cdr-des)))
	      (aver (cold-null cddr-des))
	      (list (warm-symbol car-des)
		    (warm-symbol cadr-des))))
	   (#.sb!vm:other-pointer-type
	    (warm-symbol des)))))
    (unless (legal-function-name-p result)
      (error "not a legal function name: ~S" result))
    result))

(defun cold-fdefinition-object (cold-name &optional leave-fn-raw)
  (declare (type descriptor cold-name))
  (let ((warm-name (warm-fun-name cold-name)))
    (or (gethash warm-name *cold-fdefn-objects*)
	(let ((fdefn (allocate-boxed-object (or *cold-fdefn-gspace* *dynamic*)
					    (1- sb!vm:fdefn-size)
					    sb!vm:other-pointer-type)))

	  (setf (gethash warm-name *cold-fdefn-objects*) fdefn)
	  (write-memory fdefn (make-other-immediate-descriptor
			       (1- sb!vm:fdefn-size) sb!vm:fdefn-type))
	  (write-wordindexed fdefn sb!vm:fdefn-name-slot cold-name)
	  (unless leave-fn-raw
	    (write-wordindexed fdefn sb!vm:fdefn-function-slot
			       *nil-descriptor*)
	    (write-wordindexed fdefn
			       sb!vm:fdefn-raw-addr-slot
			       (make-random-descriptor
				(cold-foreign-symbol-address-as-integer
				 "undefined_tramp"))))
	  fdefn))))

;;; Handle the at-cold-init-time, fset-for-static-linkage operation
;;; requested by FOP-FSET.
(defun static-fset (cold-name defn)
  (declare (type descriptor cold-name))
  (let ((fdefn (cold-fdefinition-object cold-name t))
	(type (logand (descriptor-low (read-memory defn)) sb!vm:type-mask)))
    (write-wordindexed fdefn sb!vm:fdefn-function-slot defn)
    (write-wordindexed fdefn
		       sb!vm:fdefn-raw-addr-slot
		       (ecase type
			 (#.sb!vm:function-header-type
			  #!+sparc
			  defn
			  #!-sparc
			  (make-random-descriptor
			   (+ (logandc2 (descriptor-bits defn)
					sb!vm:lowtag-mask)
			      (ash sb!vm:function-code-offset
				   sb!vm:word-shift))))
			 (#.sb!vm:closure-header-type
			  (make-random-descriptor
			   (cold-foreign-symbol-address-as-integer "closure_tramp")))))
    fdefn))

(defun initialize-static-fns ()
  (let ((*cold-fdefn-gspace* *static*))
    (dolist (sym sb!vm:*static-functions*)
      (let* ((fdefn (cold-fdefinition-object (cold-intern sym)))
	     (offset (- (+ (- (descriptor-low fdefn)
			      sb!vm:other-pointer-type)
			   (* sb!vm:fdefn-raw-addr-slot sb!vm:word-bytes))
			(descriptor-low *nil-descriptor*)))
	     (desired (sb!vm:static-function-offset sym)))
	(unless (= offset desired)
	  ;; FIXME: should be fatal
	  (warn "Offset from FDEFN ~S to ~S is ~D, not ~D."
		sym nil offset desired))))))

(defun list-all-fdefn-objects ()
  (let ((result *nil-descriptor*))
    (maphash #'(lambda (key value)
		 (declare (ignore key))
		 (cold-push value result))
	     *cold-fdefn-objects*)
    result))

;;;; fixups and related stuff

;;; an EQUAL hash table
(defvar *cold-foreign-symbol-table*)
(declaim (type hash-table *cold-foreign-symbol-table*))

;;; Read the sbcl.nm file to find the addresses for foreign-symbols in
;;; the C runtime.  
(defun load-cold-foreign-symbol-table (filename)
  (with-open-file (file filename)
    (loop
      (let ((line (read-line file nil nil)))
	(unless line
	  (return))
	;; UNIX symbol tables might have tabs in them, and tabs are
	;; not in Common Lisp STANDARD-CHAR, so there seems to be no
	;; nice portable way to deal with them within Lisp, alas.
	;; Fortunately, it's easy to use UNIX command line tools like
	;; sed to remove the problem, so it's not too painful for us
	;; to push responsibility for converting tabs to spaces out to
	;; the caller.
	;;
	;; Other non-STANDARD-CHARs are problematic for the same reason.
	;; Make sure that there aren't any..
	(let ((ch (find-if (lambda (char)
			     (not (typep char 'standard-char)))
			  line)))
	  (when ch
	    (error "non-STANDARD-CHAR ~S found in foreign symbol table:~%~S"
		   ch
		   line)))
	(setf line (string-trim '(#\space) line))
	(let ((p1 (position #\space line :from-end nil))
	      (p2 (position #\space line :from-end t)))
	  (if (not (and p1 p2 (< p1 p2)))
	      ;; KLUDGE: It's too messy to try to understand all
	      ;; possible output from nm, so we just punt the lines we
	      ;; don't recognize. We realize that there's some chance
	      ;; that might get us in trouble someday, so we warn
	      ;; about it.
	      (warn "ignoring unrecognized line ~S in ~A" line filename)
	      (multiple-value-bind (value name)
		  (if (string= "0x" line :end2 2)
		      (values (parse-integer line :start 2 :end p1 :radix 16)
			      (subseq line (1+ p2)))
		      (values (parse-integer line :end p1 :radix 16)
			      (subseq line (1+ p2))))
		(multiple-value-bind (old-value found)
		    (gethash name *cold-foreign-symbol-table*)
		  (when (and found
			     (not (= old-value value)))
		    (warn "redefining ~S from #X~X to #X~X"
			  name old-value value)))
		(setf (gethash name *cold-foreign-symbol-table*) value))))))
    (values)))

(defun cold-foreign-symbol-address-as-integer (name)
  (or (find-foreign-symbol-in-table name *cold-foreign-symbol-table*)
      *foreign-symbol-placeholder-value*
      (progn
        (format *error-output* "~&The foreign symbol table is:~%")
        (maphash (lambda (k v)
                   (format *error-output* "~&~S = #X~8X~%" k v))
                 *cold-foreign-symbol-table*)
        (error "The foreign symbol ~S is undefined." name))))

(defvar *cold-assembler-routines*)

(defvar *cold-assembler-fixups*)

(defun record-cold-assembler-routine (name address)
  (/xhow "in RECORD-COLD-ASSEMBLER-ROUTINE" name address)
  (push (cons name address)
	*cold-assembler-routines*))

(defun record-cold-assembler-fixup (routine
				    code-object
				    offset
				    &optional
				    (kind :both))
  (push (list routine code-object offset kind)
	*cold-assembler-fixups*))

(defun lookup-assembler-reference (symbol)
  (let ((value (cdr (assoc symbol *cold-assembler-routines*))))
    ;; FIXME: Should this be ERROR instead of WARN?
    (unless value
      (warn "Assembler routine ~S not defined." symbol))
    value))

;;; The x86 port needs to store code fixups along with code objects if
;;; they are to be moved, so fixups for code objects in the dynamic
;;; heap need to be noted.
#!+x86
(defvar *load-time-code-fixups*)

#!+x86
(defun note-load-time-code-fixup (code-object offset value kind)
  ;; If CODE-OBJECT might be moved
  (when (= (gspace-identifier (descriptor-intuit-gspace code-object))
	   dynamic-space-id)
    ;; FIXME: pushed thing should be a structure, not just a list
    (push (list code-object offset value kind) *load-time-code-fixups*))
  (values))

#!+x86
(defun output-load-time-code-fixups ()
  (dolist (fixups *load-time-code-fixups*)
    (let ((code-object (first fixups))
	  (offset (second fixups))
	  (value (third fixups))
	  (kind (fourth fixups)))
      (cold-push (cold-cons
		  (cold-intern :load-time-code-fixup)
		  (cold-cons
		   code-object
		   (cold-cons
		    (number-to-core offset)
		    (cold-cons
		     (number-to-core value)
		     (cold-cons
		      (cold-intern kind)
		      *nil-descriptor*)))))
		 *current-reversed-cold-toplevels*))))

;;; Given a pointer to a code object and an offset relative to the
;;; tail of the code object's header, return an offset relative to the
;;; (beginning of the) code object.
;;;
;;; FIXME: It might be clearer to reexpress
;;;    (LET ((X (CALC-OFFSET CODE-OBJECT OFFSET0))) ..)
;;; as
;;;    (LET ((X (+ OFFSET0 (CODE-OBJECT-HEADER-N-BYTES CODE-OBJECT)))) ..).
(declaim (ftype (function (descriptor sb!vm:word)) calc-offset))
(defun calc-offset (code-object offset-from-tail-of-header)
  (let* ((header (read-memory code-object))
	 (header-n-words (ash (descriptor-bits header) (- sb!vm:type-bits)))
	 (header-n-bytes (ash header-n-words sb!vm:word-shift))
	 (result (+ offset-from-tail-of-header header-n-bytes)))
    result))

(declaim (ftype (function (descriptor sb!vm:word sb!vm:word keyword))
		do-cold-fixup))
(defun do-cold-fixup (code-object after-header value kind)
  (let* ((offset-within-code-object (calc-offset code-object after-header))
	 (gspace-bytes (descriptor-bytes code-object))
	 (gspace-byte-offset (+ (descriptor-byte-offset code-object)
				offset-within-code-object))
	 (gspace-byte-address (gspace-byte-address
			       (descriptor-gspace code-object))))
    (ecase +backend-fasl-file-implementation+
      ;; See CMU CL source for other formerly-supported architectures
      ;; (and note that you have to rewrite them to use VECTOR-REF
      ;; unstead of SAP-REF).
      (:alpha
	 (ecase kind
         (:jmp-hint
          (assert (zerop (ldb (byte 2 0) value)))
          #+nil ;; was commented out in cmucl source too.  Don't know what
          ;; it does   -dan 2001.05.03
	    (setf (sap-ref-16 sap 0)
                (logior (sap-ref-16 sap 0) (ldb (byte 14 0) (ash value -2)))))
	 (:bits-63-48
	  (let* ((value (if (logbitp 15 value) (+ value (ash 1 16)) value))
		 (value (if (logbitp 31 value) (+ value (ash 1 32)) value))
		 (value (if (logbitp 47 value) (+ value (ash 1 48)) value)))
	    (setf (byte-vector-ref-8 gspace-bytes gspace-byte-offset)
                  (ldb (byte 8 48) value)
                  (byte-vector-ref-8 gspace-bytes (1+ gspace-byte-offset))
                  (ldb (byte 8 56) value))))
	 (:bits-47-32
	  (let* ((value (if (logbitp 15 value) (+ value (ash 1 16)) value))
		 (value (if (logbitp 31 value) (+ value (ash 1 32)) value)))
	    (setf (byte-vector-ref-8 gspace-bytes gspace-byte-offset)
                  (ldb (byte 8 32) value)
                  (byte-vector-ref-8 gspace-bytes (1+ gspace-byte-offset))
                  (ldb (byte 8 40) value))))
	 (:ldah
	  (let ((value (if (logbitp 15 value) (+ value (ash 1 16)) value)))
	    (setf (byte-vector-ref-8 gspace-bytes gspace-byte-offset)
                  (ldb (byte 8 16) value)
                  (byte-vector-ref-8 gspace-bytes (1+ gspace-byte-offset))
                  (ldb (byte 8 24) value))))
	 (:lda
	  (setf (byte-vector-ref-8 gspace-bytes gspace-byte-offset)
                (ldb (byte 8 0) value)
                (byte-vector-ref-8 gspace-bytes (1+ gspace-byte-offset))
                (ldb (byte 8 8) value)))))
      (:x86
       (let* ((un-fixed-up (byte-vector-ref-32 gspace-bytes
					       gspace-byte-offset))
	      (code-object-start-addr (logandc2 (descriptor-bits code-object)
						sb!vm:lowtag-mask)))
         (assert (= code-object-start-addr
		  (+ gspace-byte-address
		     (descriptor-byte-offset code-object))))
	 (ecase kind
	   (:absolute
	    (let ((fixed-up (+ value un-fixed-up)))
	      (setf (byte-vector-ref-32 gspace-bytes gspace-byte-offset)
		    fixed-up)
	      ;; comment from CMU CL sources:
	      ;;
	      ;; Note absolute fixups that point within the object.
	      ;; KLUDGE: There seems to be an implicit assumption in
	      ;; the old CMU CL code here, that if it doesn't point
	      ;; before the object, it must point within the object
	      ;; (not beyond it). It would be good to add an
	      ;; explanation of why that's true, or an assertion that
	      ;; it's really true, or both.
	      (unless (< fixed-up code-object-start-addr)
		(note-load-time-code-fixup code-object
					   after-header
					   value
					   kind))))
	   (:relative ; (used for arguments to X86 relative CALL instruction)
	    (let ((fixed-up (- (+ value un-fixed-up)
			       gspace-byte-address
			       gspace-byte-offset
			       sb!vm:word-bytes))) ; length of CALL argument
	      (setf (byte-vector-ref-32 gspace-bytes gspace-byte-offset)
		    fixed-up)
	      ;; Note relative fixups that point outside the code
	      ;; object, which is to say all relative fixups, since
	      ;; relative addressing within a code object never needs
	      ;; a fixup.
	      (note-load-time-code-fixup code-object
					 after-header
					 value
					 kind)))))) ))
  (values))

(defun resolve-assembler-fixups ()
  (dolist (fixup *cold-assembler-fixups*)
    (let* ((routine (car fixup))
	   (value (lookup-assembler-reference routine)))
      (when value
	(do-cold-fixup (second fixup) (third fixup) value (fourth fixup))))))

;;; *COLD-FOREIGN-SYMBOL-TABLE* becomes *!INITIAL-FOREIGN-SYMBOLS* in
;;; the core. When the core is loaded, !LOADER-COLD-INIT uses this to
;;; create *STATIC-FOREIGN-SYMBOLS*, which the code in
;;; target-load.lisp refers to.
(defun linkage-info-to-core ()
  (let ((result *nil-descriptor*))
    (maphash (lambda (symbol value)
	       (cold-push (cold-cons (string-to-core symbol)
				     (number-to-core value))
			  result))
	     *cold-foreign-symbol-table*)
    (cold-set (cold-intern '*!initial-foreign-symbols*) result))
  (let ((result *nil-descriptor*))
    (dolist (rtn *cold-assembler-routines*)
      (cold-push (cold-cons (cold-intern (car rtn))
			    (number-to-core (cdr rtn)))
		 result))
    (cold-set (cold-intern '*!initial-assembler-routines*) result)))

;;;; general machinery for cold-loading FASL files

;;; FOP functions for cold loading
(defvar *cold-fop-functions*
  ;; We start out with a copy of the ordinary *FOP-FUNCTIONS*. The
  ;; ones which aren't appropriate for cold load will be destructively
  ;; modified.
  (copy-seq *fop-functions*))

(defvar *normal-fop-functions*)

;;; Cause a fop to have a special definition for cold load.
;;; 
;;; This is similar to DEFINE-FOP, but unlike DEFINE-FOP, this version
;;;   (1) looks up the code for this name (created by a previous
;;        DEFINE-FOP) instead of creating a code, and
;;;   (2) stores its definition in the *COLD-FOP-FUNCTIONS* vector,
;;;       instead of storing in the *FOP-FUNCTIONS* vector.
(defmacro define-cold-fop ((name &optional (pushp t)) &rest forms)
  (aver (member pushp '(nil t :nope)))
  (let ((code (get name 'fop-code))
	(fname (symbolicate "COLD-" name)))
    (unless code
      (error "~S is not a defined FOP." name))
    `(progn
       (defun ,fname ()
	 ,@(if (eq pushp :nope)
	     forms
	     `((with-fop-stack ,pushp ,@forms))))
       (setf (svref *cold-fop-functions* ,code) #',fname))))

(defmacro clone-cold-fop ((name &optional (pushp t)) (small-name) &rest forms)
  (aver (member pushp '(nil t :nope)))
  `(progn
    (macrolet ((clone-arg () '(read-arg 4)))
      (define-cold-fop (,name ,pushp) ,@forms))
    (macrolet ((clone-arg () '(read-arg 1)))
      (define-cold-fop (,small-name ,pushp) ,@forms))))

;;; Cause a fop to be undefined in cold load.
(defmacro not-cold-fop (name)
  `(define-cold-fop (,name)
     (error "The fop ~S is not supported in cold load." ',name)))

;;; COLD-LOAD loads stuff into the core image being built by calling
;;; LOAD-AS-FASL with the fop function table rebound to a table of cold
;;; loading functions.
(defun cold-load (filename)
  #!+sb-doc
  "Load the file named by FILENAME into the cold load image being built."
  (let* ((*normal-fop-functions* *fop-functions*)
	 (*fop-functions* *cold-fop-functions*)
	 (*cold-load-filename* (etypecase filename
				 (string filename)
				 (pathname (namestring filename)))))
    (with-open-file (s filename :element-type '(unsigned-byte 8))
      (load-as-fasl s nil nil))))

;;;; miscellaneous cold fops

(define-cold-fop (fop-misc-trap) *unbound-marker*)

(define-cold-fop (fop-character)
  (make-character-descriptor (read-arg 3)))
(define-cold-fop (fop-short-character)
  (make-character-descriptor (read-arg 1)))

(define-cold-fop (fop-empty-list) *nil-descriptor*)
(define-cold-fop (fop-truth) (cold-intern t))

(define-cold-fop (fop-normal-load :nope)
  (setq *fop-functions* *normal-fop-functions*))

(define-fop (fop-maybe-cold-load 82 :nope)
  (when *cold-load-filename*
    (setq *fop-functions* *cold-fop-functions*)))

(define-cold-fop (fop-maybe-cold-load :nope))

(clone-cold-fop (fop-struct)
		(fop-small-struct)
  (let* ((size (clone-arg))
	 (result (allocate-boxed-object *dynamic*
					(1+ size)
					sb!vm:instance-pointer-type)))
    (write-memory result (make-other-immediate-descriptor
			  size
			  sb!vm:instance-header-type))
    (do ((index (1- size) (1- index)))
	((minusp index))
      (declare (fixnum index))
      (write-wordindexed result
			 (+ index sb!vm:instance-slots-offset)
			 (pop-stack)))
    result))

(define-cold-fop (fop-layout)
  (let* ((length-des (pop-stack))
	 (depthoid-des (pop-stack))
	 (cold-inherits (pop-stack))
	 (name (pop-stack))
	 (old (gethash name *cold-layouts*)))
    (declare (type descriptor length-des depthoid-des cold-inherits))
    (declare (type symbol name))
    ;; If a layout of this name has been defined already
    (if old
      ;; Enforce consistency between the previous definition and the
      ;; current definition, then return the previous definition.
      (destructuring-bind
	  ;; FIXME: This would be more maintainable if we used
	  ;; DEFSTRUCT (:TYPE LIST) to define COLD-LAYOUT. -- WHN 19990825
	  (old-layout-descriptor
	   old-name
	   old-length
	   old-inherits-list
	   old-depthoid)
	  old
	(declare (type descriptor old-layout-descriptor))
	(declare (type index old-length))
	(declare (type fixnum old-depthoid))
	(declare (type list old-inherits-list))
	(aver (eq name old-name))
	(let ((length (descriptor-fixnum length-des))
	      (inherits-list (listify-cold-inherits cold-inherits))
	      (depthoid (descriptor-fixnum depthoid-des)))
	  (unless (= length old-length)
	    (error "cold loading a reference to class ~S when the compile~%~
		   time length was ~S and current length is ~S"
		   name
		   length
		   old-length))
	  (unless (equal inherits-list old-inherits-list)
	    (error "cold loading a reference to class ~S when the compile~%~
		   time inherits were ~S~%~
		   and current inherits are ~S"
		   name
		   inherits-list
		   old-inherits-list))
	  (unless (= depthoid old-depthoid)
	    (error "cold loading a reference to class ~S when the compile~%~
		   time inheritance depthoid was ~S and current inheritance~%~
		   depthoid is ~S"
		   name
		   depthoid
		   old-depthoid)))
	old-layout-descriptor)
      ;; Make a new definition from scratch.
      (make-cold-layout name length-des cold-inherits depthoid-des))))

;;;; cold fops for loading symbols

;;; Load a symbol SIZE characters long from *FASL-INPUT-STREAM* and
;;; intern that symbol in PACKAGE.
(defun cold-load-symbol (size package)
  (let ((string (make-string size)))
    (read-string-as-bytes *fasl-input-stream* string)
    (cold-intern (intern string package) package)))

(macrolet ((frob (name pname-len package-len)
	     `(define-cold-fop (,name)
		(let ((index (read-arg ,package-len)))
		  (push-fop-table
		   (cold-load-symbol (read-arg ,pname-len)
				     (svref *current-fop-table* index)))))))
  (frob fop-symbol-in-package-save 4 4)
  (frob fop-small-symbol-in-package-save 1 4)
  (frob fop-symbol-in-byte-package-save 4 1)
  (frob fop-small-symbol-in-byte-package-save 1 1))

(clone-cold-fop (fop-lisp-symbol-save)
		(fop-lisp-small-symbol-save)
  (push-fop-table (cold-load-symbol (clone-arg) *cl-package*)))

(clone-cold-fop (fop-keyword-symbol-save)
		(fop-keyword-small-symbol-save)
  (push-fop-table (cold-load-symbol (clone-arg) *keyword-package*)))

(clone-cold-fop (fop-uninterned-symbol-save)
		(fop-uninterned-small-symbol-save)
  (let* ((size (clone-arg))
	 (name (make-string size)))
    (read-string-as-bytes *fasl-input-stream* name)
    (let ((symbol-des (allocate-symbol name)))
      (push-fop-table symbol-des))))

;;;; cold fops for loading lists

;;; Make a list of the top LENGTH things on the fop stack. The last
;;; cdr of the list is set to LAST.
(defmacro cold-stack-list (length last)
  `(do* ((index ,length (1- index))
	 (result ,last (cold-cons (pop-stack) result)))
	((= index 0) result)
     (declare (fixnum index))))

(define-cold-fop (fop-list)
  (cold-stack-list (read-arg 1) *nil-descriptor*))
(define-cold-fop (fop-list*)
  (cold-stack-list (read-arg 1) (pop-stack)))
(define-cold-fop (fop-list-1)
  (cold-stack-list 1 *nil-descriptor*))
(define-cold-fop (fop-list-2)
  (cold-stack-list 2 *nil-descriptor*))
(define-cold-fop (fop-list-3)
  (cold-stack-list 3 *nil-descriptor*))
(define-cold-fop (fop-list-4)
  (cold-stack-list 4 *nil-descriptor*))
(define-cold-fop (fop-list-5)
  (cold-stack-list 5 *nil-descriptor*))
(define-cold-fop (fop-list-6)
  (cold-stack-list 6 *nil-descriptor*))
(define-cold-fop (fop-list-7)
  (cold-stack-list 7 *nil-descriptor*))
(define-cold-fop (fop-list-8)
  (cold-stack-list 8 *nil-descriptor*))
(define-cold-fop (fop-list*-1)
  (cold-stack-list 1 (pop-stack)))
(define-cold-fop (fop-list*-2)
  (cold-stack-list 2 (pop-stack)))
(define-cold-fop (fop-list*-3)
  (cold-stack-list 3 (pop-stack)))
(define-cold-fop (fop-list*-4)
  (cold-stack-list 4 (pop-stack)))
(define-cold-fop (fop-list*-5)
  (cold-stack-list 5 (pop-stack)))
(define-cold-fop (fop-list*-6)
  (cold-stack-list 6 (pop-stack)))
(define-cold-fop (fop-list*-7)
  (cold-stack-list 7 (pop-stack)))
(define-cold-fop (fop-list*-8)
  (cold-stack-list 8 (pop-stack)))

;;;; cold fops for loading vectors

(clone-cold-fop (fop-string)
		(fop-small-string)
  (let* ((len (clone-arg))
	 (string (make-string len)))
    (read-string-as-bytes *fasl-input-stream* string)
    (string-to-core string)))

(clone-cold-fop (fop-vector)
		(fop-small-vector)
  (let* ((size (clone-arg))
	 (result (allocate-vector-object *dynamic*
					 sb!vm:word-bits
					 size
					 sb!vm:simple-vector-type)))
    (do ((index (1- size) (1- index)))
	((minusp index))
      (declare (fixnum index))
      (write-wordindexed result
			 (+ index sb!vm:vector-data-offset)
			 (pop-stack)))
    result))

(define-cold-fop (fop-int-vector)
  (let* ((len (read-arg 4))
	 (sizebits (read-arg 1))
	 (type (case sizebits
		 (1 sb!vm:simple-bit-vector-type)
		 (2 sb!vm:simple-array-unsigned-byte-2-type)
		 (4 sb!vm:simple-array-unsigned-byte-4-type)
		 (8 sb!vm:simple-array-unsigned-byte-8-type)
		 (16 sb!vm:simple-array-unsigned-byte-16-type)
		 (32 sb!vm:simple-array-unsigned-byte-32-type)
		 (t (error "losing element size: ~D" sizebits))))
	 (result (allocate-vector-object *dynamic* sizebits len type))
	 (start (+ (descriptor-byte-offset result)
		   (ash sb!vm:vector-data-offset sb!vm:word-shift)))
	 (end (+ start
		 (ceiling (* len sizebits)
			  sb!vm:byte-bits))))
    (read-sequence-or-die (descriptor-bytes result)
			  *fasl-input-stream*
			  :start start
			  :end end)
    result))

(define-cold-fop (fop-single-float-vector)
  (let* ((len (read-arg 4))
	 (result (allocate-vector-object *dynamic*
					 sb!vm:word-bits
					 len
					 sb!vm:simple-array-single-float-type))
	 (start (+ (descriptor-byte-offset result)
		   (ash sb!vm:vector-data-offset sb!vm:word-shift)))
	 (end (+ start (* len sb!vm:word-bytes))))
    (read-sequence-or-die (descriptor-bytes result)
			  *fasl-input-stream*
			  :start start
			  :end end)
    result))

(not-cold-fop fop-double-float-vector)
#!+long-float (not-cold-fop fop-long-float-vector)
(not-cold-fop fop-complex-single-float-vector)
(not-cold-fop fop-complex-double-float-vector)
#!+long-float (not-cold-fop fop-complex-long-float-vector)

(define-cold-fop (fop-array)
  (let* ((rank (read-arg 4))
	 (data-vector (pop-stack))
	 (result (allocate-boxed-object *dynamic*
					(+ sb!vm:array-dimensions-offset rank)
					sb!vm:other-pointer-type)))
    (write-memory result
		  (make-other-immediate-descriptor rank
						   sb!vm:simple-array-type))
    (write-wordindexed result sb!vm:array-fill-pointer-slot *nil-descriptor*)
    (write-wordindexed result sb!vm:array-data-slot data-vector)
    (write-wordindexed result sb!vm:array-displacement-slot *nil-descriptor*)
    (write-wordindexed result sb!vm:array-displaced-p-slot *nil-descriptor*)
    (let ((total-elements 1))
      (dotimes (axis rank)
	(let ((dim (pop-stack)))
	  (unless (or (= (descriptor-lowtag dim) sb!vm:even-fixnum-type)
		      (= (descriptor-lowtag dim) sb!vm:odd-fixnum-type))
	    (error "non-fixnum dimension? (~S)" dim))
	  (setf total-elements
		(* total-elements
		   (logior (ash (descriptor-high dim)
				(- descriptor-low-bits (1- sb!vm:lowtag-bits)))
			   (ash (descriptor-low dim)
				(- 1 sb!vm:lowtag-bits)))))
	  (write-wordindexed result
			     (+ sb!vm:array-dimensions-offset axis)
			     dim)))
      (write-wordindexed result
			 sb!vm:array-elements-slot
			 (make-fixnum-descriptor total-elements)))
    result))

;;;; cold fops for loading numbers

(defmacro define-cold-number-fop (fop)
  `(define-cold-fop (,fop :nope)
     ;; Invoke the ordinary warm version of this fop to push the
     ;; number.
     (,fop)
     ;; Replace the warm fop result with the cold image of the warm
     ;; fop result.
     (with-fop-stack t
       (let ((number (pop-stack)))
	 (number-to-core number)))))

(define-cold-number-fop fop-single-float)
(define-cold-number-fop fop-double-float)
(define-cold-number-fop fop-integer)
(define-cold-number-fop fop-small-integer)
(define-cold-number-fop fop-word-integer)
(define-cold-number-fop fop-byte-integer)
(define-cold-number-fop fop-complex-single-float)
(define-cold-number-fop fop-complex-double-float)

#!+long-float
(define-cold-fop (fop-long-float)
  (ecase +backend-fasl-file-implementation+
    (:x86 ; (which has 80-bit long-float format)
     (prepare-for-fast-read-byte *fasl-input-stream*
       (let* ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits
					    (1- sb!vm:long-float-size)
					    sb!vm:long-float-type))
	      (low-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (high-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (exp-bits (make-random-descriptor (fast-read-s-integer 2))))
	 (done-with-fast-read-byte)
	 (write-wordindexed des sb!vm:long-float-value-slot low-bits)
	 (write-wordindexed des (1+ sb!vm:long-float-value-slot) high-bits)
	 (write-wordindexed des (+ 2 sb!vm:long-float-value-slot) exp-bits)
	 des)))
    ;; This was supported in CMU CL, but isn't currently supported in
    ;; SBCL.
    #+nil
    (#.sb!c:sparc-fasl-file-implementation ; 128 bit long-float format
     (prepare-for-fast-read-byte *fasl-input-stream*
       (let* ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits
					    (1- sb!vm:long-float-size)
					    sb!vm:long-float-type))
	      (low-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (mid-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (high-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (exp-bits (make-random-descriptor (fast-read-s-integer 4))))
	 (done-with-fast-read-byte)
	 (write-wordindexed des sb!vm:long-float-value-slot exp-bits)
	 (write-wordindexed des (1+ sb!vm:long-float-value-slot) high-bits)
	 (write-wordindexed des (+ 2 sb!vm:long-float-value-slot) mid-bits)
	 (write-wordindexed des (+ 3 sb!vm:long-float-value-slot) low-bits)
	 des)))))

#!+long-float
(define-cold-fop (fop-complex-long-float)
  (ecase +backend-fasl-file-implementation+
    (:x86 ; (which has 80-bit long-float format)
     (prepare-for-fast-read-byte *fasl-input-stream*
       (let* ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits
					    (1- sb!vm:complex-long-float-size)
					    sb!vm:complex-long-float-type))
	      (real-low-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (real-high-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (real-exp-bits (make-random-descriptor (fast-read-s-integer 2)))
	      (imag-low-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (imag-high-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (imag-exp-bits (make-random-descriptor (fast-read-s-integer 2))))
	 (done-with-fast-read-byte)
	 (write-wordindexed des
			    sb!vm:complex-long-float-real-slot
			    real-low-bits)
	 (write-wordindexed des
			    (1+ sb!vm:complex-long-float-real-slot)
			    real-high-bits)
	 (write-wordindexed des
			    (+ 2 sb!vm:complex-long-float-real-slot)
			    real-exp-bits)
	 (write-wordindexed des
			    sb!vm:complex-long-float-imag-slot
			    imag-low-bits)
	 (write-wordindexed des
			    (1+ sb!vm:complex-long-float-imag-slot)
			    imag-high-bits)
	 (write-wordindexed des
			    (+ 2 sb!vm:complex-long-float-imag-slot)
			    imag-exp-bits)
	 des)))
    ;; This was supported in CMU CL, but isn't currently supported in SBCL.
    #+nil
    (#.sb!c:sparc-fasl-file-implementation ; 128 bit long-float format
     (prepare-for-fast-read-byte *fasl-input-stream*
       (let* ((des (allocate-unboxed-object *dynamic* sb!vm:word-bits
					    (1- sb!vm:complex-long-float-size)
					    sb!vm:complex-long-float-type))
	      (real-low-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (real-mid-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (real-high-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (real-exp-bits (make-random-descriptor (fast-read-s-integer 4)))
	      (imag-low-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (imag-mid-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (imag-high-bits (make-random-descriptor (fast-read-u-integer 4)))
	      (imag-exp-bits (make-random-descriptor (fast-read-s-integer 4))))
	 (done-with-fast-read-byte)
	 (write-wordindexed des
			    sb!vm:complex-long-float-real-slot
			    real-exp-bits)
	 (write-wordindexed des
			    (1+ sb!vm:complex-long-float-real-slot)
			    real-high-bits)
	 (write-wordindexed des
			    (+ 2 sb!vm:complex-long-float-real-slot)
			    real-mid-bits)
	 (write-wordindexed des
			    (+ 3 sb!vm:complex-long-float-real-slot)
			    real-low-bits)
	 (write-wordindexed des
			    sb!vm:complex-long-float-real-slot
			    imag-exp-bits)
	 (write-wordindexed des
			    (1+ sb!vm:complex-long-float-real-slot)
			    imag-high-bits)
	 (write-wordindexed des
			    (+ 2 sb!vm:complex-long-float-real-slot)
			    imag-mid-bits)
	 (write-wordindexed des
			    (+ 3 sb!vm:complex-long-float-real-slot)
			    imag-low-bits)
	 des)))))

(define-cold-fop (fop-ratio)
  (let ((den (pop-stack)))
    (number-pair-to-core (pop-stack) den sb!vm:ratio-type)))

(define-cold-fop (fop-complex)
  (let ((im (pop-stack)))
    (number-pair-to-core (pop-stack) im sb!vm:complex-type)))

;;;; cold fops for calling (or not calling)

(not-cold-fop fop-eval)
(not-cold-fop fop-eval-for-effect)

(defvar *load-time-value-counter*)

(define-cold-fop (fop-funcall)
  (unless (= (read-arg 1) 0)
    (error "You can't FOP-FUNCALL arbitrary stuff in cold load."))
  (let ((counter *load-time-value-counter*))
    (cold-push (cold-cons
		(cold-intern :load-time-value)
		(cold-cons
		 (pop-stack)
		 (cold-cons
		  (number-to-core counter)
		  *nil-descriptor*)))
	       *current-reversed-cold-toplevels*)
    (setf *load-time-value-counter* (1+ counter))
    (make-descriptor 0 0 nil counter)))

(defun finalize-load-time-value-noise ()
  (cold-set (cold-intern '*!load-time-values*)
	    (allocate-vector-object *dynamic*
				    sb!vm:word-bits
				    *load-time-value-counter*
				    sb!vm:simple-vector-type)))

(define-cold-fop (fop-funcall-for-effect nil)
  (if (= (read-arg 1) 0)
      (cold-push (pop-stack)
		 *current-reversed-cold-toplevels*)
      (error "You can't FOP-FUNCALL arbitrary stuff in cold load.")))

;;;; cold fops for fixing up circularities

(define-cold-fop (fop-rplaca nil)
  (let ((obj (svref *current-fop-table* (read-arg 4)))
	(idx (read-arg 4)))
    (write-memory (cold-nthcdr idx obj) (pop-stack))))

(define-cold-fop (fop-rplacd nil)
  (let ((obj (svref *current-fop-table* (read-arg 4)))
	(idx (read-arg 4)))
    (write-wordindexed (cold-nthcdr idx obj) 1 (pop-stack))))

(define-cold-fop (fop-svset nil)
  (let ((obj (svref *current-fop-table* (read-arg 4)))
	(idx (read-arg 4)))
    (write-wordindexed obj
		   (+ idx
		      (ecase (descriptor-lowtag obj)
			(#.sb!vm:instance-pointer-type 1)
			(#.sb!vm:other-pointer-type 2)))
		   (pop-stack))))

(define-cold-fop (fop-structset nil)
  (let ((obj (svref *current-fop-table* (read-arg 4)))
	(idx (read-arg 4)))
    (write-wordindexed obj (1+ idx) (pop-stack))))

(define-cold-fop (fop-nthcdr t)
  (cold-nthcdr (read-arg 4) (pop-stack)))

(defun cold-nthcdr (index obj)
  (dotimes (i index)
    (setq obj (read-wordindexed obj 1)))
  obj)

;;;; cold fops for loading code objects and functions

;;; the names of things which have had COLD-FSET used on them already
;;; (used to make sure that we don't try to statically link a name to
;;; more than one definition)
(defparameter *cold-fset-warm-names*
  ;; This can't be an EQL hash table because names can be conses, e.g.
  ;; (SETF CAR).
  (make-hash-table :test 'equal))

(define-cold-fop (fop-fset nil)
  (let* ((fn (pop-stack))
	 (cold-name (pop-stack))
	 (warm-name (warm-fun-name cold-name)))
    (if (gethash warm-name *cold-fset-warm-names*)
	(error "duplicate COLD-FSET for ~S" warm-name)
	(setf (gethash warm-name *cold-fset-warm-names*) t))
    (static-fset cold-name fn)))

(define-cold-fop (fop-fdefinition)
  (cold-fdefinition-object (pop-stack)))

(define-cold-fop (fop-sanctify-for-execution)
  (pop-stack))

;;; FIXME: byte compiler to be removed completely
#|
(not-cold-fop fop-make-byte-compiled-function)
|#

;;; Setting this variable shows what code looks like before any
;;; fixups (or function headers) are applied.
#!+sb-show (defvar *show-pre-fixup-code-p* nil)

;;; FIXME: The logic here should be converted into a function
;;; COLD-CODE-FOP-GUTS (NCONST CODE-SIZE) called by DEFINE-COLD-FOP
;;; FOP-CODE and DEFINE-COLD-FOP FOP-SMALL-CODE, so that
;;; variable-capture nastiness like (LET ((NCONST ,NCONST) ..) ..)
;;; doesn't keep me awake at night.
(defmacro define-cold-code-fop (name nconst code-size)
  `(define-cold-fop (,name)
     (let* ((nconst ,nconst)
	    (code-size ,code-size)
	    (raw-header-n-words (+ sb!vm:code-trace-table-offset-slot nconst))
	    (header-n-words
	     ;; Note: we round the number of constants up to ensure
	     ;; that the code vector will be properly aligned.
	     (round-up raw-header-n-words 2))
	    (des (allocate-cold-descriptor *dynamic*
					   (+ (ash header-n-words
						   sb!vm:word-shift)
					      code-size)
					   sb!vm:other-pointer-type)))
       (write-memory des
		     (make-other-immediate-descriptor header-n-words
						      sb!vm:code-header-type))
       (write-wordindexed des
			  sb!vm:code-code-size-slot
			  (make-fixnum-descriptor
			   (ash (+ code-size (1- (ash 1 sb!vm:word-shift)))
				(- sb!vm:word-shift))))
       (write-wordindexed des sb!vm:code-entry-points-slot *nil-descriptor*)
       (write-wordindexed des sb!vm:code-debug-info-slot (pop-stack))
       (when (oddp raw-header-n-words)
	 (write-wordindexed des
			    raw-header-n-words
			    (make-random-descriptor 0)))
       (do ((index (1- raw-header-n-words) (1- index)))
	   ((< index sb!vm:code-trace-table-offset-slot))
	 (write-wordindexed des index (pop-stack)))
       (let* ((start (+ (descriptor-byte-offset des)
			(ash header-n-words sb!vm:word-shift)))
	      (end (+ start code-size)))
	 (read-sequence-or-die (descriptor-bytes des)
			       *fasl-input-stream*
			       :start start
			       :end end)
	 #!+sb-show
	 (when *show-pre-fixup-code-p*
	   (format *trace-output*
		   "~&/raw code from code-fop ~D ~D:~%"
		   nconst
		   code-size)
	   (do ((i start (+ i sb!vm:word-bytes)))
	       ((>= i end))
	     (format *trace-output*
		     "/#X~8,'0x: #X~8,'0x~%"
		     (+ i (gspace-byte-address (descriptor-gspace des)))
		     (byte-vector-ref-32 (descriptor-bytes des) i)))))
       des)))

(define-cold-code-fop fop-code (read-arg 4) (read-arg 4))

(define-cold-code-fop fop-small-code (read-arg 1) (read-arg 2))

(clone-cold-fop (fop-alter-code nil)
		(fop-byte-alter-code)
  (let ((slot (clone-arg))
	(value (pop-stack))
	(code (pop-stack)))
    (write-wordindexed code slot value)))

(define-cold-fop (fop-function-entry)
  (let* ((type (pop-stack))
	 (arglist (pop-stack))
	 (name (pop-stack))
	 (code-object (pop-stack))
	 (offset (calc-offset code-object (read-arg 4)))
	 (fn (descriptor-beyond code-object
				offset
				sb!vm:function-pointer-type))
	 (next (read-wordindexed code-object sb!vm:code-entry-points-slot)))
    (unless (zerop (logand offset sb!vm:lowtag-mask))
      ;; FIXME: This should probably become a fatal error.
      (warn "unaligned function entry: ~S at #X~X" name offset))
    (write-wordindexed code-object sb!vm:code-entry-points-slot fn)
    (write-memory fn
		  (make-other-immediate-descriptor (ash offset
							(- sb!vm:word-shift))
						   sb!vm:function-header-type))
    (write-wordindexed fn
		       sb!vm:function-self-slot
		       ;; KLUDGE: Wiring decisions like this in at
		       ;; this level ("if it's an x86") instead of a
		       ;; higher level of abstraction ("if it has such
		       ;; and such relocation peculiarities (which
		       ;; happen to be confined to the x86)") is bad.
		       ;; It would be nice if the code were instead
		       ;; conditional on some more descriptive
		       ;; feature, :STICKY-CODE or
		       ;; :LOAD-GC-INTERACTION or something.
		       ;;
		       ;; FIXME: The X86 definition of the function
		       ;; self slot breaks everything object.tex says
		       ;; about it. (As far as I can tell, the X86
		       ;; definition makes it a pointer to the actual
		       ;; code instead of a pointer back to the object
		       ;; itself.) Ask on the mailing list whether
		       ;; this is documented somewhere, and if not,
		       ;; try to reverse engineer some documentation
		       ;; before release.
		       #!-x86
		       ;; a pointer back to the function object, as
		       ;; described in CMU CL
		       ;; src/docs/internals/object.tex
		       fn
		       #!+x86
		       ;; KLUDGE: a pointer to the actual code of the
		       ;; object, as described nowhere that I can find
		       ;; -- WHN 19990907
		       (make-random-descriptor
			(+ (descriptor-bits fn)
			   (- (ash sb!vm:function-code-offset sb!vm:word-shift)
			      ;; FIXME: We should mask out the type
			      ;; bits, not assume we know what they
			      ;; are and subtract them out this way.
			      sb!vm:function-pointer-type))))
    (write-wordindexed fn sb!vm:function-next-slot next)
    (write-wordindexed fn sb!vm:function-name-slot name)
    (write-wordindexed fn sb!vm:function-arglist-slot arglist)
    (write-wordindexed fn sb!vm:function-type-slot type)
    fn))

(define-cold-fop (fop-foreign-fixup)
  (let* ((kind (pop-stack))
	 (code-object (pop-stack))
	 (len (read-arg 1))
	 (sym (make-string len)))
    (read-string-as-bytes *fasl-input-stream* sym)
    (let ((offset (read-arg 4))
	  (value (cold-foreign-symbol-address-as-integer sym)))
      (do-cold-fixup code-object offset value kind))
    code-object))

(define-cold-fop (fop-assembler-code)
  (let* ((length (read-arg 4))
	 (header-n-words
	  ;; Note: we round the number of constants up to ensure that
	  ;; the code vector will be properly aligned.
	  (round-up sb!vm:code-constants-offset 2))
	 (des (allocate-cold-descriptor *read-only*
					(+ (ash header-n-words
						sb!vm:word-shift)
					   length)
					sb!vm:other-pointer-type)))
    (write-memory des
		  (make-other-immediate-descriptor header-n-words
						   sb!vm:code-header-type))
    (write-wordindexed des
		       sb!vm:code-code-size-slot
		       (make-fixnum-descriptor
			(ash (+ length (1- (ash 1 sb!vm:word-shift)))
			     (- sb!vm:word-shift))))
    (write-wordindexed des sb!vm:code-entry-points-slot *nil-descriptor*)
    (write-wordindexed des sb!vm:code-debug-info-slot *nil-descriptor*)

    (let* ((start (+ (descriptor-byte-offset des)
		     (ash header-n-words sb!vm:word-shift)))
	   (end (+ start length)))
      (read-sequence-or-die (descriptor-bytes des)
			    *fasl-input-stream*
			    :start start
			    :end end))
    des))

(define-cold-fop (fop-assembler-routine)
  (let* ((routine (pop-stack))
	 (des (pop-stack))
	 (offset (calc-offset des (read-arg 4))))
    (record-cold-assembler-routine
     routine
     (+ (logandc2 (descriptor-bits des) sb!vm:lowtag-mask) offset))
    des))

(define-cold-fop (fop-assembler-fixup)
  (let* ((routine (pop-stack))
	 (kind (pop-stack))
	 (code-object (pop-stack))
	 (offset (read-arg 4)))
    (record-cold-assembler-fixup routine code-object offset kind)
    code-object))

(define-cold-fop (fop-code-object-fixup)
  (let* ((kind (pop-stack))
	 (code-object (pop-stack))
	 (offset (read-arg 4))
	 (value (descriptor-bits code-object)))
    (do-cold-fixup code-object offset value kind)
    code-object))

;;;; emitting C header file

(defun tail-comp (string tail)
  (and (>= (length string) (length tail))
       (string= string tail :start1 (- (length string) (length tail)))))

(defun head-comp (string head)
  (and (>= (length string) (length head))
       (string= string head :end1 (length head))))

(defun write-c-header ()

  ;; writing beginning boilerplate
  (format t "/*~%")
  (dolist (line
	   '("This is a machine-generated file. Please do not edit it by hand."
	     ""
	     "This file contains low-level information about the"
	     "internals of a particular version and configuration"
	     "of SBCL. It is used by the C compiler to create a runtime"
	     "support environment, an executable program in the host"
	     "operating system's native format, which can then be used to"
	     "load and run 'core' files, which are basically programs"
	     "in SBCL's own format."))
    (format t " * ~A~%" line))
  (format t " */~%")
  (terpri)
  (format t "#ifndef _SBCL_H_~%#define _SBCL_H_~%")
  (terpri)

  ;; propagating *SHEBANG-FEATURES* into C-level #define's
  (dolist (shebang-feature-name (sort (mapcar #'symbol-name
					      sb-cold:*shebang-features*)
				      #'string<))
    (format t
	    "#define LISP_FEATURE_~A~%"
	    (substitute #\_ #\- shebang-feature-name)))
  (terpri)

  ;; writing miscellaneous constants
  (format t "#define SBCL_CORE_VERSION_INTEGER ~D~%" sbcl-core-version-integer)
  (format t
	  "#define SBCL_VERSION_STRING ~S~%"
	  (sb!xc:lisp-implementation-version))
  (format t "#define CORE_MAGIC 0x~X~%" core-magic)
  (terpri)
  ;; FIXME: Other things from core.h should be defined here too:
  ;; #define CORE_END 3840
  ;; #define CORE_NDIRECTORY 3861
  ;; #define CORE_VALIDATE 3845
  ;; #define CORE_VERSION 3860
  ;; #define CORE_MACHINE_STATE 3862
  ;; (Except that some of them are obsolete and should be deleted instead.)
  ;; also
  ;; #define DYNAMIC_SPACE_ID (1)
  ;; #define STATIC_SPACE_ID (2)
  ;; #define READ_ONLY_SPACE_ID (3)

  ;; writing entire families of named constants from SB!VM
  (let ((constants nil))
    (do-external-symbols (symbol (find-package "SB!VM"))
      (when (constantp symbol)
	(let ((name (symbol-name symbol)))
	  (labels (;; shared machinery
		   (record (string priority)
		     (push (list string
				 priority
				 (symbol-value symbol)
				 (documentation symbol 'variable))
			   constants))
		   ;; machinery for old-style CMU CL Lisp-to-C naming
		   (record-with-munged-name (prefix string priority)
		     (record (concatenate
			      'simple-string
			      prefix
			      (delete #\- (string-capitalize string)))
			     priority))
		   (test-tail (tail prefix priority)
		     (when (tail-comp name tail)
		       (record-with-munged-name prefix
						(subseq name 0
							(- (length name)
							   (length tail)))
						priority)))
		   (test-head (head prefix priority)
		     (when (head-comp name head)
		       (record-with-munged-name prefix
						(subseq name (length head))
						priority)))
		   ;; machinery for new-style SBCL Lisp-to-C naming
		   (record-with-translated-name (priority)
		     (record (substitute #\_ #\- name)
			     priority)))
	    ;; This style of munging of names is used in the code
	    ;; inherited from CMU CL.
	    (test-tail "-TYPE" "type_" 0)
	    (test-tail "-FLAG" "flag_" 1)
	    (test-tail "-TRAP" "trap_" 2)
	    (test-tail "-SUBTYPE" "subtype_" 3)
	    (test-head "TRACE-TABLE-" "tracetab_" 4)
	    (test-tail "-SC-NUMBER" "sc_" 5)
	    ;; This simpler style of translation of names seems less
	    ;; confusing, and is used for newer code.
	    (when (some (lambda (suffix) (tail-comp name suffix))
			#("-START" "-END"))
	      (record-with-translated-name 6))))))
    (setf constants
	  (sort constants
		#'(lambda (const1 const2)
		    (if (= (second const1) (second const2))
		      (< (third const1) (third const2))
		      (< (second const1) (second const2))))))
    (let ((prev-priority (second (car constants))))
      (dolist (const constants)
	(destructuring-bind (name priority value doc) const
	  (unless (= prev-priority priority)
	    (terpri)
	    (setf prev-priority priority))
	  (format t "#define ~A " name)
	  (format t 
		  ;; KLUDGE: As of sbcl-0.6.7.14, we're dumping two
		  ;; different kinds of values here, (1) small codes
		  ;; and (2) machine addresses. The small codes can be
		  ;; dumped as bare integer values. The large machine
		  ;; addresses might cause problems if they're large
		  ;; and represented as (signed) C integers, so we
		  ;; want to force them to be unsigned. We do that by
		  ;; wrapping them in the LISPOBJ macro. (We could do
		  ;; it with a bare "(unsigned)" cast, except that
		  ;; this header file is used not only in C files, but
		  ;; also in assembly files, which don't understand
		  ;; the cast syntax. The LISPOBJ macro goes away in
		  ;; assembly files, but that shouldn't matter because
		  ;; we don't do arithmetic on address constants in
		  ;; assembly files. See? It really is a kludge..) --
		  ;; WHN 2000-10-18
		  (let (;; cutoff for treatment as a small code
			(cutoff (expt 2 16)))
		    (cond ((minusp value)
			   (error "stub: negative values unsupported"))
			  ((< value cutoff)
			   "~D")
			  (t
			   "LISPOBJ(~D)")))
		  value)
	  (format t " /* 0x~X */~@[  /* ~A */~]~%" value doc))))
    (terpri))

  ;; writing codes/strings for internal errors
  (format t "#define ERRORS { \\~%")
  ;; FIXME: Is this just DOVECTOR?
  (let ((internal-errors sb!c:*backend-internal-errors*))
    (dotimes (i (length internal-errors))
      (format t "    ~S, /*~D*/ \\~%" (cdr (aref internal-errors i)) i)))
  (format t "    NULL \\~%}~%")
  (terpri)

  ;; writing primitive object layouts
  (let ((structs (sort (copy-list sb!vm:*primitive-objects*) #'string<
		       :key #'(lambda (obj)
				(symbol-name
				 (sb!vm:primitive-object-name obj))))))
    (format t "#ifndef LANGUAGE_ASSEMBLY~2%")
    (format t "#define LISPOBJ(x) ((lispobj)x)~2%")
    (dolist (obj structs)
      (format t
	      "struct ~A {~%"
	      (nsubstitute #\_ #\-
	      (string-downcase (string (sb!vm:primitive-object-name obj)))))
      (when (sb!vm:primitive-object-header obj)
	(format t "    lispobj header;~%"))
      (dolist (slot (sb!vm:primitive-object-slots obj))
	(format t "    ~A ~A~@[[1]~];~%"
	(getf (sb!vm:slot-options slot) :c-type "lispobj")
	(nsubstitute #\_ #\-
		     (string-downcase (string (sb!vm:slot-name slot))))
	(sb!vm:slot-rest-p slot)))
      (format t "};~2%"))
    (format t "#else /* LANGUAGE_ASSEMBLY */~2%")
    (format t "#define LISPOBJ(thing) thing~2%")
    (dolist (obj structs)
      (let ((name (sb!vm:primitive-object-name obj))
      (lowtag (eval (sb!vm:primitive-object-lowtag obj))))
	(when lowtag
	(dolist (slot (sb!vm:primitive-object-slots obj))
	  (format t "#define ~A_~A_OFFSET ~D~%"
		  (substitute #\_ #\- (string name))
		  (substitute #\_ #\- (string (sb!vm:slot-name slot)))
		  (- (* (sb!vm:slot-offset slot) sb!vm:word-bytes) lowtag)))
	(terpri))))
    (format t "#endif /* LANGUAGE_ASSEMBLY */~2%"))

  ;; writing static symbol offsets
  (dolist (symbol (cons nil sb!vm:*static-symbols*))
    ;; FIXME: It would be nice to use longer names NIL and (particularly) T
    ;; in #define statements.
    (format t "#define ~A LISPOBJ(0x~X)~%"
	    (nsubstitute #\_ #\-
			 (remove-if #'(lambda (char)
					(member char '(#\% #\* #\. #\!)))
				    (symbol-name symbol)))
	    (if *static*		; if we ran GENESIS
	      ;; We actually ran GENESIS, use the real value.
	      (descriptor-bits (cold-intern symbol))
	      ;; We didn't run GENESIS, so guess at the address.
	      (+ sb!vm:static-space-start
		 sb!vm:word-bytes
		 sb!vm:other-pointer-type
		 (if symbol (sb!vm:static-symbol-offset symbol) 0)))))

  ;; Voila.
  (format t "~%#endif~%"))

;;;; writing map file

;;; Write a map file describing the cold load. Some of this
;;; information is subject to change due to relocating GC, but even so
;;; it can be very handy when attempting to troubleshoot the early
;;; stages of cold load.
(defun write-map ()
  (let ((*print-pretty* nil)
	(*print-case* :upcase))
    (format t "assembler routines defined in core image:~2%")
    (dolist (routine (sort (copy-list *cold-assembler-routines*) #'<
			   :key #'cdr))
      (format t "#X~8,'0X: ~S~%" (cdr routine) (car routine)))
    (let ((funs nil)
	  (undefs nil))
      (maphash #'(lambda (name fdefn)
		   (let ((fun (read-wordindexed fdefn
						sb!vm:fdefn-function-slot)))
		     (if (= (descriptor-bits fun)
			    (descriptor-bits *nil-descriptor*))
			 (push name undefs)
			 (let ((addr (read-wordindexed
				      fdefn sb!vm:fdefn-raw-addr-slot)))
			   (push (cons name (descriptor-bits addr))
				 funs)))))
	       *cold-fdefn-objects*)
      (format t "~%~|~%initially defined functions:~2%")
      (setf funs (sort funs #'< :key #'cdr))
      (dolist (info funs)
	(format t "0x~8,'0X: ~S   #X~8,'0X~%" (cdr info) (car info)
		(- (cdr info) #x17)))
      (format t
"~%~|
(a note about initially undefined function references: These functions
are referred to by code which is installed by GENESIS, but they are not
installed by GENESIS. This is not necessarily a problem; functions can
be defined later, by cold init toplevel forms, or in files compiled and
loaded at warm init, or elsewhere. As long as they are defined before
they are called, everything should be OK. Things are also OK if the
cross-compiler knew their inline definition and used that everywhere
that they were called before the out-of-line definition is installed,
as is fairly common for structure accessors.)
initially undefined function references:~2%")

      (setf undefs (sort undefs #'string< :key #'function-name-block-name))
      (dolist (name undefs)
        (format t "~S" name)
	;; FIXME: This ACCESSOR-FOR stuff should go away when the
	;; code has stabilized. (It's only here to help me
	;; categorize the flood of undefined functions caused by
	;; completely rewriting the bootstrap process. Hopefully any
	;; future maintainers will mostly have small numbers of
	;; undefined functions..)
	(let ((accessor-for (info :function :accessor-for name)))
	  (when accessor-for
	    (format t " (accessor for ~S)" accessor-for)))
	(format t "~%")))

    (format t "~%~|~%layout names:~2%")
    (collect ((stuff))
      (maphash #'(lambda (name gorp)
                   (declare (ignore name))
                   (stuff (cons (descriptor-bits (car gorp))
                                (cdr gorp))))
               *cold-layouts*)
      (dolist (x (sort (stuff) #'< :key #'car))
        (apply #'format t "~8,'0X: ~S[~D]~%~10T~S~%" x))))

  (values))

;;;; writing core file

(defvar *core-file*)
(defvar *data-page*)

;;; KLUDGE: These numbers correspond to values in core.h. If they're
;;; documented anywhere, I haven't found it. (I haven't tried very
;;; hard yet.) -- WHN 19990826
(defparameter version-entry-type-code 3860)
(defparameter validate-entry-type-code 3845)
(defparameter directory-entry-type-code 3841)
(defparameter new-directory-entry-type-code 3861)
(defparameter initial-function-entry-type-code 3863)
(defparameter end-entry-type-code 3840)

(declaim (ftype (function (sb!vm:word) sb!vm:word) write-long))
(defun write-long (num) ; FIXME: WRITE-WORD would be a better name.
  (ecase sb!c:*backend-byte-order*
    (:little-endian
     (dotimes (i 4)
       (write-byte (ldb (byte 8 (* i 8)) num) *core-file*)))
    (:big-endian
     (dotimes (i 4)
       (write-byte (ldb (byte 8 (* (- 3 i) 8)) num) *core-file*))))
  num)

(defun advance-to-page ()
  (force-output *core-file*)
  (file-position *core-file*
		 (round-up (file-position *core-file*)
			   sb!c:*backend-page-size*)))

(defun output-gspace (gspace)
  (force-output *core-file*)
  (let* ((posn (file-position *core-file*))
	 (bytes (* (gspace-free-word-index gspace) sb!vm:word-bytes))
	 (pages (ceiling bytes sb!c:*backend-page-size*))
	 (total-bytes (* pages sb!c:*backend-page-size*)))

    (file-position *core-file*
		   (* sb!c:*backend-page-size* (1+ *data-page*)))
    (format t
	    "writing ~S byte~:P [~S page~:P] from ~S~%"
	    total-bytes
	    pages
	    gspace)
    (force-output)

    ;; Note: It is assumed that the GSPACE allocation routines always
    ;; allocate whole pages (of size *target-page-size*) and that any
    ;; empty gspace between the free pointer and the end of page will
    ;; be zero-filled. This will always be true under Mach on machines
    ;; where the page size is equal. (RT is 4K, PMAX is 4K, Sun 3 is
    ;; 8K).
    (write-sequence (gspace-bytes gspace) *core-file* :end total-bytes)
    (force-output *core-file*)
    (file-position *core-file* posn)

    ;; Write part of a (new) directory entry which looks like this:
    ;;   GSPACE IDENTIFIER
    ;;   WORD COUNT
    ;;   DATA PAGE
    ;;   ADDRESS
    ;;   PAGE COUNT
    (write-long (gspace-identifier gspace))
    (write-long (gspace-free-word-index gspace))
    (write-long *data-page*)
    (multiple-value-bind (floor rem)
	(floor (gspace-byte-address gspace) sb!c:*backend-page-size*)
      (aver (zerop rem))
      (write-long floor))
    (write-long pages)

    (incf *data-page* pages)))

;;; Create a core file created from the cold loaded image. (This is
;;; the "initial core file" because core files could be created later
;;; by executing SAVE-LISP in a running system, perhaps after we've
;;; added some functionality to the system.)
(declaim (ftype (function (string)) write-initial-core-file))
(defun write-initial-core-file (filename)

  (let ((filenamestring (namestring filename))
	(*data-page* 0))

    (format t
	    "[building initial core file in ~S: ~%"
	    filenamestring)
    (force-output)

    (with-open-file (*core-file* filenamestring
				 :direction :output
				 :element-type '(unsigned-byte 8)
				 :if-exists :rename-and-delete)

      ;; Write the magic number.
      (write-long core-magic)

      ;; Write the Version entry.
      (write-long version-entry-type-code)
      (write-long 3)
      (write-long sbcl-core-version-integer)

      ;; Write the New Directory entry header.
      (write-long new-directory-entry-type-code)
      (write-long 17) ; length = (5 words/space) * 3 spaces + 2 for header.

      (output-gspace *read-only*)
      (output-gspace *static*)
      (output-gspace *dynamic*)

      ;; Write the initial function.
      (write-long initial-function-entry-type-code)
      (write-long 3)
      (let* ((cold-name (cold-intern '!cold-init))
	     (cold-fdefn (cold-fdefinition-object cold-name))
	     (initial-function (read-wordindexed cold-fdefn
						 sb!vm:fdefn-function-slot)))
	(format t
		"~&/(DESCRIPTOR-BITS INITIAL-FUNCTION)=#X~X~%"
		(descriptor-bits initial-function))
	(write-long (descriptor-bits initial-function)))

      ;; Write the End entry.
      (write-long end-entry-type-code)
      (write-long 2)))

  (format t "done]~%")
  (force-output)
  (/show "leaving WRITE-INITIAL-CORE-FILE")
  (values))

;;;; the actual GENESIS function

;;; Read the FASL files in OBJECT-FILE-NAMES and produce a Lisp core,
;;; and/or information about a Lisp core, therefrom.
;;;
;;; input file arguments:
;;;   SYMBOL-TABLE-FILE-NAME names a UNIX-style .nm file *with* *any*
;;;     *tab* *characters* *converted* *to* *spaces*. (We push
;;;     responsibility for removing tabs out to the caller it's
;;;     trivial to remove them using UNIX command line tools like
;;;     sed, whereas it's a headache to do it portably in Lisp because
;;;     #\TAB is not a STANDARD-CHAR.) If this file is not supplied,
;;;     a core file cannot be built (but a C header file can be).
;;;
;;; output files arguments (any of which may be NIL to suppress output):
;;;   CORE-FILE-NAME gets a Lisp core.
;;;   C-HEADER-FILE-NAME gets a C header file, traditionally called
;;;     internals.h, which is used by the C compiler when constructing
;;;     the executable which will load the core.
;;;   MAP-FILE-NAME gets (?) a map file. (dunno about this -- WHN 19990815)
;;;
;;; other arguments:
;;;   BYTE-ORDER-SWAP-P controls whether GENESIS tries to swap bytes
;;;     in some places in the output. It's only appropriate when
;;;     cross-compiling from a machine with one byte order to a
;;;     machine with the opposite byte order, which is irrelevant in
;;;     current (19990816) SBCL, since only the X86 architecture is
;;;     supported. If you're trying to add support for more
;;;     architectures, see the comments on DEFVAR
;;;     *GENESIS-BYTE-ORDER-SWAP-P* for more information.
;;;
;;; FIXME: GENESIS doesn't belong in SB!VM. Perhaps in %KERNEL for now,
;;; perhaps eventually in SB-LD or SB-BOOT.
(defun sb!vm:genesis (&key
		      object-file-names
		      symbol-table-file-name
		      core-file-name
		      map-file-name
		      c-header-file-name
		      byte-order-swap-p)

  (when (and core-file-name
	     (not symbol-table-file-name))
    (error "can't output a core file without symbol table file input"))

  (format t
	  "~&beginning GENESIS, ~A~%"
	  (if core-file-name
	    ;; Note: This output summarizing what we're doing is
	    ;; somewhat telegraphic in style, not meant to imply that
	    ;; we're not e.g. also creating a header file when we
	    ;; create a core.
	    (format nil "creating core ~S" core-file-name)
	    (format nil "creating header ~S" c-header-file-name)))

  (let* ((*cold-foreign-symbol-table* (make-hash-table :test 'equal)))

    ;; Read symbol table, if any.
    (when symbol-table-file-name
      (load-cold-foreign-symbol-table symbol-table-file-name))

    ;; Now that we've successfully read our only input file (by
    ;; loading the symbol table, if any), it's a good time to ensure
    ;; that there'll be someplace for our output files to go when
    ;; we're done.
    (flet ((frob (filename)
	     (when filename
	       (ensure-directories-exist filename :verbose t))))
      (frob core-file-name)
      (frob map-file-name)
      (frob c-header-file-name))

    ;; (This shouldn't matter in normal use, since GENESIS normally
    ;; only runs once in any given Lisp image, but it could reduce
    ;; confusion if we ever experiment with running, tweaking, and
    ;; rerunning genesis interactively.)
    (do-all-symbols (sym)
      (remprop sym 'cold-intern-info))

    (let* ((*foreign-symbol-placeholder-value* (if core-file-name nil 0))
	   (*load-time-value-counter* 0)
	   (*genesis-byte-order-swap-p* byte-order-swap-p)
	   (*cold-fdefn-objects* (make-hash-table :test 'equal))
	   (*cold-symbols* (make-hash-table :test 'equal))
	   (*cold-package-symbols* nil)
	   (*read-only* (make-gspace :read-only
				     read-only-space-id
				     sb!vm:read-only-space-start))
	   (*static*    (make-gspace :static
				     static-space-id
				     sb!vm:static-space-start))
	   (*dynamic*   (make-gspace :dynamic
				     dynamic-space-id
				     sb!vm:dynamic-space-start))
	   (*nil-descriptor* (make-nil-descriptor))
	   (*current-reversed-cold-toplevels* *nil-descriptor*)
	   (*unbound-marker* (make-other-immediate-descriptor
			      0
			      sb!vm:unbound-marker-type))
	   *cold-assembler-fixups*
	   *cold-assembler-routines*
	   #!+x86 *load-time-code-fixups*)

      ;; Prepare for cold load.
      (initialize-non-nil-symbols)
      (initialize-layouts)
      (initialize-static-fns)

      ;; Initialize the *COLD-SYMBOLS* system with the information
      ;; from package-data-list.lisp-expr and
      ;; common-lisp-exports.lisp-expr.
      ;;
      ;; Why do things this way? Historically, the *COLD-SYMBOLS*
      ;; machinery was designed and implemented in CMU CL long before
      ;; I (WHN) ever heard of CMU CL. It dumped symbols and packages
      ;; iff they were used in the cold image. When I added the
      ;; package-data-list.lisp-expr mechanism, the idea was to
      ;; centralize all information about packages and exports. Thus,
      ;; it was the natural place for information even about packages
      ;; (such as SB!PCL and SB!WALKER) which aren't used much until
      ;; after cold load. This didn't quite match the CMU CL approach
      ;; of filling *COLD-SYMBOLS* with symbols which appear in the
      ;; cold image and then dumping only those symbols. By explicitly
      ;; putting all the symbols from package-data-list.lisp-expr and
      ;; from common-lisp-exports.lisp-expr into *COLD-SYMBOLS* here,
      ;; we feed our centralized symbol information into the old CMU
      ;; CL code without having to change the old CMU CL code too
      ;; much. (And the old CMU CL code is still useful for making
      ;; sure that the appropriate keywords and internal symbols end
      ;; up interned in the target Lisp, which is good, e.g. in order
      ;; to make &KEY arguments work right and in order to make
      ;; BACKTRACEs into target Lisp system code be legible.)
      (dolist (exported-name
	       (sb-cold:read-from-file "common-lisp-exports.lisp-expr"))
	(cold-intern (intern exported-name *cl-package*)))
      (dolist (pd (sb-cold:read-from-file "package-data-list.lisp-expr"))
	(declare (type sb-cold:package-data pd))
	(let ((package (find-package (sb-cold:package-data-name pd))))
	  (labels (;; Call FN on every node of the TREE.
		   (mapc-on-tree (fn tree)
				 (typecase tree
				   (cons (mapc-on-tree fn (car tree))
					 (mapc-on-tree fn (cdr tree)))
				   (t (funcall fn tree)
				      (values))))
		   ;; Make sure that information about the association
		   ;; between PACKAGE and the symbol named NAME gets
		   ;; recorded in the cold-intern system or (as a
		   ;; convenience when dealing with the tree structure
		   ;; allowed in the PACKAGE-DATA-EXPORTS slot) do
		   ;; nothing if NAME is NIL.
		   (chill (name)
		     (when name
		       (cold-intern (intern name package) package))))
	    (mapc-on-tree #'chill (sb-cold:package-data-export pd))
	    (mapc #'chill (sb-cold:package-data-reexport pd))
	    (dolist (sublist (sb-cold:package-data-import-from pd))
	      (destructuring-bind (package-name &rest symbol-names) sublist
		(declare (ignore package-name))
		(mapc #'chill symbol-names))))))

      ;; Cold load.
      (dolist (file-name object-file-names)
	(write-line (namestring file-name))
	(cold-load file-name))

      ;; Tidy up loose ends left by cold loading. ("Postpare from cold load?")
      (resolve-assembler-fixups)
      #!+x86 (output-load-time-code-fixups)
      (linkage-info-to-core)
      (finish-symbols)
      (/show "back from FINISH-SYMBOLS")
      (finalize-load-time-value-noise)

      ;; Tell the target Lisp how much stuff we've allocated.
      (cold-set 'sb!vm:*read-only-space-free-pointer*
		(allocate-cold-descriptor *read-only*
					  0
					  sb!vm:even-fixnum-type))
      (cold-set 'sb!vm:*static-space-free-pointer*
		(allocate-cold-descriptor *static*
					  0
					  sb!vm:even-fixnum-type))
      (cold-set 'sb!vm:*initial-dynamic-space-free-pointer*
		(allocate-cold-descriptor *dynamic*
					  0
					  sb!vm:even-fixnum-type))
      (/show "done setting free pointers")

      ;; Write results to files.
      ;;
      ;; FIXME: I dislike this approach of redefining
      ;; *STANDARD-OUTPUT* instead of putting the new stream in a
      ;; lexical variable, and it's annoying to have WRITE-MAP (to
      ;; *STANDARD-OUTPUT*) not be parallel to WRITE-INITIAL-CORE-FILE
      ;; (to a stream explicitly passed as an argument).
      (when map-file-name
	(with-open-file (*standard-output* map-file-name
					   :direction :output
					   :if-exists :supersede)
	  (write-map)))
      (when c-header-file-name
	(with-open-file (*standard-output* c-header-file-name
					   :direction :output
					   :if-exists :supersede)
	  (write-c-header)))
      (when core-file-name
	(write-initial-core-file core-file-name)))))
