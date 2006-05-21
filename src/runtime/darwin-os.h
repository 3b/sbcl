#ifndef _DARWIN_OS_H
#define _DARWIN_OS_H

/* this is meant to be included from bsd-os.h */

#include <mach/mach_init.h>
#include <mach/task.h>

/* man pages claim that the third argument is a sigcontext struct,
   but ucontext_t is defined, matches sigcontext where sensible,
   offers better access to mcontext, and is of course the SUSv2-
   mandated type of the third argument, so we use that instead.
   If Apple is going to break ucontext_t out of spite, I'm going
   to be cross with them ;) -- PRM */

#if defined(LISP_FEATURE_X86)
#include <sys/ucontext.h>
#include <sys/_types.h>
typedef struct ucontext os_context_t;

#else
#include <ucontext.h>
typedef ucontext_t os_context_t;
#endif

#define SIG_MEMORY_FAULT SIGBUS

#define SIG_INTERRUPT_THREAD (SIGINFO)
#define SIG_STOP_FOR_GC (SIGUSR1)
#define SIG_RESUME_FROM_GC (SIGUSR2)

#endif /* _DARWIN_OS_H */
