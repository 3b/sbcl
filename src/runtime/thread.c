#include <stdlib.h>
#include <stdio.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <errno.h>
#include "runtime.h"
#include "sbcl.h"
#include "validate.h"		/* for CONTROL_STACK_SIZE etc */
#include "thread.h"
#include "arch.h"
#include "target-arch-os.h"
#include "os.h"
#include "globals.h"
#include "dynbind.h"
#include "genesis/cons.h"
#define ALIEN_STACK_SIZE (1*1024*1024) /* 1Mb size chosen at random */

int dynamic_values_bytes=4096*sizeof(lispobj);	/* same for all threads */
struct thread *all_threads;
volatile lispobj all_threads_lock;
extern struct interrupt_data * global_interrupt_data;

void get_spinlock(lispobj *word,int value);

int
initial_thread_trampoline(struct thread *th)
{
    lispobj function;
    lispobj *args = NULL;
    function = th->unbound_marker;
    th->unbound_marker = UNBOUND_MARKER_WIDETAG;
    if(arch_os_thread_init(th)==0) return 1;

    if(th->pid < 1) lose("th->pid not set up right");
    th->state=STATE_RUNNING;
#if defined(LISP_FEATURE_X86)
    return call_into_lisp_first_time(function,args,0);
#else
    return funcall0(function);
#endif
}

/* this is the first thing that clone() runs in the child (which is
 * why the silly calling convention).  Basically it calls the user's
 * requested lisp function after doing arch_os_thread_init and
 * whatever other bookkeeping needs to be done
 */

int
new_thread_trampoline(struct thread *th)
{
    lispobj function;
    function = th->unbound_marker;
    th->unbound_marker = UNBOUND_MARKER_WIDETAG;
    if(arch_os_thread_init(th)==0) return 1;	

    /* wait here until our thread is linked into all_threads: see below */
    while(th->pid<1) sched_yield();

    th->state=STATE_RUNNING;
    return funcall0(function);
}

/* this is called from any other thread to create the new one, and
 * initialize all parts of it that can be initialized from another 
 * thread 
 */

struct thread * create_thread_struct(lispobj initial_function) {
    union per_thread_data *per_thread;
    struct thread *th=0;	/*  subdue gcc */
    void *spaces=0;

    /* may as well allocate all the spaces at once: it saves us from
     * having to decide what to do if only some of the allocations
     * succeed */
    spaces=os_validate(0,
		       THREAD_CONTROL_STACK_SIZE+
		       BINDING_STACK_SIZE+
		       ALIEN_STACK_SIZE+
		       dynamic_values_bytes+
		       32*SIGSTKSZ
		       );
    if(!spaces) goto cleanup;
    per_thread=(union per_thread_data *)
	(spaces+
	 THREAD_CONTROL_STACK_SIZE+
	 BINDING_STACK_SIZE+
	 ALIEN_STACK_SIZE);

    th=&per_thread->thread;
    if(all_threads) {
	memcpy(per_thread,arch_os_get_current_thread(),
	       dynamic_values_bytes);
    } else {
#ifdef LISP_FEATURE_SB_THREAD
	int i;
	for(i=0;i<(dynamic_values_bytes/sizeof(lispobj));i++)
	    per_thread->dynamic_values[i]=UNBOUND_MARKER_WIDETAG;
	if(SymbolValue(FREE_TLS_INDEX,0)==UNBOUND_MARKER_WIDETAG) 
	    SetSymbolValue
		(FREE_TLS_INDEX,
		 make_fixnum(MAX_INTERRUPTS+
			     sizeof(struct thread)/sizeof(lispobj)),
		 0);
#define STATIC_TLS_INIT(sym,field) \
  ((struct symbol *)(sym-OTHER_POINTER_LOWTAG))->tls_index= \
  make_fixnum(THREAD_SLOT_OFFSET_WORDS(field))
				  
	STATIC_TLS_INIT(BINDING_STACK_START,binding_stack_start);
	STATIC_TLS_INIT(BINDING_STACK_POINTER,binding_stack_pointer);
	STATIC_TLS_INIT(CONTROL_STACK_START,control_stack_start);
	STATIC_TLS_INIT(CONTROL_STACK_END,control_stack_end);
	STATIC_TLS_INIT(ALIEN_STACK,alien_stack_pointer);
#ifdef LISP_FEATURE_X86
	STATIC_TLS_INIT(PSEUDO_ATOMIC_ATOMIC,pseudo_atomic_atomic);
	STATIC_TLS_INIT(PSEUDO_ATOMIC_INTERRUPTED,pseudo_atomic_interrupted);
#endif
#undef STATIC_TLS_INIT
#endif
    }

