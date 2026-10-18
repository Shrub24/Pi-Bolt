{
  description = "Pi-Bolt: Pi, the coding agent, compiled ahead of time, with Nix-packaged plugins compiled in";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system: f (nixpkgs.legacyPackages.${system}.extend self.overlays.default)
        );
    in
    {
      # pi-bolt, pi-bolt-unwrapped and the piBoltPlugins scope (buildPiBoltPlugin, fetchNpmPackage, the plugins carried here).
      overlays.default = final: _prev: {
        piBoltPlugins = final.callPackage ./nix/plugins { };
        pi-bolt = final.callPackage ./nix/package.nix { };
        pi-bolt-unwrapped = final.pi-bolt.unwrapped;
      };

      packages = forAllSystems (pkgs: {
        default = pkgs.pi-bolt;
        inherit (pkgs) pi-bolt pi-bolt-unwrapped;
        pi-bolt-jit = pkgs.pi-bolt.override { jit = true; };
        # examples/plugins compiled in.
        pi-bolt-example = pkgs.pi-bolt.withPlugins (ps: [ ps.word-count ]);
      });

      # The plugin set is a scope (its builders are functions), so it is here rather than under packages.
      legacyPackages = forAllSystems (pkgs: {
        inherit (pkgs) piBoltPlugins;
      });

      checks = forAllSystems (
        pkgs:
        let
          plugins = pkgs.callPackage ./nix/tests { };
        in
        {
          inherit plugins;
          default = plugins;
        }
      );

      # nix run .#update-release [-- version]: repin the release the kit and runtime come from.
      apps = forAllSystems (pkgs: {
        update-release = {
          type = "app";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "pi-bolt-update-release";
              runtimeInputs = with pkgs; [
                openssl
                python3
              ];
              # The caller's checkout, not this script's store path, is what gets written to.
              text = ''exec python3 ${./nix/update-release.py} --root "$PWD" "$@"'';
            }
          );
          meta.description = "Repin nix/release.json to a Pi-Bolt release";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
