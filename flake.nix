{
  description = "Standalone build of Vim (minimal)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "vim";

      # Native: pkgs.pkgsStatic.vim is already minimal (no Lua, no
      # Python, no Ruby, no GUI), and the static set is in the binary
      # cache so this is a free download for Linux/Darwin runners.
      build = pkgs: pkgs.pkgsStatic.vim;

      # Windows: bypass nixpkgs' autotools-based pkgsCross.mingwW64.vim
      # (which pulls broken cross deps like gawk and forces ncurses) and
      # build via Vim's official Make_mingw.mak / Make_cyg_ming.mak with
      # CROSS=yes, GUI=no, statically linked C++ runtime + winpthread.
      # Result is a single console vim.exe importing only system DLLs.
      #
      # The runtime tree (share/vim/vim92) is reused from pkgs.vim — it's
      # pure text (.vim/.txt/.spl/.mo) with nothing arch-specific, and is
      # already in the binary cache, so the Windows install matches the
      # native install file-for-file.
      windowsBuild = pkgs:
        let
          cross = pkgs.pkgsCross.mingwW64;
          vimSrc = pkgs.vim.src;
          inherit (pkgs.vim) version;

          vimExe = cross.stdenv.mkDerivation {
            pname = "vim-exe";
            inherit version;
            src = vimSrc;

            dontConfigure = true;

            # libwinpthread.a (static pthread for MinGW). Without it,
            # Make_ming.mak's `-Wl,-Bstatic -lwinpthread` link line bails.
            buildInputs = [ cross.windows.pthreads ];
            strictDeps = true;
            enableParallelBuilding = true;

            # Make_mingw.mak knobs:
            #   FEATURES=NORMAL — middle ground (no Lua/Python/Ruby/Tcl,
            #     keeps syntax/spell/cmdline_compl etc).
            #   GUI=no          — console only.
            #   CROSS=yes       — cross-compile mode (skips host probes).
            #   STATIC_STDCPLUS / STATIC_WINPTHREAD — embed gcc/winpthread
            #     runtime so the .exe doesn't need libstdc++-6.dll or
            #     libwinpthread-1.dll companions.
            buildPhase = ''
              runHook preBuild
              cd src
              # Build only vim.exe + xxd.exe. The default `all` target
              # also tries to build GvimExt/gvimext.dll (Windows Explorer
              # shell extension), which we don't need for a headless CLI.
              make -f Make_ming.mak \
                FEATURES=NORMAL \
                GUI=no \
                CROSS=yes \
                CROSS_COMPILE=x86_64-w64-mingw32- \
                STATIC_STDCPLUS=yes \
                STATIC_WINPTHREAD=yes \
                WINDRES=x86_64-w64-mingw32-windres \
                ARCH=x86-64 \
                -j$NIX_BUILD_CORES \
                vim.exe xxd/xxd.exe
              cd ..
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp src/vim.exe $out/bin/vim.exe
              cp src/xxd/xxd.exe $out/bin/xxd.exe
              runHook postInstall
            '';

            passthru = { pname = "vim"; inherit version; };
          };

          # Extract just share/vim from pkgs.vim — pure text, identical
          # across platforms. Cheaper than building it twice and keeps
          # native and Windows installs file-for-file equivalent.
          vimRuntime = pkgs.runCommand "vim-runtime-${version}" { } ''
            mkdir -p $out/share
            cp -r ${pkgs.vim}/share/vim $out/share/vim
          '';
        in
        # Vim discovers runtime by walking up from $argv[0], so the .exe
        # in $out/bin and the runtime in $out/share/vim/vim92 wire up
        # automatically.
        pkgs.symlinkJoin {
          name = "vim-${version}-windows";
          paths = [ vimExe vimRuntime ];
          passthru = { pname = "vim"; inherit version; };
        };
    };
}
