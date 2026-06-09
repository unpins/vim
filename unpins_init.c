/* Vim startup glue for the unpin-vfs runtime.
 *
 * Called once from main() right after mch_early_init(). The runtime tree is a
 * ZIP blob embedded as a section (unpins_runtime_data.S); the unpin-vfs core
 * (vfs.c, linked via `ld --wrap`) serves every libc open/stat/opendir/... whose
 * path falls under the mount root. All this glue does is pin $VIMRUNTIME/$VIM at
 * that root so vim's runtime discovery produces paths the wrappers intercept.
 *
 * The mount root must match -DUNPIN_VFS_ROOT passed to vfs.c (see flake.nix).
 * The runtime ZIP holds the vim92/ tree CONTENTS directly (no version prefix),
 * so $VIMRUNTIME is exactly the marker -- same value the previous bespoke VFS
 * used, keeping vim-level behaviour unchanged.
 *
 * Idempotent: multiple calls no-op after the first success.
 */

#include "vfs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Bare mount point (no trailing slash); UNPIN_VFS_ROOT is this + "/". */
#define VFS_PREFIX "/__unpins_vimruntime__"

/* xxd is folded into this binary as a multicall applet: its main() is compiled
 * to xxd_main (-Dmain=xxd_main, see patches/Makefile_append) and linked into
 * vim's OBJ. unpins_xxd_dispatch() runs as the very first thing in vim's main()
 * (before mch_early_init()): when argv[0]'s basename is "xxd" it hands off and
 * exits with xxd's status; otherwise it returns and vim starts normally. xxd
 * touches only real paths, so vim's VFS interception falls through (is_virtual()
 * is a pure prefix/marker test and is safe to reach before unpin_vfs_init()).
 * The applet ships as an unpin alias (flake.nix withAliases): unpin execs this
 * binary with argv[0]="xxd" (or "xxd.exe" on Windows). */
extern int xxd_main(int argc, char **argv);

void unpins_xxd_dispatch(int argc, char **argv)
{
    if (argc < 1 || argv[0] == NULL) return;

    const char *base = argv[0], *p;
    for (p = argv[0]; *p; p++)
        if (*p == '/' || *p == '\\') base = p + 1;

    /* On Windows the alias is invoked as "xxd.exe"; ignore a trailing ".exe"
     * (case-insensitive) so the stem still matches. No-op elsewhere. */
    size_t n = strlen(base);
    if (n > 4) {
        const char *e = base + n - 4;
        if (e[0] == '.' && (e[1] == 'e' || e[1] == 'E')
                        && (e[2] == 'x' || e[2] == 'X')
                        && (e[3] == 'e' || e[3] == 'E'))
            n -= 4;
    }

    if (n == 3 && strncmp(base, "xxd", 3) == 0)
        exit(xxd_main(argc, argv));
}

void unpins_init(void)
{
    static int done;
    if (done) return;

    const char *dbg = getenv("UNPINS_DEBUG");
    if (dbg) fprintf(stderr, "[unpins] unpins_init called\n");

    /* Fail fast (and visibly under UNPINS_DEBUG) if the embedded blob is
     * unusable; the wrappers would otherwise just lazily ENOENT later. */
    if (!unpin_vfs_init()) {
        if (dbg) fprintf(stderr, "[unpins] unpin_vfs_init failed\n");
        return;
    }
    if (dbg) fprintf(stderr, "[unpins] VFS ready, VIMRUNTIME=%s\n", VFS_PREFIX);

#ifdef _WIN32
    _putenv("VIMRUNTIME=" VFS_PREFIX);
    _putenv("VIM=" VFS_PREFIX "/..");
#else
    setenv("VIMRUNTIME", VFS_PREFIX, 1);
    setenv("VIM", VFS_PREFIX "/..", 1);
#endif

    done = 1;
}
