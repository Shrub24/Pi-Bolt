# buildPiBoltPlugin: a Pi extension as a derivation, ready both to be compiled into Pi-Bolt (pi-bolt.withPlugins) and to be
# loaded at run time from the store (`-e ${plugin.extensionPath}`), from the same patched tree.
#
#   buildPiBoltPlugin {
#     pname = "loop-police";
#     version = "1.14.1";
#     src = fetchurl { url = "https://registry.npmjs.org/pi-loop-police/-/pi-loop-police-1.14.1.tgz"; hash = "..."; };
#     entry = "extensions/loop-police.ts";        # the file whose default export is the extension factory
#     libraries = [ piBoltPlugins.yaml ];         # npm packages it imports (fetchNpmPackage)
#     dependencies = [ piBoltPlugins.tool-renderer ];  # other plugins it imports, by their package names
#     postPatch = ''substituteInPlace ... --replace-fail ...'';
#   }
#
# The output is the plugin's tree with a node_modules of its own: its libraries (copied, so that their own imports of each other
# resolve from where they are) and its plugin dependencies (linked, by packageName). Pi's own packages are never in it: Pi
# provides them, to a compiled plugin and to one loaded at run time alike.
{
  lib,
  stdenvNoCC,
}:
lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "entry"
    "pluginName"
    "packageName"
    "dependencies"
    "libraries"
    "nodeModules"
    "workers"
    "builtin"
    "runtimeInputs"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      # Only names the derivation: a plugin's real version lives in its own package.json.
      version ? "0",
      # The file, relative to the plugin's root, whose default export is the extension factory.
      entry,
      # The name Pi knows it by: builtin:<pluginName> turns it on and -builtin:<pluginName> off.
      pluginName ? finalAttrs.pname,
      # The name other plugins import it by (its package.json "name"), when it is a dependency of theirs.
      packageName ? null,
      # Other plugins (buildPiBoltPlugin) this one imports. Compiled in, each is staged once and shared, whether or not it is
      # also registered.
      dependencies ? [ ],
      # npm packages this plugin imports (fetchNpmPackage, or any folder with passthru.packageName).
      libraries ? [ ],
      # A ready node_modules folder (e.g. "${deps}/node_modules"), merged under the libraries.
      nodeModules ? null,
      # External programs this plugin needs at run time; dependencies' programs are included too.
      runtimeInputs ? [ ],
      # Worker scripts the plugin starts (new Worker(new URL("./worker.ts", import.meta.url))), relative to its root: each is
      # compiled as an entry point of its own (scripts/build-pi.sh --plugin-worker).
      workers ? [ ],
      # Registered as a built-in extension (builtin:<name>), which settings can turn off and a run-time copy replaces.
      builtin ? true,
      ...
    }@args:
    let
      libraryName =
        library:
        library.packageName or library.passthru.packageName
          or (throw "buildPiBoltPlugin ${finalAttrs.pname}: library ${library.name or "?"} has no packageName");
      depInfo =
        dep:
        dep.piBolt
          or (throw "buildPiBoltPlugin ${finalAttrs.pname}: dependency ${dep.name or "?"} is not a Pi-Bolt plugin");
    in
    {
      dontConfigure = args.dontConfigure or true;
      dontBuild = args.dontBuild or true;
      # (A plugin is source: its TypeScript is the deliverable, so there is nothing to strip or patch.)
      dontFixup = args.dontFixup or true;

      installPhase =
        args.installPhase or ''
          runHook preInstall
          mkdir -p $out
          cp -r . $out/
          chmod -R u+w $out
          ${lib.optionalString (nodeModules != null) ''
            mkdir -p $out/node_modules
            cp -rL --no-preserve=mode ${nodeModules}/. $out/node_modules/
          ''}
          ${lib.concatMapStrings (library: ''
            rm -rf $out/node_modules/${libraryName library}
            mkdir -p $out/node_modules/${libraryName library}
            cp -rL --no-preserve=mode ${library}/. $out/node_modules/${libraryName library}/
          '') libraries}
          ${lib.concatMapStrings (
            dep:
            # (A dependency with no packageName is imported by a relative path to its staged sibling, ../<name>/.)
            lib.optionalString ((depInfo dep).packageName != null) ''
              rm -rf $out/node_modules/${(depInfo dep).packageName}
              mkdir -p $(dirname $out/node_modules/${(depInfo dep).packageName})
              ln -s ${dep} $out/node_modules/${(depInfo dep).packageName}
            ''
          ) dependencies}
          # Pi provides its packages; a copy here would be a second Pi.
          rm -rf $out/node_modules/@earendil-works/pi-* $out/node_modules/typebox
          test -f $out/${lib.escapeShellArg entry} || {
            echo "buildPiBoltPlugin: entry ${entry} is not in the plugin's tree" >&2
            exit 1
          }
          runHook postInstall
        '';

      passthru = {
        # What pi-bolt's build reads (nix/package.nix).
        piBolt = {
          name = pluginName;
          inherit
            entry
            packageName
            dependencies
            workers
            builtin
            ;
          runtimeInputs = lib.unique (
            runtimeInputs ++ lib.concatMap (dep: (depInfo dep).runtimeInputs) dependencies
          );
        };
        # For loading it at run time instead: `pi -e ${plugin.extensionPath}`, or a settings.json "extensions" row.
        extensionPath = "${finalAttrs.finalPackage}/${entry}";
      }
      // args.passthru or { };

      meta = {
        description = "Pi extension ${pluginName}";
      }
      // args.meta or { };
    };
}
