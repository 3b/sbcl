/*
 * wrappers around low-level operations to provide a simpler interface
 * to the operations that Lisp needs
 *
 * The functions in this file are typically called directly from Lisp.
 * Thus, when their signature changes, they don't need updates in a .h
 * file somewhere, but they do need updates in the Lisp code. FIXME:
 * It would be nice to enforce this at compile time. It mighn't even
 * be all that hard: make the cross-compiler versions of DEFINE-ALIEN-FOO
 * macros accumulate strings in a list which then gets written out at
 * the end of sbcl2.h at the end of cross-compilation, then rerun
 * 'make' in src/runtime/ using the new sbcl2.h as sbcl.h (and make
 * sure that all the files in src/runtime/ include sbcl.h). */

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

#include <sys/types.h>
#include <dirent.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <stdio.h>

#include "sbcl.h"
#include "runtime.h"
#include "util.h"

/* Although it might seem as though this should be in some standard
   Unix header, according to Perry E. Metzger, in a message on
   sbcl-devel dated 2004-03-29, this is the POSIXly-correct way of
   using environ: by an explicit declaration.  -- CSR, 2004-03-30 */
extern char **environ;
   
/*
 * stuff needed by CL:DIRECTORY and other Lisp directory operations
 */

/* Unix directory operations think of "." and ".." as filenames, but
 * Lisp directory operations do not. */
int
is_lispy_filename(const char *filename)
{
    return strcmp(filename, ".") && strcmp(filename, "..");
}

/* Return a zero-terminated array of strings holding the Lispy filenames
 * (i.e. excluding the Unix magic "." and "..") in the named directory. */
char**
alloc_directory_lispy_filenames(const char *directory_name)
{
    DIR *dir_ptr = opendir(directory_name);
    char **result = 0;

    if (dir_ptr) { /* if opendir success */

	struct voidacc va;

	if (0 == voidacc_ctor(&va)) { /* if voidacc_ctor success */
	    struct dirent *dirent_ptr;

	    while ( (dirent_ptr = readdir(dir_ptr)) ) { /* until end of data */
		char* original_name = dirent_ptr->d_name;
		if (is_lispy_filename(original_name)) {
		    /* strdup(3) is in Linux and *BSD. If you port
		     * somewhere else that doesn't have it, it's easy
		     * to reimplement. */
		    char* dup_name = strdup(original_name);
		    if (!dup_name) { /* if strdup failure */
			goto dtors;
		    }
		    if (voidacc_acc(&va, dup_name)) { /* if acc failure */
			goto dtors; 
		    }
		}
	    }
	    result = (char**)voidacc_give_away_result(&va);
	}

    dtors:
	voidacc_dtor(&va);
	/* ignoring closedir(3) return code, since what could we do?
	 *
	 * "Never ask questions you don't want to know the answer to."
	 * -- William Irving Zumwalt (Rich Cook, _The Wizardry Quested_) */
	closedir(dir_ptr);
    }

    return result;
}

/* Free a result returned by alloc_directory_lispy_filenames(). */
void
free_directory_lispy_filenames(char** directory_lispy_filenames)
{
    char** p;

    /* Free the strings. */
    for (p = directory_lispy_filenames; *p; ++p) {
	free(*p);
    }

    /* Free the table of strings. */
    free(directory_lispy_filenames);
}

/*
 * readlink(2) stuff
 */

/* a wrapped version of readlink(2):
 *   -- If path isn't a symlink, or is a broken symlink, return 0.
 *   -- If path is a symlink, return a newly allocated string holding
 *      the thing it's linked to. */
char *
wrapped_readlink(char *path)
{
    int bufsiz = strlen(path) + 16;
    while (1) {
	char *result = malloc(bufsiz);
	int n_read = readlink(path, result, bufsiz);
	if (n_read < 0) {
	    free(result);
	    return 0;
	} else if (n_read < bufsiz) {
	    result[n_read] = 0;
	    return result;
	} else {
	    free(result);
	    bufsiz *= 2;
	}
    }
}

/*
 * stat(2) stuff
 */

/* As of 0.6.12, the FFI can't handle 64-bit values. For now, we use
 * these munged-to-32-bits values for might-be-64-bit slots of
 * stat_wrapper as a workaround, so that at least we can still work
 * when values are small.
 *
 * FIXME: But of course we should fix the FFI so that we can use the
 * actual 64-bit values instead.  In fact, we probably have by now
 * (2003-10-03) on all working platforms except MIPS and HPPA; if some
 * motivated spark would simply fix those, this hack could go away.
 * -- CSR, 2003-10-03 */
typedef int ffi_dev_t; /* since Linux dev_t can be 64 bits */
typedef u32 ffi_off_t; /* since OpenBSD 2.8 st_size is 64 bits */

