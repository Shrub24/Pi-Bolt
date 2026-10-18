# Nix

The flake builds Pi-Bolt with Nix-packaged extensions compiled in:

```nix
pi-bolt.withPlugins (ps: [ ps.word-count my-plugin ])
```

- [How it builds](#how-it-builds)
- [Packages](#packages)
- [Writing a plugin derivation](#writing-a-plugin-derivation)
- [Preparing plugins for compilation](#preparing-plugins-for-compilation)
- [Home Manager](#home-manager)
- [Updating the pin](#updating-the-pin)

## How it builds

As [`pi-bolt compile`](PLUGINS.md#pi-bolt-compile) does: from a release's compile kit (Pi's built packages, the training
profile and the compile command) and its runtime (the Bun with the AOT compiler). There is no build of Pi, so a build with
plugins takes about 30 seconds. `nix/release.json` pins the release by the hashes in its signed `SHA256SUMS`.

The build is the release's Pi. Changes to `packages/` in a checkout reach the flake with the next release, not before.

[`nix/build.py`](../nix/build.py) stages each plugin into the kit's tree, writes the manifest and entry point, and runs the
kit's compile command. It does not rewrite plugin source or infer its dependencies. Each selected plugin is a built-in
extension, `builtin:<name>`: enabled by default, disabled by `-builtin:<name>` in the `extensions` setting or by
`--no-extensions`.

Two derivations keep launcher changes from triggering compilation:

| | |
|---|---|
| `pi-bolt.unwrapped` | The compiled executable and release files under `lib/pi-bolt`, with no launcher of its own. `passthru.runtimeInputs` lists the PATH dependencies declared by the selected plugins and package. |
| `pi-bolt` | A copy with the launcher: `bin/pi-bolt` and `bin/pi`, runtime tools on PATH. |

The wrapped package holds a copy rather than a link so that its launcher and executable are in one store path. Pi-Bolt resolves
assets from `process.execPath`, and tools comparing installations compare that path. The unwrapped output has no launcher of its
own: a launcher's job is setting PATH, which is the consumer's choice. Consumers that need one copy its `lib/pi-bolt` tree, wrap
`lib/pi-bolt/pi` into their own `$out/bin`, and compose PATH from `pi-bolt.unwrapped.runtimeInputs`. Keep the wrapper and
its executable together in the consumer's output.

Linux x86-64 and ARM64 are supported. The macOS kit exists; its launcher is not packaged yet.

## Packages

| Output | |
|---|---|
| `packages.<system>.pi-bolt` (default) | No plugins. JIT off. |
| `packages.<system>.pi-bolt-jit` | The JIT build. |
| `packages.<system>.pi-bolt-example` | [`examples/plugins`](../examples/plugins) compiled in. |
| `legacyPackages.<system>.piBoltPlugins` | The plugin scope: `buildPiBoltPlugin`, `fetchNpmPackage`, and the plugins carried here. |
| `overlays.default` | Adds `pi-bolt`, `pi-bolt-unwrapped`, and `piBoltPlugins` to the consumer's package set. |
| `checks.<system>.plugins` | Compiles and runs the plugin contract check in [`nix/tests`](../nix/tests). |

The overlay does not replace Pi's package. Choose Pi-Bolt explicitly.

A plugin of your own joins the scope like any nixpkgs package set, so `withPlugins` can select it by name:

```nix
nixpkgs.overlays = [
  inputs.pi-bolt.overlays.default
  (final: prev: {
    piBoltPlugins = prev.piBoltPlugins.overrideScope (pfinal: _pprev: {
      my-plugin = pfinal.buildPiBoltPlugin {
        pname = "my-plugin";
        src = ./my-plugin;
        entry = "index.ts";
      };
    });
  })
];
```

`pluginName` is the id Pi knows it by (`builtin:<pluginName>`) and defaults to `pname`. `packageName` is the name another plugin
imports it by; it has no default and is needed only when a dependent plugin imports this one by name.

`pi-bolt.override` takes:

| Argument | Default | |
|---|---|---|
| `plugins` | `[ ]` | `buildPiBoltPlugin` derivations to compile in. `withPlugins (ps: ...)` selects from `piBoltPlugins`. |
| `jit` | `false` | The JIT build ([which to use](PLUGINS.md#three-ways-to-run-a-plugin)). |
| `maxAotCandidateBytecodeSize` | unset | Raise the compiler's module size limit ([PLUGINS.md](PLUGINS.md#what-it-cannot-do)). |
| `runtimeInputs` | `[ ripgrep fd ]` | Programs on Pi's PATH, in addition to the tools declared by selected plugins. The aggregate is exposed as `pi-bolt.runtimeInputs` and `pi-bolt.unwrapped.runtimeInputs`. |

The package never passes arguments to Pi: `withPlugins` chooses what is compiled in, and everything else is a launch decision the
consumer owns. A consumer that wants default flags writes its own launcher around `bin/pi-bolt` (see below), the way the upstream
Home Manager module wraps Pi for PATH only.

`withPlugins` returns a package that is still overridable, so both orders work: `(pi-bolt.withPlugins (ps: [ ps.word-count
])).override { jit = true; }`, or `overrideAttrs` on the result. Repeated references to the same plugin derivation are
deduplicated. Different derivations with the same plugin name are rejected, including dependencies: choose one version or patch
consistently in the plugin scope.

Builds are always the baseline variant: code tuned for its builder's CPU could not be shared or substituted, and the derivation
would have to name that CPU.

## Writing a plugin derivation

```nix
{ piBoltPlugins, wl-clipboard }:
piBoltPlugins.buildPiBoltPlugin {
  pname = "my-plugin";
  version = "1.0.0";
  src = ./my-plugin;
  entry = "index.ts";
  runtimeInputs = [ wl-clipboard ];
}
```

The output is the plugin's patched source tree with its dependencies in `node_modules`. The same derivation serves both paths:
compiled in through `withPlugins`, or loaded at run time by a launcher of your own passing `-e ${my-plugin.extensionPath}`.
Compiling a plugin in adds its runtime tools to PATH; loading one at run time is the launcher's business, so add
`${lib.makeBinPath my-plugin.piBolt.runtimeInputs}` there if the plugin needs programs.

| Attribute | |
|---|---|
| `entry` | The file whose default export is the extension factory, relative to the plugin root. |
| `pluginName` | The name Pi knows as `builtin:<pluginName>`. Default: `pname`. |
| `packageName` | Its package.json name, for plugins that import it by that name. |
| `dependencies` | Other plugin derivations it imports. Each is staged once and shared, whether or not also registered. |
| `libraries` | Explicit npm libraries, each with `passthru.packageName`. Their dependencies must be supplied too. |
| `nodeModules` | A ready `node_modules` directory, copied before `libraries` are added. An escape hatch for a lockfile-built tree: every plugin passed the same directory carries its own copy of it, so the union costs one tree per plugin. `libraries` is the typed path and does not have that cost. |
| `runtimeInputs` | External programs the plugin needs; dependency plugins' tools are included automatically. |
| `workers` | Worker scripts relative to the root, each compiled as an entry point of its own. |
| `builtin` | `false` registers an inline extension rather than a selectable built-in extension. |

`patches`, `postPatch`, and other `mkDerivation` attributes work as usual. Pi's own packages (`@earendil-works/pi-*`, `typebox`)
are provided by Pi, not staged from plugins: a second copy would mean duplicate classes and registries.

`fetchNpmPackage` fetches and unpacks one pinned npm package; it does not install dependencies:

```nix
piBoltPlugins.fetchNpmPackage {
  pname = "pi-loop-police";
  version = "1.14.1";
  hash = "sha512-..."; # npm view pi-loop-police@1.14.1 dist.integrity
}
```

For a plugin with a lockfile, use nixpkgs' dependency builder and pass its **`node_modules` subdirectory**, not its output root:

```nix
let
  deps = pkgs.importNpmLock.buildNodeModules {
    npmRoot = ./my-plugin;
    nodejs = pkgs.nodejs;
    derivationArgs.npmRebuildFlags = [ "--ignore-scripts" ];
  };
in pkgs.piBoltPlugins.buildPiBoltPlugin {
  pname = "my-plugin";
  version = "1.0.0";
  src = ./my-plugin;
  entry = "index.ts";
  nodeModules = "${deps}/node_modules";
}
```

## Preparing plugins for compilation

Plugin derivations must satisfy the [AOT compatibility checklist](PLUGINS.md#compatibility-checklist). The builder does not
attempt to make arbitrary npm packages compatible or lint JavaScript with text patterns. Patch the particular expressions
that need adaptation with `substituteInPlace --replace-fail`, so upstream changes fail visibly.

For example, a plugin reading `data.txt` through `new URL("./data.txt", import.meta.url)` needs a real store path when compiled
in. Its source URL would otherwise point into the executable's virtual file system:

```nix
postPatch = ''
  substituteInPlace index.ts \
    --replace-fail 'new URL("./data.txt", import.meta.url)' "\"$out/data.txt\""
'';
```

That patched path also works when the plugin is loaded from the store. Do not replace every occurrence of `import.meta.url`:
worker URLs may need to retain it so Bun can find their compiled entry points.

Other common adaptations are writing state under `getAgentDir()` rather than beside read-only sources, replacing computed
imports with literal imports, and choosing `jit = true` for `bun:ffi`. See [PLUGINS.md](PLUGINS.md) for the remaining limits.

## Home Manager

Use Home Manager's existing `programs.pi-coding-agent` module for configuration and the package API for compilation:

```nix
{ inputs, pkgs, ... }:
{
  nixpkgs.overlays = [ inputs.pi-bolt.overlays.default ];
  programs.pi-coding-agent = {
    enable = true;
    package = (pkgs.pi-bolt.override { jit = true; }).withPlugins (ps: [ ps.word-count ]);
    settings.defaultProvider = "anthropic";
  };
}
```

With Home Manager's `useGlobalPkgs`, install the overlay in the system's nixpkgs configuration instead. Without an overlay,
use `inputs.pi-bolt.packages.${pkgs.stdenv.hostPlatform.system}.pi-bolt` directly; its `withPlugins` uses the flake's plugin scope.

Do not use the module's `extraPackages` with Pi-Bolt: it wraps only `bin/pi` inside a `symlinkJoin`, so the command on PATH
lives in a different store path than the executable it runs, which the launcher above exists to avoid, and `pi-bolt` gets none of
that PATH. Add programs through the package's `runtimeInputs` instead.

The module also provides `configDir`, models, keybindings, context and appended system instructions. Pi-Bolt does not add a
second configuration module. Leave `settings` unset for settings managed interactively by Pi; declarative settings are
read-only and Pi cannot persist changes to them. Keep credentials out of Nix-generated files.

**Compiled extensions are not npm package installations.** Selecting `word-count` above compiles it as `builtin:word-count`,
enabled by default. Do not also install it through `settings.packages = [ "npm:..." ]`. To disable it, use
`settings.extensions = [ "-builtin:word-count" ]`. A Pi package can contain skills, prompts and themes as well as extensions;
compiling an extension does not install those other resources.

For a configuration shared with ordinary Pi, use the existing `piBolt.packages` exclusions. If a Nix derivation compiles
`pi-loop-police` into Pi-Bolt, this keeps its npm installation for Pi without loading it again in Pi-Bolt:

```nix
programs.pi-coding-agent.settings = {
  packages = [ "npm:pi-loop-police" ];
  piBolt.packages = [ "-npm:pi-loop-police" ];
};
```

This excludes the entire npm package from Pi-Bolt, including any skills, prompts or themes it supplies. Declare any needed
resources separately. Provider and model settings can be shared unchanged. Builtins are enabled by default, so the shared
configuration need not reference them; ordinary Pi cannot resolve Pi-Bolt-specific `builtin:` paths. There is no automatic
translation of `npm:` sources to compiled plugins.

`pi-bolt update` and `pi-bolt compile` are for installer installations. With Nix, update the flake input and choose plugins in
Nix.

## Updating the pin

`publish` advances this when it publishes a release, and `ci` fails when the pin and the latest release disagree, so it is
normally a redo or a deliberate choice to build another release. The flake app runs the script with openssl and python on PATH;
`--root` is the checkout you run it from:

```bash
nix run .#update-release            # the version in VERSION
nix run .#update-release -- 0.9.2   # or another release
```

[nix/update-release.py](../nix/update-release.py) does the same directly.

It checks the release's `SHA256SUMS` against `keys/release.pub` and its first line against the version, then writes the kit's,
the runtime's and the release archive's hashes. A release must carry its kit (`pi-bolt-kit-<platform>.tar.gz`) to be pinned.
