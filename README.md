# vim

Standalone build of [Vim](https://www.vim.org/) (minimal feature set, no GUI). Runs on any Linux, macOS or Windows without external dependencies.

## Installation

You can install this package instantly using the [unpin](https://github.com/unpins/unpin) package manager:

```bash
unpin vim
```

Or run it without installing:

```bash
unpin run vim
```

## Build locally

```bash
nix build github:unpins/vim
./result/bin/vim
```

Or, in one shot:

```bash
nix run github:unpins/vim
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual Download

Standalone binaries and data packages are available on the [Releases](https://github.com/unpins/vim/releases) page.
