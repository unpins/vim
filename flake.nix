{
  description = "Standalone build of Vim (single-binary, runtime tree embedded)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Vim's runtime tree (share/vim/vim92 — syntax, ftplugin, doc, …) used to
  # ship as a companion `.tar.zst` next to the binary. Since 2026-05-25 the
  # tree is packed to a deflate ZIP at build time and linked into the binary
  # as an ELF/PE section via `ld -r -b binary`. A tiny VFS layer (~410 LOC
  # of C + miniz) intercepts vim's libc file calls for paths under a unique
  # marker and serves them from the in-memory ZIP. Result: single static
  # binary, no companion file, no extract-on-first-run.
  outputs = { self, unpins-lib }:
    let
      injectVfs = pkgs: oldDrv: oldDrv.overrideAttrs (old:
        let
          # vim major version → runtime dir name (vim92/vim93/…). Read out of
          # the upstream tree so we don't track it manually.
          runtimeZip = pkgs.runCommand "vim-runtime.zip" {
            nativeBuildInputs = [ pkgs.buildPackages.zip ];
          } ''
            cd ${oldDrv}/share/vim
            rt=$(ls -d vim* | head -1)
            zip -9 -r -q $out "$rt"
            if [ ! -f $out ] && [ -f $out.zip ]; then mv $out.zip $out; fi
          '';
        in
        {
          postPatch = (old.postPatch or "") + ''
            echo "==> inject unpins VFS sources"
            cp ${./unpins_vfs.h}            src/unpins_vfs.h
            cp ${./unpins_vfs_hooks.h}      src/unpins_vfs_hooks.h
            cp ${./unpins_vfs.c}            src/unpins_vfs.c
            cp ${./unpins_init.c}           src/unpins_init.c
            cp ${./unpins_runtime_data.S}   src/unpins_runtime_data.S
            cp ${./miniz.h}                 src/miniz.h
            cp ${./miniz.c}                 src/miniz.c

            echo "==> stage runtime ZIP at src/unpins_runtime.zip for .incbin"
            cp ${runtimeZip} src/unpins_runtime.zip
            chmod 0644 src/unpins_runtime.zip

            echo "==> insert hooks include INSIDE vim.h's VIM__H guard"
            # Critical: hook MUST be inside the guard. Outside, xdiff.h's
            # recursive `#include "vim.h"` re-processes our hook but skips
            # the guarded body; then on return to the first pass, vim.h's
            # own `# define mch_open` rewinds our macros to libc.
            sed -i 's|^#endif // VIM__H|#include "unpins_vfs_hooks.h"\n#endif // VIM__H|' src/vim.h

            echo "==> inject unpins_init() right after mch_early_init() in main.c"
            sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c

            echo "==> add OBJ entries + compile rules to autotools Makefile"
            sed -i 's|$(XDIFF_OBJS_USED)|$(XDIFF_OBJS_USED) \\\n\tobjects/unpins_vfs.o \\\n\tobjects/unpins_init.o \\\n\tobjects/unpins_runtime_data.o \\\n\tobjects/miniz.o|' src/Makefile
            cat ${./patches/Makefile_append} >> src/Makefile
          '';

          # The runtime tree is now embedded — drop the on-disk copy so the
          # install is truly single-file.
          postInstall = (old.postInstall or "") + ''
            echo "==> prune embedded-into-binary runtime tree from \$out"
            rm -rf $out/share/vim/vim*
            rm -f  $out/share/vim/vimrc
            rmdir  $out/share/vim 2>/dev/null || true
          '';
        });
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "vim";

      # Native (Linux + Darwin) — start from pkgsStatic.vim (already cached
      # on the binary cache) and layer VFS on top.
      build = pkgs: injectVfs pkgs pkgs.pkgsStatic.vim;

      # Windows — Make_ming.mak cross build, same VFS sources, same ELF/PE
      # symbol shape. mch_fopen/mch_open are real functions in os_win32.c
      # on Windows (they wrap _wfopen/_wopen for wide-char paths), so we
      # don't redirect them via macro and instead patch the function bodies
      # to dispatch virtual paths at entry.
      windowsBuild = pkgs:
        let
          cross = pkgs.pkgsCross.mingwW64;
          prefix = cross.stdenv.hostPlatform.config;

          runtimeZip = pkgs.runCommand "vim-runtime.zip" {
            nativeBuildInputs = [ pkgs.buildPackages.zip ];
          } ''
            cd ${pkgs.vim}/share/vim
            rt=$(ls -d vim* | head -1)
            zip -9 -r -q $out "$rt"
            if [ ! -f $out ] && [ -f $out.zip ]; then mv $out.zip $out; fi
          '';
        in
        cross.stdenv.mkDerivation {
          pname = "vim";
          inherit (pkgs.vim) version src;

          dontConfigure = true;
          buildInputs = [ cross.windows.pthreads ];
          strictDeps = true;
          enableParallelBuilding = true;

          postPatch = ''
            echo "==> inject unpins VFS sources"
            cp ${./unpins_vfs.h}            src/unpins_vfs.h
            cp ${./unpins_vfs_hooks.h}      src/unpins_vfs_hooks.h
            cp ${./unpins_vfs.c}            src/unpins_vfs.c
            cp ${./unpins_init.c}           src/unpins_init.c
            cp ${./unpins_runtime_data.S}   src/unpins_runtime_data.S
            cp ${./miniz.h}                 src/miniz.h
            cp ${./miniz.c}                 src/miniz.c

            echo "==> stage runtime ZIP at src/unpins_runtime.zip for .incbin"
            cp ${runtimeZip} src/unpins_runtime.zip
            chmod 0644 src/unpins_runtime.zip

            echo "==> insert hooks include inside VIM__H guard"
            sed -i 's|^#endif // VIM__H|#include "unpins_vfs_hooks.h"\n#endif // VIM__H|' src/vim.h

            echo "==> inject unpins_init() right after mch_early_init() in main.c"
            sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c

            echo "==> patch os_win32.c mch_open/mch_fopen to dispatch virtual paths"
            awk '
            /^mch_open\(const char \*name, int flags, int mode\)$/ {
                print; getline; print;
                print "    if (unpins_vfs_is_virtual(name))";
                print "\treturn unpins_vfs_open(name, flags, mode);";
                next;
            }
            /^mch_fopen\(const char \*name, const char \*mode\)$/ {
                print; getline; print;
                print "    if (unpins_vfs_is_virtual(name))";
                print "\treturn unpins_vfs_fopen(name, mode);";
                next;
            }
            { print }' src/os_win32.c > src/os_win32.c.new
            mv src/os_win32.c.new src/os_win32.c

            echo "==> add OBJ entries to Make_cyg_ming.mak"
            cat ${./patches/Make_cyg_ming_append} >> src/Make_cyg_ming.mak
          '';

          buildPhase = ''
            runHook preBuild

            # Pre-build our objects into OUTDIR (objx86-64 for ARCH=x86-64).
            # Make_ming.mak's pattern rule doesn't carry the miniz defines,
            # so the explicit compile here is the simplest reliable hook.
            mkdir -p src/objx86-64
            MINIZ_DEFS='-DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES'
            CFLAGS_BASE='-I. -O2 -march=x86-64 -DWIN32 -DWINVER=0x0601 -D_WIN32_WINNT=0x0601'
            ( cd src && \
              ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -o objx86-64/unpins_vfs.o            unpins_vfs.c          && \
              ${prefix}-gcc -c $CFLAGS_BASE             -o objx86-64/unpins_init.o           unpins_init.c         && \
              ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -w -o objx86-64/miniz.o              miniz.c               && \
              ${prefix}-gcc -c $CFLAGS_BASE             -o objx86-64/unpins_runtime_data.o   unpins_runtime_data.S )

            make -C src -f Make_ming.mak \
              FEATURES=NORMAL \
              GUI=no \
              CROSS=yes \
              CROSS_COMPILE=${prefix}- \
              STATIC_STDCPLUS=yes \
              STATIC_WINPTHREAD=yes \
              WINDRES=${prefix}-windres \
              ARCH=x86-64 \
              -j$NIX_BUILD_CORES \
              vim.exe xxd/xxd.exe

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp src/vim.exe $out/bin/vim.exe
            cp src/xxd/xxd.exe $out/bin/xxd.exe
            # Runtime tree is embedded — no share/vim/vim92 to ship.
            runHook postInstall
          '';

          passthru = { pname = "vim"; inherit (pkgs.vim) version; };
        };
    };
}
