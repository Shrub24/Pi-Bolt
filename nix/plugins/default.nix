# The Pi-Bolt plugin set, a scope in the manner of nixpkgs' package sets: its builders, and the plugins this repository carries.
#
# Add your own with an overlay, as for any nixpkgs scope:
#
#   final: prev: {
#     piBoltPlugins = prev.piBoltPlugins.overrideScope (pfinal: pprev: {
#       my-plugin = pfinal.buildPiBoltPlugin { ... };
#     });
#   }
#
# or pass plugins built anywhere straight to `pi-bolt.withPlugins` (they need not be in this set).
{
  lib,
  newScope,
}:
lib.makeScope newScope (self: {
  buildPiBoltPlugin = self.callPackage ./build-plugin.nix { };
  fetchNpmPackage = self.callPackage ./fetch-npm-package.nix { };

  # examples/plugins: the /words command (docs/PLUGINS.md).
  word-count = self.buildPiBoltPlugin {
    pname = "word-count";
    version = "0";
    src = lib.fileset.toSource {
      root = ../../examples/plugins/extensions;
      fileset = ../../examples/plugins/extensions/word-count.ts;
    };
    entry = "word-count.ts";
    meta.license = lib.licenses.mit;
  };
})
