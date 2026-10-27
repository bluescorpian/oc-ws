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
          ];
        };
      });
    };
}
