;;;; structures used for recording debugger information

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

;;;; SC-OFFSETs
;;;;
;;;; We represent the place where some value is stored with a SC-OFFSET,
;;;; which is the SC number and offset encoded as an integer.

(defconstant-eqx sc-offset-scn-byte (byte 5 0) #'equalp)
(defconstant-eqx sc-offset-offset-byte (byte 22 5) #'equalp)
(def!type sc-offset () '(unsigned-byte 27))

(defmacro make-sc-offset (scn offset)
  `(dpb ,scn sc-offset-scn-byte
	(dpb ,offset sc-offset-offset-byte 0)))

(defmacro sc-offset-scn (sco) `(ldb sc-offset-scn-byte ,sco))
(defmacro sc-offset-offset (sco) `(ldb sc-offset-offset-byte ,sco))

;;;; flags for compiled debug variables

;;; FIXME: old CMU CL representation follows:
;;;    Compiled debug variables are in a packed binary representation in the
;;; DEBUG-FUN-VARIABLES:
;;;    single byte of boolean flags:
;;;	uninterned name
;;;	   packaged name
;;;	environment-live
;;;	has distinct save location
;;;	has ID (name not unique in this fun)
;;;	minimal debug-info argument (name generated as ARG-0, ...)
;;;	deleted: placeholder for unused minimal argument
;;;    [name length in bytes (as var-length integer), if not minimal]
;;;    [...name bytes..., if not minimal]
;;;    [if packaged, var-length integer that is package name length]
;;;     ...package name bytes...]
;;;    [If has ID, ID as var-length integer]
;;;    SC-Offset of primary location (as var-length integer)
;;;    [If has save SC, SC-Offset of save location (as var-length integer)]

;;; FIXME: The first two are no longer used in SBCL.
;;;(defconstant compiled-debug-var-uninterned		#b00000001)
;;;(defconstant compiled-debug-var-packaged		#b00000010)
(defconstant compiled-debug-var-environment-live	#b00000100)
(defconstant compiled-debug-var-save-loc-p		#b00001000)
(defconstant compiled-debug-var-id-p			#b00010000)
(defconstant compiled-debug-var-minimal-p		#b00100000)
(defconstant compiled-debug-var-deleted-p		#b01000000)

;;;; compiled debug blocks
;;;;
;;;;    Compiled debug blocks are in a packed binary representation in the
;;;; DEBUG-FUN-BLOCKS:
;;;;    number of successors + bit flags (single byte)
;;;;	elsewhere-p
;;;;    ...ordinal number of each successor in the function's blocks vector...
;;;;    number of locations in this block
;;;;    kind of first location (single byte)
;;;;    delta from previous PC (or from 0 if first location in function.)
;;;;    [offset of first top-level form, if no function TLF-NUMBER]
;;;;    form number of first source form
;;;;    first live mask (length in bytes determined by number of VARIABLES)
;;;;    ...more <kind, delta, top-level form offset, form-number, live-set>
;;;;       tuples...

(defconstant-eqx compiled-debug-block-nsucc-byte (byte 2 0) #'equalp)
(defconstant compiled-debug-block-elsewhere-p #b00000100)

(defconstant-eqx compiled-code-location-kind-byte (byte 3 0) #'equalp)
(defparameter *compiled-code-location-kinds*
  #(:unknown-return :known-return :internal-error :non-local-exit
    :block-start :call-site :single-value-return :non-local-entry))

;;;; DEBUG-FUN objects

(def!struct (debug-fun (:constructor nil)))

(def!struct (compiled-debug-fun (:include debug-fun)
				#-sb-xc-host (:pure t))
  ;; The name of this function. If from a DEFUN, etc., then this is the
  ;; function name, otherwise it is a descriptive string.
  (name (missing-arg) :type (or simple-string cons symbol))
  ;; The kind of function (same as FUNCTIONAL-KIND):
  (kind nil :type (member nil :optional :external :top-level :cleanup))
  ;; a description of variable locations for this function, in alphabetical
  ;; order by name; or NIL if no information is available
  ;;
  ;; The variable entries are alphabetically ordered. This ordering is used in
  ;; lifetime info to refer to variables: the first entry is 0, the second
  ;; entry is 1, etc. Variable numbers are *not* the byte index at which the
  ;; representation of the location starts.
  ;;
  ;; Each entry is:
  ;;   * a FLAGS value, which is a FIXNUM with various
  ;;     COMPILED-DEBUG-FUN-FOO bits set
  ;;   * the symbol which names this variable, unless debug info is minimal
  ;;   * the variable ID, when it has one
  ;;   * SC-offset of primary location, if it has one
  ;;   * SC-offset of save location, if it has one
  (variables nil :type (or simple-vector null))
  ;; a vector of the packed binary representation of the
  ;; COMPILED-DEBUG-BLOCKs in this function, in the order that the
  ;; blocks were emitted. The first block is the start of the
  ;; function. This slot may be NIL to save space.
  ;;
  ;; FIXME: The "packed binary representation" description in the comment
  ;; above is the same as the description of the old representation of
  ;; VARIABLES which doesn't work properly in SBCL (because it doesn't
  ;; transform correctly under package renaming). Check whether this slot's
  ;; data might have the same problem that that slot's data did.
  (blocks nil :type (or (simple-array (unsigned-byte 8) (*)) null))
  ;; If all code locations in this function are in the same top-level form,
  ;; then this is the number of that form, otherwise NIL. If NIL, then each
  ;; code location represented in the BLOCKS specifies the TLF number.
  (tlf-number nil :type (or index null))
  ;; A vector describing the variables that the argument values are stored in
  ;; within this function. The locations are represented by the ordinal number
  ;; of the entry in the VARIABLES slot value. The locations are in the order
  ;; that the arguments are actually passed in, but special marker symbols can
  ;; be interspersed to indicate the original call syntax:
  ;;
  ;; DELETED
  ;;    There was an argument to the function in this position, but it was
  ;;    deleted due to lack of references. The value cannot be recovered.
  ;;
  ;; SUPPLIED-P
  ;;    The following location is the supplied-p value for the preceding
  ;;    keyword or optional.
  ;;
  ;; OPTIONAL-ARGS
  ;;    Indicates that following unqualified args are optionals, not required.
  ;;
  ;; REST-ARG
  ;;    The following location holds the list of rest args.
  ;;
  ;; MORE-ARG
  ;;    The following two locations are the more arg context and count.
  ;;
  ;; <any other symbol>
  ;;    The following location is the value of the &KEY argument with the
  ;;    specified name.
  ;;
  ;; This may be NIL to save space. If no symbols are present, then this will
  ;; be represented with an I-vector with sufficiently large element type. If
  ;; this is :MINIMAL, then this means that the VARIABLES are all required
  ;; arguments, and are in the order they appear in the VARIABLES vector. In
  ;; other words, :MINIMAL stands in for a vector where every element holds its
  ;; index.
  (arguments nil :type (or (simple-array * (*)) (member :minimal nil)))
  ;; There are three alternatives for this slot:
  ;;
  ;; A vector
  ;;    A vector of SC-OFFSETS describing the return locations. The
  ;;    vector element type is chosen to hold the largest element.
  ;;
  ;; :Standard
  ;;    The function returns using the standard unknown-values convention.
  ;;
  ;; :Fixed
  ;;    The function returns using the fixed-values convention, but
  ;;    in order to save space, we elected not to store a vector.
  (returns :fixed :type (or (simple-array * (*)) (member :standard :fixed)))
  ;; SC-Offsets describing where the return PC and return FP are kept.
  (return-pc (missing-arg) :type sc-offset)
  (old-fp (missing-arg) :type sc-offset)
  ;; SC-Offset for the number stack FP in this function, or NIL if no NFP
  ;; allocated.
  (nfp nil :type (or sc-offset null))
  ;; The earliest PC in this function at which the environment is properly
  ;; initialized (arguments moved from passing locations, etc.)
  (start-pc (missing-arg) :type index)
  ;; The start of elsewhere code for this function (if any.)
  (elsewhere-pc (missing-arg) :type index))

;;;; minimal debug function

;;; The minimal debug info format compactly represents debug-info for some
;;; cases where the other debug info (variables, blocks) is small enough so
;;; that the per-function overhead becomes relatively large. The minimal
;;; debug-info format can represent any function at level 0, and any fixed-arg
;;; function at level 1.
;;;
;;; In the minimal format, the debug functions and function map are
;;; packed into a single byte-vector which is placed in the
;;; COMPILED-DEBUG-INFO-FUN-MAP. Because of this, all functions in a
;;; component must be representable in minimal format for any function
;;; to actually be dumped in minimal format. The vector is a sequence
;;; of records in this format:
;;;    name representation + kind + return convention (single byte)
;;;    bit flags (single byte)
;;;	setf, nfp, variables
;;;    [package name length (as var-length int), if name is packaged]
;;;    [...package name bytes, if name is packaged]
;;;    [name length (as var-length int), if there is a name]
;;;    [...name bytes, if there is a name]
;;;    [variables length (as var-length int), if variables flag]
;;;    [...bytes holding variable descriptions]
;;;	If variables are dumped (level 1), then the variables are all
;;;	arguments (in order) with the minimal-arg bit set.
;;;    [If returns is specified, then the number of return values]
;;;    [...sequence of var-length ints holding sc-offsets of the return
;;;	value locations, if fixed return values are specified.]
;;;    return-pc location sc-offset (as var-length int)
;;;    old-fp location sc-offset (as var-length int)
;;;    [nfp location sc-offset (as var-length int), if nfp flag]
;;;    code-start-pc (as a var-length int)
;;;	This field implicitly encodes start of this function's code in the
;;;	function map, as a delta from the previous function's code start.
;;;	If the first function in the component, then this is the delta from
;;;	0 (i.e. the absolute offset.)
;;;    start-pc (as a var-length int)
;;;	This encodes the environment start PC as an offset from the
;;;	code-start PC.
;;;    elsewhere-pc
;;;	This encodes the elsewhere code start for this function, as a delta
;;;	from the previous function's elsewhere code start. (i.e. the
;;;	encoding is the same as for code-start-pc.)

;;; ### For functions with XEPs, name could be represented more simply
;;; and compactly as some sort of info about with how to find the
;;; FUNCTION-ENTRY that this is a function for. Actually, you really
;;; hardly need any info. You can just chain through the functions in
;;; the component until you find the right one. Well, I guess you need
;;; to at least know which function is an XEP for the real function
;;; (which would be useful info anyway).

;;;; debug source

(def!struct (debug-source #-sb-xc-host (:pure t))
  ;; This slot indicates where the definition came from:
  ;;    :FILE - from a file (i.e. COMPILE-FILE)
  ;;    :LISP - from Lisp (i.e. COMPILE)
  (from (missing-arg) :type (member :file :lisp))
  ;; If :FILE, the file name, if :LISP or :STREAM, then a vector of
  ;; the top-level forms. When from COMPILE, form 0 is #'(LAMBDA ...).
  (name nil)
  ;; the universal time that the source was written, or NIL if
  ;; unavailable
  (created nil :type (or unsigned-byte null))
  ;; the universal time that the source was compiled
  (compiled (missing-arg) :type unsigned-byte)
  ;; the source path root number of the first form read from this
  ;; source (i.e. the total number of forms converted previously in
  ;; this compilation)
  (source-root 0 :type index)
  ;; The FILE-POSITIONs of the truly top-level forms read from this
  ;; file (if applicable). The vector element type will be chosen to
  ;; hold the largest element. May be null to save space, or if
  ;; :DEBUG-SOURCE-FORM is :LISP.
  (start-positions nil :type (or (simple-array * (*)) null))
  ;; If from :LISP, this is the function whose source is form 0.
  (info nil))

;;;; DEBUG-INFO structures

(def!struct debug-info
  ;; Some string describing something about the code in this component.
  (name (missing-arg) :type simple-string)
  ;; A list of DEBUG-SOURCE structures describing where the code for this
  ;; component came from, in the order that they were read.
  ;;
  ;; KLUDGE: comment from CMU CL:
  ;;   *** NOTE: the offset of this slot is wired into the fasl dumper 
  ;;   *** so that it can backpatch the source info when compilation
  ;;   *** is complete.
  (source nil :type list))

(def!struct (compiled-debug-info
	     (:include debug-info)
	     #-sb-xc-host (:pure t))
  ;; a simple-vector of alternating DEBUG-FUN objects and fixnum
  ;; PCs, used to map PCs to functions, so that we can figure out what
  ;; function we were running in. Each function is valid between the
  ;; PC before it (inclusive) and the PC after it (exclusive). The PCs
  ;; are in sorted order, to allow binary search. We omit the first
  ;; and last PC, since their values are 0 and the length of the code
  ;; vector.
  ;;
  ;; KLUDGE: PC's can't always be represented by FIXNUMs, unless we're
  ;; always careful to put our code in low memory. Is that how it
  ;; works? Would this break if we used a more general memory map? --
  ;; WHN 20000120
  (fun-map (missing-arg) :type simple-vector :read-only t))
