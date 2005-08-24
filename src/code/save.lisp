;;;; Dump the current Lisp image into a core file. Also contains
;;;; various high-level initialization stuff: loading init files and
;;;; parsing environment variables.
;;;;
;;;; (All the real work is done by C.)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;;; SAVE-LISP-AND-DIE itself

(define-alien-routine "save" (boolean)
  (file c-string)
  (initial-fun (unsigned #.sb!vm:n-word-bits)))

#!+gencgc
(define-alien-routine "gc_and_save" void
  (file c-string))

#!+gencgc
(defvar sb!vm::*restart-lisp-function*)

(defun save-lisp-and-die (core-file-name &key
                                         (toplevel #'toplevel-init)
                                         (purify #!+gencgc nil
                                                 #!-gencgc t)
                                         (root-structures ())
                                         (environment-name "auxiliary"))
  #!+sb-doc
  "Save a \"core image\", i.e. enough information to restart a Lisp
process later in the same state, in the file of the specified name.
Only global state is preserved: the stack is unwound in the process.

The following &KEY arguments are defined:

  :TOPLEVEL
     The function to run when the created core file is resumed. The
     default function handles command line toplevel option processing
     and runs the top level read-eval-print loop. This function should
     not return.

  :PURIFY
     If true (the default on cheneygc), do a purifying GC which moves all
     dynamically allocated objects into static space. This takes
     somewhat longer than the normal GC which is otherwise done, but
     it's only done once, and subsequent GC's will be done less often
     and will take less time in the resulting core file. See the PURIFY
     function. For platforms that use the generational garbage collector
     (x86 and x86-64) purification generally results in a loss of
     performance.

  :ROOT-STRUCTURES
     This should be a list of the main entry points in any newly loaded
     systems. This need not be supplied, but locality and/or GC performance
     may be better if they are. Meaningless if :PURIFY is NIL. See the
     PURIFY function.

  :ENVIRONMENT-NAME
     This is also passed to the PURIFY function when :PURIFY is T.
     (rarely used)

The save/load process changes the values of some global variables:

  *STANDARD-OUTPUT*, *DEBUG-IO*, etc.
    Everything related to open streams is necessarily changed, since
    the OS won't let us preserve a stream across save and load.

  *DEFAULT-PATHNAME-DEFAULTS*
    This is reinitialized to reflect the working directory where the
    saved core is loaded.

Foreign objects loaded with SB-ALIEN:LOAD-SHARED-OBJECT are
automatically reloaded on startup, but references to foreign symbols
do not survive intact on all platforms: in this case a WARNING is
signalled when saving the core. If no warning is signalled, then the
foreign symbol references will remain intact. Platforms where this is
currently the case are x86/FreeBSD, x86/Linux, x86/NetBSD,
sparc/Linux, sparc/SunOS, and ppc/Darwin.

This implementation is not as polished and painless as you might like:
  * It corrupts the current Lisp image enough that the current process
    needs to be killed afterwards. This can be worked around by forking
    another process that saves the core.
  * It will not work if multiple threads are in use.
  * There is absolutely no binary compatibility of core images between
    different runtime support programs. Even runtimes built from the same
    sources at different times are treated as incompatible for this
    purpose.
This isn't because we like it this way, but just because there don't
seem to be good quick fixes for either limitation and no one has been
sufficiently motivated to do lengthy fixes."
  (deinit)
  ;; FIXME: Would it be possible to unmix the PURIFY logic from this
  ;; function, and just do a GC :FULL T here? (Then if the user wanted
  ;; a PURIFYed image, he'd just run PURIFY immediately before calling
  ;; SAVE-LISP-AND-DIE.)
  (labels ((restart-lisp ()
             (handling-end-of-the-world
               (reinit)
               (funcall toplevel)))
           (save-core (gc)
             (when gc
               #!-gencgc (gc)
               ;; Do a destructive non-conservative GC, and then save a core.
               ;; A normal GC will leave huge amounts of storage unreclaimed
               ;; (over 50% on x86). This needs to be done by a single function
               ;; since the GC will invalidate the stack.
               #!+gencgc (gc-and-save (unix-namestring core-file-name nil)))
             (without-gcing
              (save (unix-namestring core-file-name nil)
                    (get-lisp-obj-address #'restart-lisp)))))
    ;; Save the restart function into a static symbol, to allow GC-AND-SAVE
    ;; access to it even after the GC has moved it.
    (setf sb!vm::*restart-lisp-function* #'restart-lisp)
    (ecase purify
      ((t)
       (purify :root-structures root-structures
               :environment-name environment-name)
       (save-core nil))
      ((nil)
       (purify :compact-only t
               :environment-name environment-name)
       (save-core t)))))

(defun deinit ()
  (dolist (hook *save-hooks*)
    (with-simple-restart (continue "Skip this save hook.")
      (funcall hook)))
  (when (fboundp 'cancel-finalization)
    (cancel-finalization sb!sys:*tty*))
  (profile-deinit)
  (debug-deinit)
  (foreign-deinit))
