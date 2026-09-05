# vim

[Vim](https://www.vim.org/) — a highly configurable terminal text editor. A single self-contained binary, built natively for Linux, macOS, and Windows.

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

`vim.1` is embedded in the binary — read it with `unpin man vim`. So are the
pages for `xxd` and for Vim's other modes (`vimdiff`, `ex`, `view`, `rvim`,
`rview`, `evim`), which you reach with a flag: `unpin man vim vimdiff`.

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

- **Runtime tree embedded.** Vim's runtime files (syntax, ftplugin, indent, help, …) are packed into a ZIP and embedded in the binary; the shared [unpin-vfs](https://github.com/unpins/unpin-vfs) core serves them from memory at runtime. There's no companion `share/vim` directory and nothing to extract on first run — `$VIMRUNTIME` points inside the binary.
- **`xxd` included.** The `xxd` hex dumper ships in the same binary; installing Vim creates both the `vim` and `xxd` commands.
- **Feature set.** Linux and macOS ship the **Huge** feature set; Windows ships **Normal**. The scripting interpreters (Lua, Python, Ruby, Perl, Tcl) are not compiled in either way — they would tie the binary to whatever versions the machine happens to have. This is the terminal build; the graphical build is the separate [gvim](https://github.com/unpins/gvim) package.
