/*
 * The x86 Linux incarnation of arch-dependent OS-dependent routines.
 * See also "linux-os.c".
 */

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

#include <stdio.h>
#include <stddef.h>
#include <sys/param.h>
#include <sys/file.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>

#define __USE_GNU
#include <sys/ucontext.h>
#undef __USE_GNU


#include "./signal.h"
#include "os.h"
#include "arch.h"
#include "globals.h"
#include "interrupt.h"
#include "interr.h"
#include "lispregs.h"
#include "sbcl.h"
#include <sys/socket.h>
#include <sys/utsname.h>

#include <sys/types.h>
#include <signal.h>
/* #include <sys/sysinfo.h> */
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <asm/ldt.h>
#include <linux/unistd.h>
#include <sys/mman.h>
#include <linux/version.h>
#include "thread.h"		/* dynamic_values_bytes */

#if LINUX_VERSION_CODE < KERNEL_VERSION(2,6,0)
#define user_desc  modify_ldt_ldt_s 
#endif

_syscall3(int, modify_ldt, int, func, void *, ptr, unsigned long, bytecount );

#include "validate.h"
size_t os_vm_page_size;

u32 local_ldt_copy[LDT_ENTRIES*LDT_ENTRY_SIZE/sizeof(u32)];

/* This is never actually called, but it's great for calling from gdb when
 * users have thread-related problems that maintainers can't duplicate */

void debug_get_ldt()
{ 
    int n=modify_ldt (0, local_ldt_copy, sizeof local_ldt_copy);
    printf("%d bytes in ldt: print/x local_ldt_copy\n", n);
}

lispobj modify_ldt_lock;	/* protect all calls to modify_ldt */

int arch_os_thread_init(struct thread *thread) {
    stack_t sigstack;
#ifdef LISP_FEATURE_SB_THREAD
    /* this must be called from a function that has an exclusive lock
     * on all_threads
     */
    struct user_desc ldt_entry = {
	1, 0, 0, /* index, address, length filled in later */
	1, MODIFY_LDT_CONTENTS_DATA, 0, 0, 0, 1
    }; 
    int n;
    get_spinlock(&modify_ldt_lock,thread);
    n=modify_ldt(0,local_ldt_copy,sizeof local_ldt_copy);
    /* get next free ldt entry */

    if(n) {
	u32 *p;
	for(n=0,p=local_ldt_copy;*p;p+=LDT_ENTRY_SIZE/sizeof(u32))
	    n++;
    }
    ldt_entry.entry_number=n;
    ldt_entry.base_addr=(unsigned long) thread;
    ldt_entry.limit=dynamic_values_bytes;
    ldt_entry.limit_in_pages=0;
    if (modify_ldt (1, &ldt_entry, sizeof (ldt_entry)) != 0) {
	modify_ldt_lock=0;
	/* modify_ldt call failed: something magical is not happening */
	return -1;
    }
    __asm__ __volatile__ ("movw %w0, %%fs" : : "q" 
			  ((n << 3) /* selector number */
			   + (1 << 2) /* TI set = LDT */
			   + 3)); /* privilege level */
    thread->tls_cookie=n;
    modify_ldt_lock=0;

    if(n<0) return 0;
#endif
#ifdef LISP_FEATURE_C_STACK_IS_CONTROL_STACK
    /* Signal handlers are run on the control stack, so if it is exhausted
     * we had better use an alternate stack for whatever signal tells us
     * we've exhausted it */
    sigstack.ss_sp=((void *) thread)+dynamic_values_bytes;
    sigstack.ss_flags=0;
    sigstack.ss_size = 32*SIGSTKSZ;
    sigaltstack(&sigstack,0);
#endif
    return 1;
}

struct thread *debug_get_fs() {
    register u32 fs;
    __asm__ __volatile__ ("movl %%fs,%0" : "=r" (fs)  : );
    return fs;
}

/* free any arch/os-specific resources used by thread, which is now
 * defunct.  Not called on live threads
 */

int arch_os_thread_cleanup(struct thread *thread) {
    struct user_desc ldt_entry = {
	0, 0, 0, 
	0, MODIFY_LDT_CONTENTS_DATA, 0, 0, 0, 0
    }; 

    ldt_entry.entry_number=thread->tls_cookie;
    get_spinlock(&modify_ldt_lock,thread);
    if (modify_ldt (1, &ldt_entry, sizeof (ldt_entry)) != 0) {
	modify_ldt_lock=0;
	/* modify_ldt call failed: something magical is not happening */
	return 0;
    }
    modify_ldt_lock=0;
    return 1;
}


os_context_register_t *
os_context_register_addr(os_context_t *context, int offset)
{
#define RCASE(name) case reg_ ## name: return &context->uc_mcontext.gregs[REG_ ## name];
    switch(offset) {
        RCASE(RAX)
	RCASE(RCX)
	RCASE(RDX)
	RCASE(RBX)
	RCASE(RSP)
	RCASE(RBP)
	RCASE(RSI)
	RCASE(RDI)
	RCASE(R8)
	RCASE(R9)
	RCASE(R10)
	RCASE(R11)
	RCASE(R12)
	RCASE(R13)
	RCASE(R14)
	RCASE(R15)
      default: 
	if(offset<NGREG) 
	    return &context->uc_mcontext.gregs[offset/2+4];
	else return 0;
    }
    return &context->uc_mcontext.gregs[offset];
}

os_context_register_t *
os_context_pc_addr(os_context_t *context)
{
    return &context->uc_mcontext.gregs[REG_RIP]; /*  REG_EIP */
}

os_context_register_t *
os_context_sp_addr(os_context_t *context)
{				
    return &context->uc_mcontext.gregs[REG_RSP];
}

os_context_register_t *
os_context_fp_addr(os_context_t *context)
{
    return &context->uc_mcontext.gregs[REG_RBP];
}

unsigned long
os_context_fp_control(os_context_t *context)
{
#if 0
    return ((((context->uc_mcontext.fpregs->cw) & 0xffff) ^ 0x3f) |
	    (((context->uc_mcontext.fpregs->sw) & 0xffff) << 16));
#else
    return 0;
#endif
}

sigset_t *
os_context_sigmask_addr(os_context_t *context)
{
    return &context->uc_sigmask;
}

void
os_restore_fp_control(os_context_t *context)
{
#if 0
    asm ("fldcw %0" : : "m" (context->uc_mcontext.fpregs->cw));
#endif
}

void
os_flush_icache(os_vm_address_t address, os_vm_size_t length)
{
}

