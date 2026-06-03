# vim

Standalone build of [Vim](https://www.vim.org/) — terminal only, no GUI. The whole runtime tree (`share/vim/vim92` — syntax, ftplugin, indent, doc, …) is baked into the binary, so it's a single file with nothing to install alongside it.

[![CI](https://github.com/unpins/vim/actions/workflows/vim.yml/badge.svg)](https://github.com/unpins/vim/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run the `vim` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin vim file.txt
```

To install it onto your PATH:

```bash
unpin install vim
```

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

## Man pages

`vim.1` (and `vimdiff`, `ex`, `view`, `rvim`, `rview`, `evim`, `vimtutor`) are embedded in the binary — read one with `unpin man vim`, e.g. `unpin man vim vimdiff`.

## Build notes

- **Runtime tree embedded.** Vim's runtime directory (`share/vim/vim92`) used to ship as a companion `.tar.zst`. It is now packed to a deflate ZIP at build time and linked into the binary as an ELF/PE section; a small in-binary VFS (~410 LOC of C + miniz) intercepts Vim's file calls under a private marker and serves the runtime from memory. No companion file, no extract-on-first-run. `$VIMRUNTIME` resolves to a virtual path inside the binary.
- **Feature set differs by platform.** Linux and macOS are the **Huge** feature set (everything except the GUI); the Windows build is **Normal**. No GUI on any platform.
- **Windows** is an `mingw` cross build. `mch_open`/`mch_fopen` are real functions there (they wrap `_wfopen`/`_wopen` for wide-char paths), so the VFS dispatches by patching those function bodies rather than via the macro redirect used on Unix.
