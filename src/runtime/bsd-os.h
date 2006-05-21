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

#ifdef __FreeBSD__
#include <osreldate.h>
#endif

#include <sys/types.h>
#include <sys/mman.h>
#include <sys/signal.h>

#ifdef LISP_FEATURE_DARWIN
#include <mach/mach_types.h>
#endif

typedef caddr_t os_vm_address_t;
#if defined __NetBSD__
typedef vsize_t os_vm_size_t;
#elif defined __OpenBSD__
typedef size_t os_vm_size_t;
#else
typedef vm_size_t os_vm_size_t;
#endif
typedef off_t os_vm_offset_t;
typedef int os_vm_prot_t;
typedef int os_context_register_t;

#if defined __OpenBSD__
/* name defined for compatibility between OpenBSD 3.1 sigaltstack(2) and
 * Linux sigaltstack(2) */
typedef struct sigaltstack stack_t;
#elif defined __FreeBSD__
/* FreeBSD 4.6 and NetBSD 1.6 already have stack_t defined. */
#endif

#if defined __FreeBSD__
/* Note: The man page for sigaction(2) in FreeBSD 4.0 says that this
 * is an mcontext_t, but according to comments by Raymond Wiker in the
 * original FreeBSD port of SBCL, that's wrong, it's actually a
 * ucontext_t. */

#include <sys/ucontext.h>
typedef ucontext_t os_context_t;
/* As the sbcl-devel message from Raymond Wiker 2000-12-01, FreeBSD
 * (unlike Linux and OpenBSD) doesn't let us tweak the CPU's single
 * step flag bit by messing with the flags stored in a signal context,
 * so we need to implement single stepping in a more roundabout way. */
#define CANNOT_GET_TO_SINGLE_STEP_FLAG
#define SIG_MEMORY_FAULT SIGSEGV
/* Sometime in late 2005 FreeBSD was changed to signal SIGSEGV instead
 * of SIGBUS for memory faults, as required by POSIX. In order to
 * support both new and old FreeBSD at the same time, both signals are
 * hooked to the GC write barrier machinery. If you're reading this
 * message in the far future where FreeBSD 6 and earlier are just
 * quaint memories, feel free to delete this hack (and any code that's
 * #ifdef SIG_MEMORY_FAULT2'ed). -- JES, 2005-12-30
 */
#define SIG_MEMORY_FAULT2 SIGBUS

#define SIG_INTERRUPT_THREAD (SIGINFO)
#define SIG_STOP_FOR_GC (SIGUSR1)
#define SIG_RESUME_FROM_GC (SIGUSR2)

#elif defined __OpenBSD__

typedef struct sigcontext os_context_t;
#define SIG_MEMORY_FAULT SIGSEGV

#elif defined __NetBSD__

#include <ucontext.h>
typedef ucontext_t os_context_t;
#define SIG_MEMORY_FAULT SIGSEGV

#elif defined LISP_FEATURE_DARWIN
#include "darwin-os.h"
#else
#error unsupported BSD variant
#endif

#include "target-arch-os.h"
#include "target-arch.h"

#define OS_VM_PROT_READ PROT_READ
#define OS_VM_PROT_WRITE PROT_WRITE
#define OS_VM_PROT_EXECUTE PROT_EXEC