    th->control_stack_start = spaces;
    th->binding_stack_start=
	(lispobj*)((void*)th->control_stack_start+THREAD_CONTROL_STACK_SIZE);
    th->control_stack_end = th->binding_stack_start;
    th->alien_stack_start=
	(lispobj*)((void*)th->binding_stack_start+BINDING_STACK_SIZE);
    th->binding_stack_pointer=th->binding_stack_start;
    th->this=th;
    th->pid=0;
    th->state=STATE_STOPPED;
#ifdef LISP_FEATURE_STACK_GROWS_DOWNWARD_NOT_UPWARD
    th->alien_stack_pointer=((void *)th->alien_stack_start
			     + ALIEN_STACK_SIZE-4); /* naked 4.  FIXME */
#else
    th->alien_stack_pointer=((void *)th->alien_stack_start);
#endif
#ifdef LISP_FEATURE_X86
    th->pseudo_atomic_interrupted=0;
    th->pseudo_atomic_atomic=0;
#endif
#ifdef LISP_FEATURE_GENCGC
    gc_set_region_empty(&th->alloc_region);
#endif

#ifndef LISP_FEATURE_SB_THREAD
    /* the tls-points-into-struct-thread trick is only good for threaded
     * sbcl, because unithread sbcl doesn't have tls.  So, we copy the
     * appropriate values from struct thread here, and make sure that 
     * we use the appropriate SymbolValue macros to access any of the
     * variable quantities from the C runtime.  It's not quite OAOOM,
     * it just feels like it */
    SetSymbolValue(BINDING_STACK_START,th->binding_stack_start,th);
    SetSymbolValue(CONTROL_STACK_START,th->control_stack_start,th);
    SetSymbolValue(CONTROL_STACK_END,th->control_stack_end,th);
#if defined(LISP_FEATURE_X86) || defined(LISP_FEATURE_X86_64)
    SetSymbolValue(BINDING_STACK_POINTER,th->binding_stack_pointer,th);
    SetSymbolValue(ALIEN_STACK,th->alien_stack_pointer,th);
    SetSymbolValue(PSEUDO_ATOMIC_ATOMIC,th->pseudo_atomic_atomic,th);
    SetSymbolValue(PSEUDO_ATOMIC_INTERRUPTED,th->pseudo_atomic_interrupted,th);
#else
    current_binding_stack_pointer=th->binding_stack_pointer;
    current_control_stack_pointer=th->control_stack_start;
#endif
#endif    
    bind_variable(CURRENT_CATCH_BLOCK,make_fixnum(0),th);
    bind_variable(CURRENT_UNWIND_PROTECT_BLOCK,make_fixnum(0),th); 
    bind_variable(FREE_INTERRUPT_CONTEXT_INDEX,make_fixnum(0),th);
    bind_variable(INTERRUPT_PENDING, NIL,th);
    bind_variable(INTERRUPTS_ENABLED,T,th);

    th->interrupt_data=os_validate(0,(sizeof (struct interrupt_data)));
    if(all_threads) 
	memcpy(th->interrupt_data,
	       arch_os_get_current_thread()->interrupt_data,
	       sizeof (struct interrupt_data));
    else 
	memcpy(th->interrupt_data,global_interrupt_data,
	       sizeof (struct interrupt_data));

    th->unbound_marker=initial_function;
    return th;
 cleanup:
    /* if(th && th->tls_cookie>=0) os_free_tls_pointer(th); */
    if(spaces) os_invalidate(spaces,
			     THREAD_CONTROL_STACK_SIZE+BINDING_STACK_SIZE+
			     ALIEN_STACK_SIZE+dynamic_values_bytes);
    return 0;
}

void link_thread(struct thread *th,pid_t kid_pid)
{
    get_spinlock(&all_threads_lock,kid_pid);
    th->next=all_threads;
    all_threads=th;
    /* note that th->pid is 0 at this time.  We rely on all_threads_lock
     * to ensure that we don't have >1 thread with pid=0 on the list at once
     */
    protect_control_stack_guard_page(th->pid,1);
    release_spinlock(&all_threads_lock);
    th->pid=kid_pid;		/* child will not start until this is set */
}

pid_t create_initial_thread(lispobj initial_function) {
    struct thread *th=create_thread_struct(initial_function);
    pid_t kid_pid=getpid();
    if(th && kid_pid>0) {
	link_thread(th,kid_pid);
	initial_thread_trampoline(all_threads); /* no return */
    } else lose("can't create initial thread");
}

