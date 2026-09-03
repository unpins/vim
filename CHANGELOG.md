# Changelog

## [Unreleased]

### Changed

- The Linux and macOS binaries are now built by the unpin-llvm engine (clang
  with full LTO) instead of nixpkgs' gcc. Windows is unaffected — it has always
  been its own separate build.

- One mechanism now connects Vim's file reads to the runtime tree embedded in
  the binary, on every platform. There used to be two, one for Linux and one for
  macOS, and neither survives the move to the new compiler; both were replaced
  by the shared one that does.

  Nothing about the editor changes. On every Linux target the embedded runtime
  reads back exactly as before — `filetype.vim` is still 1675 lines, `syntax/`
  still holds 770 files, `:syntax on` still loads, `xxd` still runs — and the
  Windows binary answers the same on every check it did before.

  The x86_64 binary grew from 15.5 MB to 16.6 MB. That is the new compiler's
  code generation, not a lost optimisation: putting back the dead-code trimming
  the gcc build used recovers 45 KB of the 1.1 MB.
