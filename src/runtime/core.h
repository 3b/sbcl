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

#ifndef _CORE_H_
#define _CORE_H_

#include "runtime.h"

struct ndir_entry {
    long identifier;
    long nwords;
    long data_page;
    long address;
    long page_count;
};

extern lispobj load_core_file(char *file);

/* arbitrary string identifying this build, embedded in .core files to
 * prevent people mismatching a runtime built e.g. with :SB-SHOW
 * against a .core built without :SB-SHOW (or against various grosser
 * mismatches, e.g. a .core built with an old version of the code
 * against a runtime with patches which add new C code) */
extern unsigned char build_id[];

#endif
