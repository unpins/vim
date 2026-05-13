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

      # pkgs.pkgsStatic.vim is already minimal (no Lua/Python/Ruby/GUI)
      # and lives in the binary cache.
      build = pkgs: pkgs.pkgsStatic.vim;

      # pkgsCross.mingwW64.vim is autotools-based and pulls broken cross
      # deps (gawk, ncurses); build Vim's own Make_ming.mak directly.
      # Runtime tree (share/vim/vim92) is pure text — reuse from pkgs.vim
      # so native and Windows installs are file-for-file equivalent.
      windowsBuild = pkgs:
        let
          cross = pkgs.pkgsCross.mingwW64;
          prefix = cross.stdenv.hostPlatform.config;
        in
        cross.stdenv.mkDerivation {
          pname = "vim";
          inherit (pkgs.vim) version src;

          dontConfigure = true;

          # libwinpthread.a (static pthread for MinGW). Without it,
          # Make_ming.mak's `-Wl,-Bstatic -lwinpthread` line bails.
          buildInputs = [ cross.windows.pthreads ];
          strictDeps = true;
          enableParallelBuilding = true;

          # Make_ming.mak knobs:
          #   FEATURES=NORMAL — no Lua/Python/Ruby/Tcl; keeps syntax/spell/...
          #   GUI=no          — console only (Make_ming.mak defaults to yes).
          #   CROSS=yes       — skips host probes.
          #   STATIC_*=yes    — embed gcc/winpthread runtime; no DLL companions.
          # Build vim.exe + xxd.exe explicitly: default `all` also builds
          # GvimExt/gvimext.dll (Explorer shell extension) which we don't need.
          buildPhase = ''
            runHook preBuild
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

          # Vim discovers runtime by walking up from $argv[0]; $out/bin
          # + $out/share/vim/vim92 wire up automatically.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share
            cp src/vim.exe $out/bin/vim.exe
            cp src/xxd/xxd.exe $out/bin/xxd.exe
            cp -r ${pkgs.vim}/share/vim $out/share/vim
            runHook postInstall
          '';

          passthru = { pname = "vim"; inherit (pkgs.vim) version; };
        };
    };
}
