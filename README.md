# vim

Standalone build of [Vim](https://www.vim.org/) (minimal feature set, no GUI).

[![CI](https://github.com/unpins/vim/actions/workflows/vim.yml/badge.svg)](https://github.com/unpins/vim/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Installation

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin vim
```

Or run without installing:

```bash
unpin run vim
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

The [Releases](https://github.com/unpins/vim/releases) page has standalone binaries and a `.tar.zst` data archive (Vim runtime files, man pages, syntax/spell) for manual download.
