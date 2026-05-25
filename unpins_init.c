/* Vim startup glue for the unpins runtime VFS.
 *
 * Called once from main() right after mch_early_init(). The runtime ZIP
 * is embedded into the binary as an ELF section via `ld -r -b binary`
 * applied to unpins_runtime.zip; the linker exports start/end symbols
 * that we treat as a plain byte range.
 *
 * Idempotent — multiple calls no-op after the first success.
 */

#include "unpins_vfs.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

/* Defined by `ld -r -b binary -o … unpins_runtime.zip`. The symbols name
 * the source file with non-alphanum chars folded to underscores. */
extern const char _binary_unpins_runtime_zip_start[];
extern const char _binary_unpins_runtime_zip_end[];

static int g_initialized = 0;

void unpins_init(void)
{
    if (g_initialized) return;

    const char *dbg = getenv("UNPINS_DEBUG");
    if (dbg) fprintf(stderr, "[unpins] unpins_init called\n");

    size_t size = (size_t)(_binary_unpins_runtime_zip_end
                           - _binary_unpins_runtime_zip_start);
    if (dbg) fprintf(stderr, "[unpins] embedded runtime is %zu bytes\n", size);

    if (unpins_vfs_init(_binary_unpins_runtime_zip_start, size) != 0) {
        if (dbg) fprintf(stderr, "[unpins] unpins_vfs_init failed\n");
        return;
    }
    if (dbg) fprintf(stderr, "[unpins] VFS ready, setting VIMRUNTIME=%s\n", VFS_PREFIX);

    /* Pin $VIMRUNTIME at the virtual prefix so all of vim's runtime
     * discovery hits paths under the prefix; the macro redirects route
     * those reads into the VFS. */
#ifdef _WIN32
    _putenv("VIMRUNTIME=" VFS_PREFIX);
    _putenv("VIM=" VFS_PREFIX "/..");
#else
    setenv("VIMRUNTIME", VFS_PREFIX, 1);
    setenv("VIM", VFS_PREFIX "/..", 1);
#endif

    g_initialized = 1;
}
