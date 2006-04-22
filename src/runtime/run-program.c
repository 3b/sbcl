/*
 * support for the Lisp function RUN-PROGRAM and friends
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

#include "sbcl.h"

#ifndef LISP_FEATURE_WIN32

#include <stdlib.h>
#include <sys/file.h>
#include <sys/types.h>
#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <termios.h>


/* borrowed from detachtty's detachtty.c, in turn borrowed from APUE
 * example code found at
 * http://www.yendor.com/programming/unix/apue/pty/main.c

-brkint

 */

int set_noecho(int fd)
{
    struct termios  stermios;

    if (tcgetattr(fd, &stermios) < 0) return 0;

    stermios.c_lflag &= ~(  ECHO | /* ECHOE |  ECHOK | */  ECHONL);
    stermios.c_oflag |= (ONLCR);
    stermios.c_iflag &= ~(BRKINT);
    stermios.c_iflag |= (ICANON|ICRNL);

    stermios.c_cc[VERASE]=0177;
    if (tcsetattr(fd, TCSANOW, &stermios) < 0) return 0;
    return 1;
}

int spawn(char *program, char *argv[], char *envp[], char *pty_name,
          int stdin, int stdout, int stderr)
{
    int pid = fork();
    int fd;
    sigset_t sset;

    if (pid != 0)
        return pid;

    /* Put us in our own process group. */
#if defined(hpux)
    setsid();
#elif defined(SVR4) || defined(__linux__) || defined(__osf__)
    setpgrp();
#else
    setpgrp(0, getpid());
#endif

    /* unblock signals */
    sigemptyset(&sset);
    sigprocmask(SIG_SETMASK, &sset, NULL);

    /* If we are supposed to be part of some other pty, go for it. */
    if (pty_name) {
#if !defined(hpux) && !defined(SVR4)
        fd = open("/dev/tty", O_RDWR, 0);
        if (fd >= 0) {
            ioctl(fd, TIOCNOTTY, 0);
            close(fd);
        }
#endif
        fd = open(pty_name, O_RDWR, 0);
        dup2(fd, 0);
        set_noecho(0);
        dup2(fd, 1);
        dup2(fd, 2);
        close(fd);
    } else{
    /* Set up stdin, stdout, and stderr */
    if (stdin >= 0)
        dup2(stdin, 0);
    if (stdout >= 0)
        dup2(stdout, 1);
    if (stderr >= 0)
        dup2(stderr, 2);
    }
    /* Close all other fds. */
#ifdef SVR4
    for (fd = sysconf(_SC_OPEN_MAX)-1; fd >= 3; fd--)
        close(fd);
#else
    for (fd = getdtablesize()-1; fd >= 3; fd--)
        close(fd);
#endif

    /* Exec the program. */
    execve(program, argv, envp);

    /* It didn't work, so try /bin/sh. */
    argv[0] = program;
    argv[-1] = "sh";
    execve("/bin/sh", argv-1, envp);

    /* The exec didn't work, flame out. */
    exit(1);
}
#else  /* !LISP_FEATURE_WIN32 */

#  include <windows.h>
#  include <process.h>
#  include <stdio.h>
#  include <stdlib.h>
#  include <fcntl.h>
#  include <io.h>

#define   READ_HANDLE  0
#define   WRITE_HANDLE 1

/* These functions do not attempt to deal with wchar_t variations. */

/* Get the value of _environ maintained by MSVCRT */
char **msvcrt_environ ( void ) {
    return ( _environ );
}

/* Set up in, out, err pipes and spawn a program, waiting or otherwise. */
HANDLE spawn (
    const char *program,
    const char *const *argv,
    int in,
    int out,
    int err,
    int wait
    )
{
    int fdOut, fdIn, fdErr, fdInPipe[2], fdOutPipe[2], fdErrPipe[2], wait_mode;
    HANDLE hProcess;

    /* Make pipes to be passed to the spawned process as in/out/err */
    if ( _pipe ( fdOutPipe, 512, O_TEXT | O_NOINHERIT ) == -1 ) return (HANDLE)-1;
    if ( _pipe ( fdInPipe,  512, O_TEXT | O_NOINHERIT ) == -1 ) return (HANDLE)-1;
    if ( _pipe ( fdErrPipe, 512, O_TEXT | O_NOINHERIT ) == -1 ) return (HANDLE)-1;

    /* Duplicate and save original in/out/err handles */
    fdOut = _dup ( out );
    fdIn  = _dup ( in );
    fdErr = _dup ( err );

    /* Duplicate write end of new pipes to current out/err handles,
     * read to in */
    if ( _dup2 ( fdOutPipe[WRITE_HANDLE], out ) != 0 ) return (HANDLE)-1;
    if ( _dup2 ( fdInPipe[READ_HANDLE],   in  ) != 0 ) return (HANDLE)-1;
    if ( _dup2 ( fdErrPipe[WRITE_HANDLE], err ) != 0 ) return (HANDLE)-1;


    /* Close the duplicated handles to the new pipes */
    close ( fdOutPipe[WRITE_HANDLE] );
    close ( fdInPipe[READ_HANDLE] );
    close ( fdErrPipe[WRITE_HANDLE] );

    /* Set the wait mode. */
    if ( 0 == wait ) {
        wait_mode = P_NOWAIT;
    } else {
        wait_mode = P_WAIT;
    }

    /* Spawn process given on the command line*/
    hProcess = (HANDLE) spawnvp ( wait_mode, program, argv );

    /* Now that the process is launched, replace the original
     * in/out/err handles */
    if ( _dup2 ( fdOut, out ) != 0 ) return (HANDLE)-1;
    if ( _dup2 ( fdIn,  in )  != 0 ) return (HANDLE)-1;
    if ( _dup2 ( fdErr, err ) != 0 ) return (HANDLE)-1;

    /* Close duplicates */
    close(fdOut);
    close(fdIn);
    close(fdErr);

    return ( hProcess );
}


#endif /* !LISP_FEATURE_WIN32 */