/* a representation of stat(2) results which doesn't depend on CPU or OS */
struct stat_wrapper {
    /* KLUDGE: The verbose wrapped_st_ prefixes are to protect us from
     * the C preprocessor as wielded by the fiends of OpenBSD, who do
     * things like
     *    #define st_atime        st_atimespec.tv_sec
     * I remember when I was young and innocent, I read about how the
     * C preprocessor isn't to be used to globally munge random
     * lowercase symbols like this, because things like this could
     * happen, and I nodded sagely. But now I know better. :-| This is
     * another entry for Dan Barlow's ongoing episodic rant about C
     * header files, I guess.. -- WHN 2001-05-10 */
    ffi_dev_t     wrapped_st_dev;         /* device */
    ino_t         wrapped_st_ino;         /* inode */
    mode_t        wrapped_st_mode;        /* protection */
    nlink_t       wrapped_st_nlink;       /* number of hard links */
    uid_t         wrapped_st_uid;         /* user ID of owner */
    gid_t         wrapped_st_gid;         /* group ID of owner */
    ffi_dev_t     wrapped_st_rdev;        /* device type (if inode device) */
    ffi_off_t     wrapped_st_size;        /* total size, in bytes */
    unsigned long wrapped_st_blksize;     /* blocksize for filesystem I/O */
    unsigned long wrapped_st_blocks;      /* number of blocks allocated */
    time_t        wrapped_st_atime;       /* time_t of last access */
    time_t        wrapped_st_mtime;       /* time_t of last modification */
    time_t        wrapped_st_ctime;       /* time_t of last change */
};

static void 
copy_to_stat_wrapper(struct stat_wrapper *to, struct stat *from)
{
#define FROB(stem) to->wrapped_st_##stem = from->st_##stem
    FROB(dev);
    FROB(ino);
    FROB(mode);
    FROB(nlink);
    FROB(uid);
    FROB(gid);
    FROB(rdev);
    FROB(size);
    FROB(blksize);
    FROB(blocks);
    FROB(atime);
    FROB(mtime);
    FROB(ctime);
#undef FROB
}

int
stat_wrapper(const char *file_name, struct stat_wrapper *buf)
{
    struct stat real_buf;
    int ret;
    fprintf(stderr, "in stat_wrapper, buf=%#lx\n", buf);
    if ((ret = stat(file_name,&real_buf)) >= 0)
	copy_to_stat_wrapper(buf, &real_buf); 
    fprintf(stderr, "examined %s, ret=%d\n", file_name, ret);
    return ret;
}

int
lstat_wrapper(const char *file_name, struct stat_wrapper *buf)
{
    struct stat real_buf;
    int ret;
    fprintf(stderr, "in lstat_wrapper");
    if ((ret = lstat(file_name,&real_buf)) >= 0) 
	copy_to_stat_wrapper(buf, &real_buf); 
    return ret;
}

int
fstat_wrapper(int filedes, struct stat_wrapper *buf)
{
    struct stat real_buf;
    int ret;
    fprintf(stderr, "in fstat_wrapper");
    if ((ret = fstat(filedes,&real_buf)) >= 0)
	copy_to_stat_wrapper(buf, &real_buf); 
    return ret;
}

/*
 * getpwuid() stuff
 */

/* Return a newly-allocated string holding the username for "uid", or
 * NULL if there's no such user.
 *
 * KLUDGE: We also return NULL if malloc() runs out of memory
 * (returning strdup() result) since it's not clear how to handle that
 * error better. -- WHN 2001-12-28 */
char *
uid_username(int uid)
{
    struct passwd *p = getpwuid(uid);
    if (p) {
	/* The object *p is a static struct which'll be overwritten by
	 * the next call to getpwuid(), so it'd be unsafe to return
	 * p->pw_name without copying. */
	return strdup(p->pw_name);
    } else {
	return 0;
    }
}

char *
uid_homedir(uid_t uid)
{
    struct passwd *p = getpwuid(uid);
    if(p) {
	/* Let's be careful about this, shall we? */
	size_t len = strlen(p->pw_dir);
	if (p->pw_dir[len-1] == '/') {
	    return strdup(p->pw_dir);
	} else {
	    char *result = malloc(len + 2);
	    if (result) {
		int nchars = sprintf(result,"%s/",p->pw_dir);
		if (nchars == len + 1) {
		    return result;
		} else {
		    return 0;
		}
	    } else {
		return 0;
	    }
	}
    } else {
	return 0;
    }
}

/*
 * functions to get miscellaneous C-level variables
 *
 * (Doing this by calling functions lets us borrow the smarts of the C
 * linker, so that things don't blow up when libc versions and thus
 * variable locations change between compile time and run time.)
 */

char **
wrapped_environ()
{
    return environ;
}
