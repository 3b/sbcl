/*
 * Rummage through the system header files using the C compiler itself
 * as a parser, extracting stuff like preprocessor constants and the
 * sizes and signedness of basic system types, and write it out as
 * Lisp code.
 */

/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * While most of SBCL is derived from the CMU CL system, many
 * utilities for the build process (like this one) were written from
 * scratch after the fork from CMU CL.
 *
 * This software is in the public domain and is provided with
 * absolutely no warranty. See the COPYING and CREDITS files for
 * more information.
 */

#include <stdio.h>
#include <sys/types.h>
#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #include <stdlib.h>
  #include <shlobj.h>
#else
  #include <sys/times.h>
  #include <sys/wait.h>
  #include <sys/ioctl.h>
  #include <sys/termios.h>
  #ifdef __APPLE_CC__
    #include "../src/runtime/ppc-darwin-dlshim.h"
    #include "../src/runtime/ppc-darwin-langinfo.h"
  #else
    #include <dlfcn.h>
    #include <langinfo.h>
  #endif
#endif

#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>

#include "genesis/config.h"

#define DEFTYPE(lispname,cname) { cname foo; \
    printf("(define-alien-type " lispname " (%s %d))\n", (((foo=-1)<0) ? "sb!alien:signed" : "unsigned"), (8 * (sizeof foo))); }

void
defconstant(char* lisp_name, long unix_number)
{
    printf("(defconstant %s %ld) ; #x%lx\n",
           lisp_name, unix_number, unix_number);
}

void deferrno(char* lisp_name, long unix_number)
{
    defconstant(lisp_name, unix_number);
}

void defsignal(char* lisp_name, long unix_number)
{
    defconstant(lisp_name, unix_number);
}

