{
  description = "Vim (runtime tree embedded) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Vim's runtime tree (share/vim/vim92 — syntax, ftplugin, doc, …) used to
  # ship as a companion `.tar.zst`, then as a deflate ZIP compiled in as a
  # read-only section (.incbin). It now rides the binary's SINGLE embedded
  # metadata/runtime ZIP, appended at EOF by the nix build (withRuntimeData,
  # next to the unpin/aliases + unpin/man entries) — the shared unpin-vfs core
  # (vfs.c + miniz.c; github:unpins/unpin-vfs) in self-EOF mode
  # (-DUNPIN_VFS_SELF) reads the running executable back and serves vim's libc
  # file calls for paths under a private mount root. Result: single static
  # binary, no companion file, no extract-on-first-run, no relink when only
  # runtime data changes.
  outputs = { self, unpins-lib }:
    let
      # Stage the vim<NN>/ tree CONTENTS (no version prefix) as the ZIP root so
      # $VIMRUNTIME is exactly the mount marker -- same value the bespoke VFS
      # used. `rtSrc` is the drv whose share/vim provides the tree; chmod: the
      # store copy is read-only and the embed needs writable staging.
      vimRuntimeStage = rtSrc: ''
        __vim_rt=$(ls -d ${rtSrc}/share/vim/vim* | head -1)
        cp -a "$__vim_rt/." "$__unpin_stage/"
        chmod -R u+w "$__unpin_stage"
      '';

      injectVfs = pkgs: oldDrv: oldDrv.overrideAttrs (old:
        let
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          is32bit = pkgs.stdenv.hostPlatform.is32bit;
          # macOS has no `ld --wrap`; rewrite vim's own objects' libc file refs
          # to the VFS shims with llvm-objcopy --redefine-sym (GNU objcopy can't
          # touch Mach-O). buildPackages so the cross darwin targets use a tool
          # that runs on the build host.
          objcopy = "${pkgs.buildPackages.llvm}/bin/llvm-objcopy";
        in
        {
          postPatch = (old.postPatch or "") + ''
            echo "==> inject unpin-vfs core (vfs.c + miniz.c, routed via ld --wrap)"
            cp ${./vfs.c}                   src/vfs.c
            cp ${./vfs.h}                   src/vfs.h
            cp ${./unpins_init.c}           src/unpins_init.c
            cp ${./miniz.h}                 src/miniz.h
            cp ${./miniz.c}                 src/miniz.c
            cp ${./unpin_zstd.c}            src/unpin_zstd.c
            cp ${./unpin_zstd.h}            src/unpin_zstd.h
            cp ${./zstddeclib.c}            src/zstddeclib.c

            echo "==> declare + wire unpins glue into main(): xxd dispatch (pre) + env pin (post)"
            # No vim.h macro hooks anymore -- ld --wrap intercepts vim's libc
            # open/stat/opendir/... at link time (see patches/Makefile_append).
            # unpins_xxd_dispatch() runs FIRST (multicall: argv[0]=="xxd" -> xxd
            # and exit); unpins_init() runs after mch_early_init() to pin
            # $VIMRUNTIME/$VIM at the mount root.
            sed -i '1i extern void unpins_init(void);\nextern void unpins_xxd_dispatch(int, char **);' src/main.c
            sed -i '0,/mch_early_init();/{s|mch_early_init();|unpins_xxd_dispatch(argc, argv);\n    mch_early_init();\n    unpins_init();|}' src/main.c

            echo "==> add OBJ entries + compile rules to autotools Makefile"
            sed -i 's|$(XDIFF_OBJS_USED)|$(XDIFF_OBJS_USED) \\\n\tobjects/vfs.o \\\n\tobjects/unpins_init.o \\\n\tobjects/unpin_zstd.o \\\n\tobjects/miniz.o \\\n\tobjects/xxd.o|' src/Makefile
            cat ${./patches/Makefile_append} >> src/Makefile
          '' + lib.optionalString (!isDarwin) ''
            echo "==> Linux: route vim's libc file calls into the VFS via ld --wrap"
            printf '%s\n' \
              'override ALL_LIBS += -Wl,--wrap=open -Wl,--wrap=stat -Wl,--wrap=lstat -Wl,--wrap=access -Wl,--wrap=opendir -Wl,--wrap=readdir -Wl,--wrap=closedir -Wl,--wrap=fopen' >> src/Makefile
          '' + lib.optionalString (!isDarwin && is32bit) ''
            echo "==> 32-bit musl is _REDIR_TIME64: wrap the __stat_time64 aliases too"
            printf '%s\n' \
              'UNPIN_VFS_DEFS += -DUNPIN_WRAP_TIME64' \
              'override ALL_LIBS += -Wl,--wrap=__stat_time64 -Wl,--wrap=__lstat_time64' >> src/Makefile
          '';

          # macOS: vim built+linked once already (with real libc refs and our
          # vfs.o present but unreferenced). Now rewrite each vim object's libc
          # file references to the _unpinvfs_* shims and relink. vfs.o/miniz.o/
          # unpins_*.o are left untouched, so the shims' own REAL_* calls still
          # resolve to libc. x86_64-darwin carries the $INODE64 ABI suffix on
          # stat/lstat/opendir/readdir; aarch64-darwin uses the plain names —
          # list both (--redefine-sym no-ops on absent symbols), so one block
          # covers both arches. xxd.o is rewritten too, but only ever sees real
          # paths, so the shims fall through to libc (same as the Linux --wrap).
          postBuild = lib.optionalString isDarwin ''
            echo "==> macOS: redefine vim's libc file refs -> _unpinvfs_*, then relink"
            for o in src/objects/*.o; do
              case "$o" in
                */vfs.o|*/miniz.o|*/unpin_zstd.o|*/unpins_init.o) continue ;;
              esac
              ${objcopy} \
                --redefine-sym _open=_unpinvfs_open \
                --redefine-sym _access=_unpinvfs_access \
                --redefine-sym _fopen=_unpinvfs_fopen \
                --redefine-sym _closedir=_unpinvfs_closedir \
                --redefine-sym '_stat$INODE64=_unpinvfs_stat'       --redefine-sym _stat=_unpinvfs_stat \
                --redefine-sym '_lstat$INODE64=_unpinvfs_lstat'     --redefine-sym _lstat=_unpinvfs_lstat \
                --redefine-sym '_opendir$INODE64=_unpinvfs_opendir' --redefine-sym _opendir=_unpinvfs_opendir \
                --redefine-sym '_readdir$INODE64=_unpinvfs_readdir' --redefine-sym _readdir=_unpinvfs_readdir \
                "$o"
            done
            echo "==> macOS: relink vim against the rewritten objects"
            rm -f src/vim
            make -C src -j''${NIX_BUILD_CORES:-1}
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

      # Native (Linux + Darwin) — start from pkgsStatic.vim (already cached on
      # the binary cache) and layer the VFS on top. `build` returns this PRISTINE
      # injectVfs base (no embed) so mkStandaloneFlake's hooks reach the compile;
      # the embed is declared in `runtimeEmbed` below and runs once, post-build,
      # via the shared unpinEmbedWrap (the single embed path).
      build = pkgs: injectVfs pkgs pkgs.pkgsStatic.vim;

      # The whole embedded container (one pack): the runtime tree (read back by
      # the VFS's self-EOF mode; the same UNMODIFIED pkgsStatic.vim source the
      # .incbin zip used), the `xxd` alias, and the man pages (man = true harvests
      # the base's own share/man). xxd is FOLDED into the vim binary (objects/
      # xxd.o + argv[0] dispatch), so there's no separate xxd file to harvest —
      # hence the explicit `aliases = [ "xxd" ]` (auto-harvest can't see it:
      # nixpkgs moves the standalone xxd to its own output). unpin creates the
      # `xxd -> vim` command at install time; the binary dispatches on argv[0].
      # Windows grafts the runtime + man from the NATIVE vim (host-agnostic text
      # files; the cross build ships no man of its own).
      runtimeEmbed = {
        native = pkgs: base: {
          aliases = [ "xxd" ];
          man = true;
          runtimeStage = vimRuntimeStage pkgs.pkgsStatic.vim;
        };
        windows = pkgs: base: {
          aliases = [ "xxd" ];
          runtimeStage = vimRuntimeStage pkgs.vim;
          manRoot = "${pkgs.vim.man or pkgs.vim}";
        };
      };

      # Windows — Make_ming.mak cross build, same unpin-vfs core. There is no
      # win32_* layer to `ld --wrap` (that's perl's shape), and vim canonicalises
      # virtual paths to "C:\<marker>\…", so the core is built in marker mode
      # (-DUNPIN_VFS_WIN_MARKER): unpin_vfs_is_virtual matches the marker anywhere
      # in the path, and the explicit unpin_vfs_* API materialises to a temp file
      # and serves it from the CRT. mch_open/mch_fopen (real functions in
      # os_win32.c that wrap _wopen/_wfopen for wide-char paths) get a
      # virtual-path fast path patched in at entry. xxd is folded in just like
      # the native build (objx86-64/xxd.o + argv[0] dispatch) and exposed as an
      # unpin alias; the console (GUI=no) binary runs xxd fine.
      windowsBuild = pkgs:
        let
          cross = pkgs.pkgsCross.mingwW64;
          prefix = cross.stdenv.hostPlatform.config;
        in
        cross.stdenv.mkDerivation {
          pname = "vim";
          inherit (pkgs.vim) version src;

          dontConfigure = true;
          buildInputs = [ cross.windows.pthreads ];
          strictDeps = true;
          enableParallelBuilding = true;

          postPatch = ''
            echo "==> inject unpin-vfs core sources"
            cp ${./vfs.h}                   src/vfs.h
            cp ${./vfs.c}                   src/vfs.c
            cp ${./unpins_init.c}           src/unpins_init.c
            cp ${./miniz.h}                 src/miniz.h
            cp ${./miniz.c}                 src/miniz.c
            cp ${./unpin_zstd.c}            src/unpin_zstd.c
            cp ${./unpin_zstd.h}            src/unpin_zstd.h
            cp ${./zstddeclib.c}            src/zstddeclib.c

            echo "==> declare + wire unpins glue into VimMain(): env pin + xxd dispatch"
            # On Windows, VimMain() ignores the argv it is handed and re-fetches
            # the real (wide) command line with get_cmd_argsW() -- AFTER
            # mch_early_init(). So pin the env after mch_early_init (as on Unix),
            # but dispatch xxd only AFTER get_cmd_argsW(), or argv[0] is still the
            # unreliable narrow value and never matches "xxd".
            sed -i '1i extern void unpins_init(void);\nextern void unpins_xxd_dispatch(int, char **);' src/main.c
            sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c
            sed -i 's|argc = get_cmd_argsW(&argv);|&\n    unpins_xxd_dispatch(argc, argv);|' src/main.c

            echo "==> patch os_win32.c mch_open/mch_fopen to dispatch virtual paths via the VFS"
            # No win32_* to --wrap here; give the real mch_open/mch_fopen a
            # virtual-path fast path at entry, calling the explicit unpin_vfs_*
            # API (declared inline -- unpin_vfs_fopen lives behind UNPIN_VFS_DIRS
            # in vfs.h, which this TU doesn't define).
            sed -i 's|^#include "vim.h"|#include "vim.h"\nextern int unpin_vfs_is_virtual(const char *);\nextern int unpin_vfs_open(const char *, int, ...);\nextern FILE *unpin_vfs_fopen(const char *, const char *);|' src/os_win32.c
            awk '
            /^mch_open\(const char \*name, int flags, int mode\)$/ {
                print; getline; print;
                print "    if (unpin_vfs_is_virtual(name))";
                print "\treturn unpin_vfs_open(name, flags, mode);";
                next;
            }
            /^mch_fopen\(const char \*name, const char \*mode\)$/ {
                print; getline; print;
                print "    if (unpin_vfs_is_virtual(name))";
                print "\treturn unpin_vfs_fopen(name, mode);";
                next;
            }
            { print }' src/os_win32.c > src/os_win32.c.new
            mv src/os_win32.c.new src/os_win32.c

            echo "==> patch os_mswin.c vim_stat so :runtime/:syntax resolve in the VFS"
            # mch_stat is a macro -> vim_stat() -> stat_impl(). vim's
            # gen_expand_wildcards verifies a (wildcard-free) runtime file with
            # mch_getperm()->mch_stat() BEFORE sourcing it, so without this the
            # whole runtime tree (syntax/menu/ftplugin/indent) is invisible.
            # Materialise the virtual path to a temp and let vim's own stat_impl
            # fill its stat_T (avoids re-deriving the struct layout here).
            sed -i 's|^#include "vim.h"|#include "vim.h"\nextern int unpin_vfs_is_virtual(const char *);\nextern const char *unpin_vfs_winpath(const char *);|' src/os_mswin.c
            awk '
            /^vim_stat\(const char \*name, stat_T \*stp\)$/ {
                print; getline; print;
                print "    if (unpin_vfs_is_virtual(name)) {";
                print "\tconst char *__m = unpin_vfs_winpath(name);";
                print "\treturn __m ? stat_impl(__m, stp, TRUE) : -1;";
                print "    }";
                next;
            }
            { print }' src/os_mswin.c > src/os_mswin.c.new
            mv src/os_mswin.c.new src/os_mswin.c

            echo "==> add OBJ entries to Make_cyg_ming.mak"
            cat ${./patches/Make_cyg_ming_append} >> src/Make_cyg_ming.mak
          '';

          buildPhase = ''
            runHook preBuild

            # Pre-build our objects into OUTDIR (objx86-64 for ARCH=x86-64).
            # Make_ming.mak's pattern rule doesn't carry the VFS/miniz defines,
            # so the explicit compile here is the simplest reliable hook.
            mkdir -p src/objx86-64
            MINIZ_DEFS='-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES'
            CFLAGS_BASE='-I. -O2 -march=x86-64 -DWIN32 -DWINVER=0x0601 -D_WIN32_WINNT=0x0601'
            # The string-literal -D flags are written inline (single quotes round
            # the double quotes) so the C string survives the shell intact -- the
            # same form the native Makefile_append uses. Routing through a shell
            # variable would leave literal quotes and mangle the macro.
            ( cd src && \
              ${prefix}-gcc -c $CFLAGS_BASE \
                -DUNPIN_VFS_WIN_MARKER='"__unpins_vimruntime__"' \
                -DUNPIN_VFS_ROOT='"/__unpins_vimruntime__/"' \
                -DUNPIN_VFS_SELF \
                $MINIZ_DEFS -o objx86-64/vfs.o                vfs.c                 && \
              ${prefix}-gcc -c $CFLAGS_BASE                    -o objx86-64/unpins_init.o        unpins_init.c         && \
              ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -w     -o objx86-64/miniz.o              miniz.c               && \
              ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -DUNPIN_ZSTD_VENDORED -w -o objx86-64/unpin_zstd.o unpin_zstd.c && \
              ${prefix}-gcc -c $CFLAGS_BASE -Dmain=xxd_main -w -o objx86-64/xxd.o                xxd/xxd.c )

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
              vim.exe

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp src/vim.exe $out/bin/vim.exe
            # Runtime tree is embedded; xxd is folded in — single binary.
            runHook postInstall
          '';

          passthru = { pname = "vim"; inherit (pkgs.vim) version; };
        };
    };
}
