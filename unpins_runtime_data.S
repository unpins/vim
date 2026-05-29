/* Embed unpins_runtime.zip in a read-only section. The C side picks up
 * the data through `_binary_unpins_runtime_zip_{start,end}` (same names
 * GNU `ld -r -b binary` would expose), so we can drop the linker recipe
 * entirely and use this single source on every target.
 *
 * Why not `ld -r -b binary`?
 *   - Apple `ld` (used on darwin) treats `-b` as an obsolete flag and
 *     ignores it, so the recipe silently fails on Mach-O hosts.
 *   - The nixpkgs ld-wrapper appends `--gc-sections` for static targets,
 *     which is incompatible with `-r` (relocatable output has no entry
 *     point for gc to root from).
 *   - An .incbin'd assembler source skips the linker for the embed step
 *     entirely; the C compiler assembles it like any other TU.
 *
 * Symbol-prefix convention:
 *   Assemblers don't auto-mangle — the symbol name in the object is
 *   literally whatever the user wrote in the label. The C compiler does
 *   mangle: on Mach-O, C identifier `foo` becomes object symbol `_foo`;
 *   on ELF/PE-x86_64 there is no prefix. So to match a C extern named
 *   `_binary_unpins_runtime_zip_start`, the assembler label must be:
 *     - `_binary_unpins_runtime_zip_start`  on ELF / PE-x86_64
 *     - `__binary_unpins_runtime_zip_start` on Mach-O (extra leading `_`)
 *   The two-branch source below keeps both sides aligned without leaking
 *   the mangling rule into unpins_init.c.
 */

#if defined(__APPLE__)
    .section __TEXT,__const
    .global __binary_unpins_runtime_zip_start
    .global __binary_unpins_runtime_zip_end
__binary_unpins_runtime_zip_start:
    .incbin "unpins_runtime.zip"
__binary_unpins_runtime_zip_end:
#else
# if defined(_WIN32) || defined(__CYGWIN__)
    .section .rdata, "dr"
# else
    /* No explicit `@progbits` type: on 32-bit ARM `@` is the line-comment
     * char, so `, @progbits` is parsed as a comment and the trailing `,`
     * errors out ("junk at end of line"). `.rodata` is a well-known section,
     * so GAS infers PROGBITS from the `"a"` flag on every ELF target. */
    .section .rodata, "a"
# endif
    .global _binary_unpins_runtime_zip_start
    .global _binary_unpins_runtime_zip_end
_binary_unpins_runtime_zip_start:
    .incbin "unpins_runtime.zip"
_binary_unpins_runtime_zip_end:
#endif
