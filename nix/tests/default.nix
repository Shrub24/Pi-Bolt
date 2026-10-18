# The flake's plugin contract check: compiled in and loaded from the store.
#
# consumer imports helper by its package name, `ms` from its lockfile and data.txt through an explicit store-path patch.
# helper is also registered, so it must be staged once and shared. Its declared runtime tool must reach consumer's PATH.
# The model consumer registers is named after what it saw, and `--list-models` prints it.
{
  lib,
  runCommand,
  writeShellScriptBin,
  importNpmLock,
  makeBinaryWrapper,
  nodejs,
  pi-bolt,
  piBoltPlugins,
}:
let
  inherit (piBoltPlugins) buildPiBoltPlugin;
  tool = writeShellScriptBin "pi-bolt-check-tool" "printf 'tool' ";
  nodeModules = importNpmLock.buildNodeModules {
    npmRoot = ./consumer;
    inherit nodejs;
    derivationArgs.npmRebuildFlags = [ "--ignore-scripts" ];
  };

  helper = buildPiBoltPlugin {
    pname = "pi-bolt-check-helper";
    version = "0";
    src = ./helper;
    entry = "index.ts";
    packageName = "@pi-bolt-check/helper";
    pluginName = "check-helper";
    runtimeInputs = [ tool ];
  };

  consumer = buildPiBoltPlugin {
    pname = "pi-bolt-check-consumer";
    version = "0";
    src = ./consumer;
    entry = "index.ts";
    dependencies = [ helper ];
    # Distinct names that used to produce the same JavaScript import binding.
    pluginName = "check_helper";
    nodeModules = "${nodeModules}/node_modules";
    postPatch = ''
      substituteInPlace index.ts \
        --replace-fail 'new URL("./data.txt", import.meta.url)' "\"$out/data.txt\""
    '';
  };

  built = pi-bolt.withPlugins (ps: [
    ps.word-count
    helper
    consumer
    helper
  ]);
  # What a consumer that wants a plugin at run time owns: its own launcher, the plugin's store path and its tools.
  runtime = runCommand "pi-bolt-runtime-check" { nativeBuildInputs = [ makeBinaryWrapper ]; } ''
    mkdir -p $out/bin
    makeBinaryWrapper ${lib.getExe pi-bolt} $out/bin/pi-bolt \
      ${
        lib.optionalString (
          consumer.piBolt.runtimeInputs != [ ]
        ) "--prefix PATH : ${lib.makeBinPath consumer.piBolt.runtimeInputs}"
      } \
      --add-flag -e --add-flag ${consumer.extensionPath}
  '';
  conflicting = pi-bolt.withPlugins (_: [
    helper
    (helper.overrideAttrs (old: {
      version = "1";
      src = old.src;
    }))
  ]);
  expected = "hello-fromdisk-3600000-loads1-tool";
in
assert !(builtins.tryEval conflicting.unwrapped.plan.drvPath).success;
assert lib.elem tool built.unwrapped.runtimeInputs;
assert lib.elem tool built.runtimeInputs;
assert lib.hasSuffix "-jit"
  ((pi-bolt.override { jit = true; }).withPlugins (_: [ helper ])).unwrapped.variant;
# A launcher-only change leaves the compiled payload alone.
assert
  pi-bolt.unwrapped.drvPath == (pi-bolt.overrideAttrs (_: {
    postInstall = "touch $out/launcher-only";
  })).unwrapped.drvPath;
runCommand "pi-bolt-plugins-check" { } ''
  export HOME=$TMPDIR PI_OFFLINE=1
  test -x ${built.unwrapped}/lib/pi-bolt/pi
  # Compiled in: every plugin is a built-in extension, and the consumer's model reports what it saw.
  ${lib.getExe built} --list-models pi-bolt-check > models.txt 2>&1 || { cat models.txt; exit 1; }
  cat models.txt
  grep -q -- '${expected}' models.txt || {
    echo "expected the compiled-in consumer's model ${expected}" >&2
    exit 1
  }
  # Turned off as any built-in is: no model.
  ${lib.getExe built} --no-extensions --list-models pi-bolt-check > off.txt 2>&1 || true
  ! grep -q -- '${expected}' off.txt
  # The same patched plugin and its transitive runtime tool, loaded from the store instead of compiled in.
  ${lib.getExe' runtime "pi-bolt"} --list-models pi-bolt-check > runtime.txt 2>&1 || { cat runtime.txt; exit 1; }
  cat runtime.txt
  grep -q -- '${expected}' runtime.txt
  touch $out
''
