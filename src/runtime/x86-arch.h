/* FIXME: Aren't preprocessor symbols with underscore prefixes
 * reserved for the system libraries? If so, it would be tidy to
 * rename flags like _X86_ARCH_H so their names are in a part of the
 * namespace that we control. */
#ifndef _X86_ARCH_H
#define _X86_ARCH_H

#define ARCH_HAS_STACK_POINTER

/* FIXME: Do we also want
 *   #define ARCH_HAS_FLOAT_REGISTERS
 * here? (The answer wasn't obvious to me when merging the
 * architecture-abstracting patches for CSR's SPARC port. -- WHN 2002-02-15) */

static inline void 
get_spinlock(lispobj *word,int value)
{
    u32 eax=0;
    do {
	asm ("xor %0,%0\n\
              lock cmpxchg %1,%2" 
	     : "=a" (eax)
	     : "r" (value), "m" (*word)
	     : "memory", "cc");
    } while(eax!=0);
}

static inline void
release_spinlock(lispobj *word)
{
    *word=0;
}

#endif /* _X86_ARCH_H */
