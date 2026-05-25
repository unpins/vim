/* In-memory VFS for vim runtime.
 *
 * Backed by a ZIP archive (deflate) loaded once into memory. Every entry stays
 * compressed in the source buffer; unpins_vfs_fopen() inflates a single entry into a
 * fresh malloc'd buffer and wraps it with fopencookie() so plain fclose()
 * cleans up the backing buffer via the cookie close hook. This means vim can
 * call fclose() on a VFS-backed FILE* without leaking — no special-case API.
 *
 * Paths under VFS_PREFIX are served from the ZIP; everything else falls
 * through to the real filesystem so user files (swap, viminfo, edited
 * buffers) keep working unchanged.
 */

#ifndef UNPINS_VFS_H
#define UNPINS_VFS_H

#include <dirent.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>

/* `unpins_stat_t` shadows whatever vim picked for `stat_T`. On Windows
 * the mingw build uses `struct _stat64`; everywhere else it's plain
 * `struct stat`. Matching the layout means our redirects can pass a
 * stat_T* through unchanged, with no per-call shimming. */
#ifdef _WIN32
typedef struct _stat64 unpins_stat_t;
#else
typedef struct stat unpins_stat_t;
#endif

#define VFS_PREFIX "/__unpins_vimruntime__"

/* Initialize from a ZIP blob already in memory (e.g. an embedded ELF
 * section). The pointer must remain valid for the lifetime of the
 * process; vfs holds it by reference. Returns 0 on success. */
int unpins_vfs_init(const void *zip_data, size_t zip_size);

/* Path test. Returns 1 if path begins with VFS_PREFIX (with or without
 * a trailing slash; "/__unpins_vimruntime__" alone is the root). */
int unpins_vfs_is_virtual(const char *path);

/* fopen replacement. For virtual paths returns a fopencookie FILE*
 * over a freshly inflated copy of the entry; the cookie owns the
 * buffer and frees it on close, so plain fclose() works.
 *
 * For non-virtual paths, falls through to fopen(). Mode is honored
 * literally on the fallback path; on the virtual path only read modes
 * (r/rb) are supported and write modes return NULL with EROFS. */
FILE *unpins_vfs_fopen(const char *path, const char *mode);

/* open() replacement. Returns a real fd for non-virtual paths. For
 * virtual paths, allocates a memfd-backed fd (memfd_create) with the
 * inflated entry contents, so the caller gets a regular fd that
 * supports read/lseek/close like any other. Returns -1 on error. */
int unpins_vfs_open(const char *path, int flags, ...);

/* opendir replacement. Virtual paths return a synthetic DIR* iterating
 * entries directly under that prefix. Non-virtual paths fall through to
 * opendir(). unpins_vfs_closedir handles both. */
DIR *unpins_vfs_opendir(const char *path);
struct dirent *unpins_vfs_readdir(DIR *d);
int unpins_vfs_closedir(DIR *d);

/* stat / lstat. Virtual paths synthesize struct stat from the ZIP
 * central directory entry; symlinks aren't represented in the ZIP, so
 * unpins_vfs_lstat is identical to unpins_vfs_stat for virtual paths. */
int unpins_vfs_stat(const char *path, unpins_stat_t *st);
int unpins_vfs_lstat(const char *path, unpins_stat_t *st);

#endif
