/* Embed unpins_runtime.zip in a read-only section, exposing start/end labels
 * that the unpin-vfs core (vfs.c) picks up as `extern` arrays. vfs.c selects
 * the symbol-name convention by OS:
 *     - ELF (Linux)  : `_binary_unpins_runtime_zip_{start,end}` (the same names
 *                      GNU `ld -r -b binary` would expose)
 *     - Mach-O/PE    : the BARE `unpins_runtime_zip_{start,end}`
 * so this source must emit matching labels per target.
 *
 * Why not `ld -r -b binary`?
 *   - Apple `ld` (used on darwin) treats `-b` as an obsolete flag and ignores
 *     it, so the recipe silently fails on Mach-O hosts.
 *   - The nixpkgs ld-wrapper appends `--gc-sections` for static targets, which
 *     is incompatible with `-r` (relocatable output has no entry point for gc
 *     to root from).
 *   - An .incbin'd assembler source skips the linker for the embed step
 *     entirely; the C compiler assembles it like any other TU.
 *
 * Symbol-prefix convention:
 *   Assemblers don't auto-mangle — the symbol in the object is literally the
 *   label written here. The C compiler DOES mangle: on Mach-O a C identifier
 *   `foo` becomes object symbol `_foo`; on ELF and PE-x86_64 there is no
 *   prefix. So to match vfs.c's externs:
 *     - ELF   : C `_binary_unpins_runtime_zip_start` -> label `_binary_…`
 *     - Mach-O: C `unpins_runtime_zip_start`         -> label `_unpins_…`
 *     - PE    : C `unpins_runtime_zip_start`         -> label `unpins_…`
 *   This three-branch source keeps every side aligned without leaking the
 *   mangling rule into unpins_init.c. The name stem must match the flake's
 *   -DUNPIN_VFS_BLOB_SYM=unpins_runtime_zip.
 */

#if defined(__APPLE__)
    .section __TEXT,__const
    .global _unpins_runtime_zip_start
    .global _unpins_runtime_zip_end
_unpins_runtime_zip_start:
    .incbin "unpins_runtime.zip"
_unpins_runtime_zip_end:
#elif defined(_WIN32) || defined(__CYGWIN__)
    .section .rdata, "dr"
    .global unpins_runtime_zip_start
    .global unpins_runtime_zip_end
unpins_runtime_zip_start:
    .incbin "unpins_runtime.zip"
unpins_runtime_zip_end:
#else
    /* No explicit `@progbits` type: on 32-bit ARM `@` is the line-comment
     * char, so `, @progbits` is parsed as a comment and the trailing `,`
     * errors out ("junk at end of line"). `.rodata` is a well-known section,
     * so GAS infers PROGBITS from the `"a"` flag on every ELF target. */
    .section .rodata, "a"
    .global _binary_unpins_runtime_zip_start
    .global _binary_unpins_runtime_zip_end
_binary_unpins_runtime_zip_start:
    .incbin "unpins_runtime.zip"
_binary_unpins_runtime_zip_end:
#endif
