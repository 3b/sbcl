/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#if !defined(_INCLUDE_GLOBALS_H_)
#define _INCLUDED_GLOBALS_H_

#ifndef LANGUAGE_ASSEMBLY

#include <sys/types.h>
#include <unistd.h>
#include "sbcl.h"
#include "runtime.h"

extern int foreign_function_call_active;
extern boolean stop_the_world;

extern lispobj *current_control_stack_pointer;
extern lispobj *current_control_frame_pointer;
#if !defined(LISP_FEATURE_X86)
extern lispobj *current_binding_stack_pointer;
#endif

#if !defined(LISP_FEATURE_X86)
/* FIXME: Why doesn't the x86 need this? */
extern lispobj *dynamic_space_free_pointer;
extern lispobj *current_auto_gc_trigger;
#endif

extern lispobj *current_dynamic_space;
extern pid_t parent_pid;
extern boolean stop_the_world;

extern void globals_init(void);

#else /* LANGUAGE_ASSEMBLY */

#ifdef mips
#define EXTERN(name,bytes) .extern name bytes
#endif
/**/
#ifdef sparc
#ifdef SVR4
#define EXTERN(name,bytes) .global name
#else
#define EXTERN(name,bytes) .global _ ## name
#endif
#endif
/**/
#ifdef alpha
#ifdef __linux__
#define EXTERN(name,bytes) .globl name 
#endif
#ifdef osf1
#define EXTERN(name,bytes) .globl name
#endif
#endif
#ifdef ppc
#ifdef LISP_FEATURE_DARWIN
#define EXTERN(name,bytes) .globl _/**/name
#else
#define EXTERN(name,bytes) .globl name 
#endif
#endif
#ifdef LISP_FEATURE_X86
#ifdef __linux__
/* I'm very dubious about this.  Linux hasn't used _ on external names
 * since ELF became prevalent - i.e. about 1996, on x86    -dan 20010125 */
#define EXTERN(name,bytes) .globl _/**/name
#else
#define EXTERN(name,bytes) .global _ ## name
#endif
#endif

/* FIXME : these sizes are, incidentally, bogus on Alpha.  But the
 * EXTERN macro doesn't use its second arg anyway, so no immediate harm
 * done   -dan 2002.05.07
 */

EXTERN(foreign_function_call_active, N_WORD_BYTES)

EXTERN(current_control_stack_pointer, N_WORD_BYTES)
EXTERN(current_control_frame_pointer, N_WORD_BYTES)
EXTERN(current_binding_stack_pointer, N_WORD_BYTES)
EXTERN(dynamic_space_free_pointer, N_WORD_BYTES)
EXTERN(current_dynamic_space, N_WORD_BYTES)

#ifdef mips
EXTERN(current_flags_register, N_WORD_BYTES)
#endif

#endif /* LANGUAGE_ASSEMBLY */

#endif /* _INCLUDED_GLOBALS_H_ */
