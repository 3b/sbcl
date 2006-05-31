#ifndef _X86_BSD_OS_H
#define _X86_BSD_OS_H

static inline os_context_t *arch_os_get_context(void **void_context) {
    return (os_context_t *) *void_context;
}

/* The different BSD variants have diverged in exactly where they
 * store signal context information, but at least they tend to use the
 * same stems to name the structure fields, so by using this macro we
 * can share a fair amount of code between different variants. */
#if defined __FreeBSD__
#define CONTEXT_ADDR_FROM_STEM(stem) &context->uc_mcontext.mc_ ## stem
#elif defined(__OpenBSD__)
#define CONTEXT_ADDR_FROM_STEM(stem) &context->sc_ ## stem
#elif defined __NetBSD__
#define CONTEXT_ADDR_FROM_STEM(stem) &((context)->uc_mcontext.__gregs[_REG_ ## stem])
#else
#error unsupported BSD variant
#endif

#if defined(LISP_FEATURE_SB_THREAD)

#if defined LISP_FEATURE_FREEBSD
/* FIXME: why is this only done for SB-THREAD? */
#define RESTORE_FP_CONTROL_FROM_CONTEXT
void os_restore_fp_control(os_context_t *context);
#endif

#endif

#endif /* _X86_BSD_OS_H */
