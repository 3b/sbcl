/*
 * support for dynamic binding from C
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

#include "runtime.h"
#include "sbcl.h"
#include "globals.h"
#include "dynbind.h"
#include "genesis/symbol.h"
#include "genesis/binding.h"
#include "genesis/static-symbols.h"

#if defined(__i386__)
#define GetBSP() ((struct binding *)SymbolValue(BINDING_STACK_POINTER))
#define SetBSP(value) SetSymbolValue(BINDING_STACK_POINTER, (lispobj)(value))
#else
#define GetBSP() ((struct binding *)current_binding_stack_pointer)
#define SetBSP(value) (current_binding_stack_pointer=(lispobj *)(value))
#endif

void bind_variable(lispobj symbol, lispobj value)
{
    lispobj old_value;
    struct binding *binding;

    old_value = SymbolValue(symbol);
    binding = GetBSP();
    SetBSP(binding+1);

    binding->value = old_value;
    binding->symbol = symbol;
    SetSymbolValue(symbol, value);
}

void
unbind(void)
{
    struct binding *binding;
    lispobj symbol;
	
    binding = GetBSP() - 1;
		
    symbol = binding->symbol;

    SetSymbolValue(symbol, binding->value);

    binding->symbol = 0;

    SetBSP(binding);
}

void
unbind_to_here(lispobj *bsp)
{
    struct binding *target = (struct binding *)bsp;
    struct binding *binding = GetBSP();
    lispobj symbol;

    while (target < binding) {
	binding--;

	symbol = binding->symbol;

	if (symbol) {
	    SetSymbolValue(symbol, binding->value);
	    binding->symbol = 0;
	}

    }
    SetBSP(binding);
}