int
main(int argc, char *argv[])
{
    /* don't need no steenking command line arguments */
    if (1 != argc) {
        fprintf(stderr, "argh! command line argument(s)\n");
        exit(1);
    }

    /* don't need no steenking hand-editing */
    printf(
";;;; This is an automatically generated file, please do not hand-edit it.\n\
;;;; See the program \"grovel-headers.c\".\n\
\n\
");
#ifdef _WIN32
    printf("(in-package \"SB!WIN32\")\n\n");

    defconstant ("input-record-size", sizeof (INPUT_RECORD));

    defconstant ("MAX_PATH", MAX_PATH);

    printf(";;; CSIDL\n");

    defconstant ("CSIDL_DESKTOP", CSIDL_DESKTOP);
    defconstant ("CSIDL_INTERNET", CSIDL_INTERNET);
    defconstant ("CSIDL_PROGRAMS", CSIDL_PROGRAMS);
    defconstant ("CSIDL_CONTROLS", CSIDL_CONTROLS);
    defconstant ("CSIDL_PRINTERS", CSIDL_PRINTERS);
    defconstant ("CSIDL_PERSONAL", CSIDL_PERSONAL);
    defconstant ("CSIDL_FAVORITES", CSIDL_FAVORITES);
    defconstant ("CSIDL_STARTUP", CSIDL_STARTUP);
    defconstant ("CSIDL_RECENT", CSIDL_RECENT);
    defconstant ("CSIDL_SENDTO", CSIDL_SENDTO);
    defconstant ("CSIDL_BITBUCKET", CSIDL_BITBUCKET);
    defconstant ("CSIDL_STARTMENU", CSIDL_STARTMENU);
    defconstant ("CSIDL_DESKTOPDIRECTORY", CSIDL_DESKTOPDIRECTORY);
    defconstant ("CSIDL_DRIVES", CSIDL_DRIVES);
    defconstant ("CSIDL_NETWORK", CSIDL_NETWORK);
    defconstant ("CSIDL_NETHOOD", CSIDL_NETHOOD);
    defconstant ("CSIDL_FONTS", CSIDL_FONTS);
    defconstant ("CSIDL_TEMPLATES", CSIDL_TEMPLATES);
    defconstant ("CSIDL_COMMON_STARTMENU", CSIDL_COMMON_STARTMENU);
    defconstant ("CSIDL_COMMON_PROGRAMS", CSIDL_COMMON_PROGRAMS);
    defconstant ("CSIDL_COMMON_STARTUP", CSIDL_COMMON_STARTUP);
    defconstant ("CSIDL_COMMON_DESKTOPDIRECTORY", CSIDL_COMMON_DESKTOPDIRECTORY);
    defconstant ("CSIDL_APPDATA", CSIDL_APPDATA);
    defconstant ("CSIDL_PRINTHOOD", CSIDL_PRINTHOOD);
    defconstant ("CSIDL_LOCAL_APPDATA", CSIDL_LOCAL_APPDATA);
    defconstant ("CSIDL_ALTSTARTUP", CSIDL_ALTSTARTUP);
    defconstant ("CSIDL_COMMON_ALTSTARTUP", CSIDL_COMMON_ALTSTARTUP);
    defconstant ("CSIDL_COMMON_FAVORITES", CSIDL_COMMON_FAVORITES);
    defconstant ("CSIDL_INTERNET_CACHE", CSIDL_INTERNET_CACHE);
    defconstant ("CSIDL_COOKIES", CSIDL_COOKIES);
    defconstant ("CSIDL_HISTORY", CSIDL_HISTORY);
    defconstant ("CSIDL_COMMON_APPDATA", CSIDL_COMMON_APPDATA);
    defconstant ("CSIDL_WINDOWS", CSIDL_WINDOWS);
    defconstant ("CSIDL_SYSTEM", CSIDL_SYSTEM);
    defconstant ("CSIDL_PROGRAM_FILES", CSIDL_PROGRAM_FILES);
    defconstant ("CSIDL_MYPICTURES", CSIDL_MYPICTURES);
    defconstant ("CSIDL_PROFILE", CSIDL_PROFILE);
    defconstant ("CSIDL_SYSTEMX86", CSIDL_SYSTEMX86);
    defconstant ("CSIDL_PROGRAM_FILESX86", CSIDL_PROGRAM_FILESX86);
    defconstant ("CSIDL_PROGRAM_FILES_COMMON", CSIDL_PROGRAM_FILES_COMMON);
    defconstant ("CSIDL_PROGRAM_FILES_COMMONX86", CSIDL_PROGRAM_FILES_COMMONX86);
    defconstant ("CSIDL_COMMON_TEMPLATES", CSIDL_COMMON_TEMPLATES);
    defconstant ("CSIDL_COMMON_DOCUMENTS", CSIDL_COMMON_DOCUMENTS);
    defconstant ("CSIDL_COMMON_ADMINTOOLS", CSIDL_COMMON_ADMINTOOLS);
    defconstant ("CSIDL_ADMINTOOLS", CSIDL_ADMINTOOLS);
    defconstant ("CSIDL_CONNECTIONS", CSIDL_CONNECTIONS);
    defconstant ("CSIDL_COMMON_MUSIC", CSIDL_COMMON_MUSIC);
    defconstant ("CSIDL_COMMON_PICTURES", CSIDL_COMMON_PICTURES);
    defconstant ("CSIDL_COMMON_VIDEO", CSIDL_COMMON_VIDEO);
    defconstant ("CSIDL_RESOURCES", CSIDL_RESOURCES);
    defconstant ("CSIDL_RESOURCES_LOCALIZED", CSIDL_RESOURCES_LOCALIZED);
    defconstant ("CSIDL_COMMON_OEM_LINKS", CSIDL_COMMON_OEM_LINKS);
    defconstant ("CSIDL_CDBURN_AREA", CSIDL_CDBURN_AREA);
    defconstant ("CSIDL_COMPUTERSNEARME", CSIDL_COMPUTERSNEARME);
    defconstant ("CSIDL_FLAG_DONT_VERIFY", CSIDL_FLAG_DONT_VERIFY);
    defconstant ("CSIDL_FLAG_CREATE", CSIDL_FLAG_CREATE);
    defconstant ("CSIDL_FLAG_MASK", CSIDL_FLAG_MASK);

    printf(";;; FormatMessage\n");

    defconstant ("FORMAT_MESSAGE_ALLOCATE_BUFFER", FORMAT_MESSAGE_ALLOCATE_BUFFER);
    defconstant ("FORMAT_MESSAGE_FROM_SYSTEM", FORMAT_MESSAGE_FROM_SYSTEM);

    printf(";;; Errors\n");

    defconstant ("ERROR_ENVVAR_NOT_FOUND", ERROR_ENVVAR_NOT_FOUND);

#else
    printf("(in-package \"SB!ALIEN\")\n\n");

    printf (";;;flags for dlopen()\n");

    defconstant ("rtld-lazy", RTLD_LAZY);
    defconstant ("rtld-now", RTLD_NOW);
    defconstant ("rtld-global", RTLD_GLOBAL);

    printf("(in-package \"SB!UNIX\")\n\n");

    printf(";;; langinfo\n");
    defconstant("codeset", CODESET);

    printf(";;; types, types, types\n");
    DEFTYPE("clock-t", clock_t);
    DEFTYPE("dev-t",   dev_t);
    DEFTYPE("gid-t",   gid_t);
    DEFTYPE("ino-t",   ino_t);
    DEFTYPE("mode-t",  mode_t);
    DEFTYPE("nlink-t", nlink_t);
    DEFTYPE("off-t",   off_t);
    DEFTYPE("size-t",  size_t);
    DEFTYPE("time-t",  time_t);
    DEFTYPE("uid-t",   uid_t);
    printf("\n");

    printf(";;; fcntl.h (or unistd.h on OpenBSD and NetBSD)\n");
    defconstant("r_ok", R_OK);
    defconstant("w_ok", W_OK);
    defconstant("x_ok", X_OK);
    defconstant("f_ok", F_OK);
    printf("\n");

    printf(";;; fcntlbits.h\n");
    defconstant("o_rdonly",  O_RDONLY);
    defconstant("o_wronly",  O_WRONLY);
    defconstant("o_rdwr",    O_RDWR);
    defconstant("o_accmode", O_ACCMODE);
    defconstant("o_creat",   O_CREAT);
    defconstant("o_excl",    O_EXCL);
    defconstant("o_noctty",  O_NOCTTY);
    defconstant("o_trunc",   O_TRUNC);
    defconstant("o_append",  O_APPEND);
    printf(";;;\n");
    defconstant("s-ifmt",  S_IFMT);
    defconstant("s-ififo", S_IFIFO);
    defconstant("s-ifchr", S_IFCHR);
    defconstant("s-ifdir", S_IFDIR);
    defconstant("s-ifblk", S_IFBLK);
    defconstant("s-ifreg", S_IFREG);
    printf("\n");

    defconstant("s-iflnk",  S_IFLNK);
    defconstant("s-ifsock", S_IFSOCK);
    printf("\n");

    printf(";;; error numbers\n");
    deferrno("enoent", ENOENT);
    deferrno("eintr", EINTR);
    deferrno("eio", EIO);
    deferrno("eexist", EEXIST);
    deferrno("espipe", ESPIPE);
    deferrno("ewouldblock", EWOULDBLOCK);
    printf("\n");

    printf(";;; for wait3(2) in run-program.lisp\n");
    defconstant("wnohang", WNOHANG);
    defconstant("wuntraced", WUNTRACED);
    printf("\n");

    printf(";;; various ioctl(2) flags\n");
    defconstant("tiocnotty",  TIOCNOTTY);
    defconstant("tiocgwinsz", TIOCGWINSZ);
    defconstant("tiocswinsz", TIOCSWINSZ);
    defconstant("tiocgpgrp",  TIOCGPGRP);
    defconstant("tiocspgrp",  TIOCSPGRP);
    /* KLUDGE: These are referenced by old CMUCL-derived code, but
     * Linux doesn't define them.
     *
     * I think these are the BSD names, but I don't know what the
     * corresponding SysV/Linux names are. As a point of reference,
     * CMUCL doesn't have these defined either (although the defining
     * forms *do* exist in src/code/unix.lisp), so I don't feel nearly
     * so bad about not hunting them down. Insight into renamed
     * obscure ioctl(2) flags appreciated. --njf, 2002-08-26
     *
     * I note that the first one I grepped for, TIOCSIGSEND, is
     * referenced in SBCL conditional on #+HPUX. Maybe the porters of
     * Oxbridge know more about things like that? And even if they
     * don't, one benefit of the Rhodes crusade to heal the worthy
     * ports should be that afterwards, if we grep for something like
     * this in CVS and it's not there, we can lightheartedly nuke it.
     * -- WHN 2002-08-30 */
    /*
      defconstant("tiocsigsend", TIOCSIGSEND);
      defconstant("tiocflush", TIOCFLUSH);
      defconstant("tiocgetp", TIOCGETP);
      defconstant("tiocsetp", TIOCSETP);
      defconstant("tiocgetc", TIOCGETC);
      defconstant("tiocsetc", TIOCSETC);
      defconstant("tiocgltc", TIOCGLTC);
      defconstant("tiocsltc", TIOCSLTC);
    */
    printf("\n");

    printf(";;; signals\n");
    defsignal("sigalrm", SIGALRM);
    defsignal("sigbus", SIGBUS);
    defsignal("sigchld", SIGCHLD);
    defsignal("sigcont", SIGCONT);
#ifdef SIGEMT
    defsignal("sigemt", SIGEMT);
#endif
    defsignal("sigfpe", SIGFPE);
    defsignal("sighup", SIGHUP);
    defsignal("sigill", SIGILL);
    defsignal("sigint", SIGINT);
    defsignal("sigio", SIGIO);
    defsignal("sigiot", SIGIOT);
    defsignal("sigkill", SIGKILL);
    defsignal("sigpipe", SIGPIPE);
    defsignal("sigprof", SIGPROF);
    defsignal("sigquit", SIGQUIT);
    defsignal("sigsegv", SIGSEGV);
#if ((defined LISP_FEATURE_LINUX) && (defined LISP_FEATURE_X86))
    defsignal("sigstkflt", SIGSTKFLT);
#endif
    defsignal("sigstop", SIGSTOP);
#if (!((defined LISP_FEATURE_LINUX) && (defined LISP_FEATURE_X86)))
    defsignal("sigsys", SIGSYS);
#endif
    defsignal("sigterm", SIGTERM);
    defsignal("sigtrap", SIGTRAP);
    defsignal("sigtstp", SIGTSTP);
    defsignal("sigttin", SIGTTIN);
    defsignal("sigttou", SIGTTOU);
    defsignal("sigurg", SIGURG);
    defsignal("sigusr1", SIGUSR1);
    defsignal("sigusr2", SIGUSR2);
    defsignal("sigvtalrm", SIGVTALRM);
#ifdef LISP_FEATURE_SUNOS
    defsignal("sigwaiting", SIGWAITING);
#endif
    defsignal("sigwinch", SIGWINCH);
#ifndef LISP_FEATURE_HPUX
    defsignal("sigxcpu", SIGXCPU);
    defsignal("sigxfsz", SIGXFSZ);
#endif
#endif // _WIN32
    return 0;
}
