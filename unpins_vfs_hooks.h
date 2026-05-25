/* Macro hooks injected at the end of vim.h. Routes vim's file I/O
 * through the unpins runtime VFS. Only included into vim's translation
 * units, NEVER from unpins_vfs.c itself (which needs the real libc).
 *
 * Strategy:
 *   - mch_* macros redefined to call the VFS wrappers. Most vim runtime
 *     reads already go through mch_fopen / mch_open / mch_stat, so this
 *     captures ~70% of the surface with zero call-site edits.
 *   - opendir / readdir / closedir hijacked at the libc symbol level
 *     via #define. Vim uses opendir directly (no mch_opendir abstraction),
 *     so this is the only way to redirect runtime path globs without
 *     editing every call site.
 *   - Raw fopen/open/stat bypass sites (~80 sites in vim) are left as
 *     libc by default. The VFS wrappers fall through to libc for any
 *     non-virtual path, so even if vim hits a bypass site for a real
 *     user file, behavior is unchanged. If a bypass site DOES touch
 *     runtime, the smoke test will catch it and we expand the override.
 */

#ifndef UNPINS_VFS_HOOKS_H
#define UNPINS_VFS_HOOKS_H

#include "unpins_vfs.h"

/* mch_* redirects */
#undef mch_stat
#undef mch_lstat
#define mch_stat(n, p)     unpins_vfs_stat((n), (p))
#define mch_lstat(n, p)    unpins_vfs_lstat((n), (p))

#ifndef _WIN32
/* On Windows mch_open / mch_fopen are real function DEFINITIONS in
 * os_win32.c (wide-char wrappers around _wopen / _wfopen). A function-
 * like macro on the same name breaks the syntax of those definitions,
 * so we don't redirect them via macro. Instead we patch the Windows
 * function bodies in postPatch to dispatch virtual paths to the VFS at
 * entry. */
#undef mch_open
#undef mch_fopen
#define mch_open(n, m, p)  unpins_vfs_open((n), (m), (p))
#define mch_fopen(n, p)    unpins_vfs_fopen((n), (p))
#endif

/* Raw libc redirects — vim has ~80 bypass sites that call open/fopen/
 * stat/lstat directly instead of through mch_*. Strace showed e.g.
 * mch_isdir calls stat() raw, breaking runtime path probing. Redirecting
 * at this layer is transparent: unpins_vfs_* falls through to libc for
 * any non-virtual path. */
#undef stat
#undef lstat
#undef open
#undef fopen
#define stat(p, s)  unpins_vfs_stat((p), (s))
#define lstat(p, s) unpins_vfs_lstat((p), (s))
#define open        unpins_vfs_open    /* variadic — let preprocessor pass through */
#define fopen(p, m) unpins_vfs_fopen((p), (m))

/* Directory iteration hooks. vim has no mch_opendir abstraction. */
#undef opendir
#undef readdir
#undef closedir
#define opendir(p)   unpins_vfs_opendir(p)
#define readdir(d)   unpins_vfs_readdir(d)
#define closedir(d)  unpins_vfs_closedir(d)

/* Startup hook — called from main.c right after mch_early_init(). */
void unpins_init(void);

#endif
