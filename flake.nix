{
  description = "WebSocket client library for OpenComputers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAll (pkgs: {
        # OpenComputers runs Lua 5.3 by default, so the host tests do too.
        default = pkgs.mkShell {
          packages = [
            (pkgs.lua5_3.withPackages (ps: [ ps.busted ps.luasocket ]))
            pkgs.lua53Packages.luacheck
            pkgs.nodejs
            pkgs.pnpm
            pkgs.openssl
            pkgs.zip
          ];
        };

        # For tests/ocemu/run.sh: OCEmu loads SDL2 through luaffi, which the
        # script builds with luarocks. OCEmu is written for Lua 5.2 and calls
        # math.pow, so its Lua 5.3 needs the 5.2 compatibility functions.
        ocemu = pkgs.mkShell {
          packages = [
            (pkgs.lua5_3_compat.withPackages (ps: [ ps.luarocks ps.luafilesystem ps.luautf8 ps.luasocket ]))
            pkgs.gcc
            pkgs.nodejs
            pkgs.pnpm
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.SDL2 ];
          SDL_VIDEODRIVER = "dummy";
          SDL_AUDIODRIVER = "dummy";
        };
      });
    };
}
