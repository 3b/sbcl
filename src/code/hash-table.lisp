;;;; the needed-on-the-cross-compilation-host part of HASH-TABLE
;;;; implementation

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; HASH-TABLE is implemented as a STRUCTURE-OBJECT.
(sb!xc:defstruct (hash-table (:constructor %make-hash-table))
  ;; The type of hash table this is. Only used for printing and as
  ;; part of the exported interface.
  (test (missing-arg) :type symbol :read-only t)
  ;; The function used to compare two keys. Returns T if they are the
  ;; same and NIL if not.
  (test-fun (missing-arg) :type function :read-only t)
  ;; The function used to compute the hashing of a key. Returns two
  ;; values: the index hashing and T if that might change with the
  ;; next GC.
  (hash-fun (missing-arg) :type function :read-only t)
  ;; how much to grow the hash table by when it fills up. If an index,
  ;; then add that amount. If a floating point number, then multiply
  ;; it by that.
  (rehash-size (missing-arg) :type (or index (single-float (1.0)))
	       :read-only t)
  ;; how full the hash table has to get before we rehash
  (rehash-threshold (missing-arg) :type (single-float (0.0) 1.0) :read-only t)
  ;; The number of entries before a rehash, just one less than the
  ;; size of the next-vector, hash-vector, and half the size of the
  ;; kv-vector.
  (rehash-trigger (missing-arg) :type index)
  ;; The current number of entries in the table.
  (number-entries 0 :type index)
  ;; The Key-Value pair vector.
  (table (missing-arg) :type simple-vector)
  ;; True if this is a weak hash table, meaning that key->value
  ;; mappings will disappear if there are no other references to the
  ;; key. Note: this only matters if the hash function indicates that
  ;; the hashing is EQ based.
  (weak-p nil :type (member t nil))
  ;; Index into the next-vector, chaining together buckets that need
  ;; to be rehashed because their hashing is EQ based and the key has
  ;; been moved by the garbage collector.
  (needing-rehash 0 :type index)
  ;; Index into the Next vector chaining together free slots in the KV
  ;; vector.
  (next-free-kv 0 :type index)
  ;; The index vector. This may be larger than the hash size to help
  ;; reduce collisions.
  (index-vector (missing-arg)
		:type (simple-array (unsigned-byte #.sb!vm:n-word-bits) (*)))
  ;; This table parallels the KV vector, and is used to chain together
  ;; the hash buckets, the free list, and the values needing rehash, a
  ;; slot will only ever be in one of these lists.
  (next-vector (missing-arg)
	       :type (simple-array (unsigned-byte #.sb!vm:n-word-bits) (*)))
  ;; This table parallels the KV table, and can be used to store the
  ;; hash associated with the key, saving recalculation. Could be
  ;; useful for EQL, and EQUAL hash tables. This table is not needed
  ;; for EQ hash tables, and when present the value of #x80000000
  ;; represents EQ-based hashing on the respective key.
  (hash-vector nil :type (or null (simple-array (unsigned-byte
						 #.sb!vm:n-word-bits) (*)))))

(defmacro-mundanely with-hash-table-iterator ((function hash-table) &body body)
  #!+sb-doc
  "WITH-HASH-TABLE-ITERATOR ((function hash-table) &body body)
   provides a method of manually looping over the elements of a hash-table.
   FUNCTION is bound to a generator-macro that, within the scope of the
   invocation, returns one or three values. The first value tells whether
   any objects remain in the hash table. When the first value is non-NIL,
   the second and third values are the key and the value of the next object."
  (let ((n-function (gensym "WITH-HASH-TABLE-ITERATOR-")))
    `(let ((,n-function
	    (let* ((table ,hash-table)
		   (length (length (hash-table-next-vector table)))
		   (index 1))
	      (declare (type (mod #.(floor most-positive-fixnum 2)) index))
	      (labels
		  ((,function ()
		     ;; (We grab the table again on each iteration just in
		     ;; case it was rehashed by a PUTHASH.)
		     (let ((kv-vector (hash-table-table table)))
		       (do ()
			   ((>= index length) (values nil))
			 (let ((key (aref kv-vector (* 2 index)))
			       (value (aref kv-vector (1+ (* 2 index)))))
			   (incf index)
			   (unless (and (eq key +empty-ht-slot+)
					(eq value +empty-ht-slot+))
			     (return (values t key value))))))))
		#',function))))
      (macrolet ((,function () '(funcall ,n-function)))
	,@body))))
