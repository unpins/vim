# vim

[Vim](https://www.vim.org/) — terminal only, no GUI. A single self-contained binary, built natively for Linux, macOS, and Windows: the whole runtime tree (`share/vim/vim92` — syntax, ftplugin, indent, doc, …) is baked in, so there's nothing to install alongside it.

[![CI](https://github.com/unpins/vim/actions/workflows/vim.yml/badge.svg)](https://github.com/unpins/vim/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install vim`.

## Usage

Run the `vim` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin vim file.txt
```

To install it onto your PATH:

```bash
unpin install vim
```

## Man pages

`vim.1` (and `vimdiff`, `ex`, `view`, `rvim`, `rview`, `evim`, `vimtutor`) are embedded in the binary — read one with `unpin man vim`, e.g. `unpin man vim vimdiff`.

## Build locally

```bash
nix build github:unpins/vim
./result/bin/vim
```

Or run directly:

```bash
nix run github:unpins/vim
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/vim/releases) page has standalone binaries for manual download.

## Build notes

- **Runtime tree embedded.** Vim's runtime directory (`share/vim/vim92`) used to ship as a companion `.tar.zst`. It is now packed to a deflate ZIP at build time and linked into the binary as an ELF/PE/Mach-O section; the shared [unpin-vfs](https://github.com/unpins/unpin-vfs) core intercepts Vim's file calls under a private marker and serves the runtime from memory. No companion file, no extract-on-first-run. `$VIMRUNTIME` resolves to a virtual path inside the binary.
- **`xxd` is built in.** The hex-dump tool ships inside the same binary; installing Vim creates both the `vim` and `xxd` commands.
- **Feature set differs by platform.** Linux and macOS are the **Huge** feature set (everything except the GUI); the Windows build is **Normal**. No GUI on any platform.
- **How the runtime is routed into the VFS** differs by OS, all behind the one core: Linux uses `ld --wrap` on the libc file calls; macOS rewrites Vim's own `open`/`stat`/… references to the VFS shims with `llvm-objcopy --redefine-sym` (no `ld --wrap` on Mach-O); Windows is an `mingw` cross build where `mch_open`/`mch_fopen`/`vim_stat` are real functions (they wrap `_wopen`/`_wfopen`/`_wstat` for wide-char paths), so the VFS gets a virtual-path fast path patched into them.