#ifdef LISP_FEATURE_LINUX
pid_t create_thread(lispobj initial_function) {
    struct thread *th=create_thread_struct(initial_function);
    pid_t kid_pid=clone(new_thread_trampoline,
			(((void*)th->control_stack_start)+
			 THREAD_CONTROL_STACK_SIZE-4),
			CLONE_FILES|SIG_THREAD_EXIT|CLONE_VM,th);

    if(th && kid_pid>0) {
	link_thread(th,kid_pid);
	return th->pid;
    } else {
	destroy_thread(th);
	return 0;
    }
}
#endif

void destroy_thread (struct thread *th)
{
    /* precondition: the unix task has already been killed and exited.
     * This is called by the parent */
#ifdef LISP_FEATURE_GENCGC
    gc_alloc_update_page_tables(0, &th->alloc_region);
#endif
    get_spinlock(&all_threads_lock,th->pid);
    th->state=STATE_STOPPED;
    if(th==all_threads) 
	all_threads=th->next;
    else {
	struct thread *th1=all_threads;
	while(th1 && th1->next!=th) th1=th1->next;
	if(th1)	th1->next=th->next;	/* unlink */
    }
    release_spinlock(&all_threads_lock);
    if(th && th->tls_cookie>=0) arch_os_thread_cleanup(th); 
    os_invalidate((os_vm_address_t) th->control_stack_start,
		  ((sizeof (lispobj))
		   * (th->control_stack_end-th->control_stack_start)) +
		  BINDING_STACK_SIZE+ALIEN_STACK_SIZE+dynamic_values_bytes+
		  32*SIGSTKSZ);
}


struct thread *find_thread_by_pid(pid_t pid) 
{
    struct thread *th;
    for_each_thread(th)
	if(th->pid==pid) return th;
    return 0;
}

/* These are not needed unless #+SB-THREAD, and since sigwaitinfo()
 * doesn't seem to be easily available everywhere (OpenBSD...) it's
 * more trouble than it's worth to compile it when not needed. */
#if defined LISP_FEATURE_SB_THREAD
void block_sigcont(void)
{
    /* don't allow ourselves to receive SIGCONT while we're in the
     * "ambiguous" state of being on the queue but not actually stopped.
     */
    sigset_t newset;
    sigemptyset(&newset);
    sigaddset(&newset,SIG_DEQUEUE);
    sigprocmask(SIG_BLOCK, &newset, 0); 
}

void unblock_sigcont_and_sleep(void)
{
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set,SIG_DEQUEUE);
    do {
	errno=0;
	sigwaitinfo(&set,0);
    }while(errno==EINTR);
    sigprocmask(SIG_UNBLOCK,&set,0);
}

int interrupt_thread(pid_t pid, lispobj function)
{
    union sigval sigval;
    sigval.sival_int=function;

    return sigqueue(pid, SIG_INTERRUPT_THREAD, sigval);
}

int signal_thread_to_dequeue (pid_t pid)
{
    return kill (pid, SIG_DEQUEUE);
}


/* stopping the world is a two-stage process.  From this thread we signal 
 * all the others with SIG_STOP_FOR_GC.  The handler for this thread does
 * the usual pseudo-atomic checks (we don't want to stop a thread while 
 * it's in the middle of allocation) then kills _itself_ with SIGSTOP.
 */

void gc_stop_the_world()
{
    /* stop all other threads by sending them SIG_STOP_FOR_GC */
    struct thread *p,*th=arch_os_get_current_thread();
    pid_t old_pid;
    int finished=0;
    do {
	get_spinlock(&all_threads_lock,th->pid);
	for(p=all_threads,old_pid=p->pid; p; p=p->next) {
	    if(p==th) continue;
	    if(p->state!=STATE_RUNNING) continue;
	    p->state=STATE_STOPPING;
	    kill(p->pid,SIG_STOP_FOR_GC);
	}
	release_spinlock(&all_threads_lock);
	sched_yield();
	/* if everything has stopped, and there is no possibility that
	 * a new thread has been created, we're done.  Otherwise go
	 * round again and signal anything that sprang up since last
	 * time	 */
	if(old_pid==all_threads->pid) {
	    finished=1;
	    for_each_thread(p) 
		finished = finished &&
		((p==th) || (p->state==STATE_STOPPED));
	}
    } while(!finished);
}

void gc_start_the_world()
{
    struct thread *p,*th=arch_os_get_current_thread();
    get_spinlock(&all_threads_lock,th->pid);
    for(p=all_threads;p;p=p->next) {
	if(p==th) continue;
	p->state=STATE_RUNNING;
	kill(p->pid,SIGCONT);
    }
    release_spinlock(&all_threads_lock);
}
#endif
