# Pi-Bolt, with the plugins a Nix expression chooses compiled in.
#
#   pi-bolt                                         the release's build, compiled for this system
#   pi-bolt.withPlugins (ps: [ ps.word-count ])     with plugins compiled in (from piBoltPlugins, or built anywhere)
#   pi-bolt.override { jit = true; }                the JIT build (docs/PLUGINS.md: for extensions loaded at run time)
#
# It builds as `pi-bolt compile` does (packages/coding-agent/src/pi-bolt-compile.ts): from the release's compile kit and runtime,
# with no build of Pi. nix/release.json pins the release (nix/update-release.py). The compiled executable is `unwrapped`; this
# package is a copy of it with the launcher, so that a launcher change (PATH, runtimeInputs) does not compile again, and the
# launcher and the executable it runs are in one store path (process.execPath is where Pi-Bolt finds its assets).
args@{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  writeText,
  python3,
  patchelf,
  autoPatchelfHook,
  makeBinaryWrapper,
  callPackage,
  libxcb,
  ripgrep,
  fd,
  piBoltPlugins,

  # Plugins to compile in: buildPiBoltPlugin derivations. Each is a built-in extension, builtin:<name>.
  plugins ? [ ],
  # The JIT build: compiled code as always, and run-time loaded extensions JIT-compiled too.
  jit ? false,
  # The largest module (top-level bytecode, in bytes) the AOT compiler takes. The compiler names the module it refused; raise
  # this for it (docs/PLUGINS.md, "A large module").
  maxAotCandidateBytecodeSize ? null,
  # Programs Pi finds in PATH rather than downloading: rg and fd for its grep and find tools. Add wl-clipboard or xclip for
  # the clipboard.
  runtimeInputs ? [
    ripgrep
    fd
  ],
}:
stdenvNoCC.mkDerivation (
  finalAttrs:
  let
    pin = lib.importJSON ./release.json;
    inherit (pin) version;

    platform =
      {
        x86_64-linux = "linux-x64";
        aarch64-linux = "linux-arm64";
      }
      .${stdenv.hostPlatform.system}
        or (throw "pi-bolt: no Nix build for ${stdenv.hostPlatform.system} yet");
    arch = lib.last (lib.splitString "-" platform);
    release = lib.mapAttrs (
      _: file:
      fetchurl {
        url = "https://github.com/opensec-git/Pi-Bolt/releases/download/bolt-v${version}/${file.name}";
        inherit (file) sha256;
      }
    ) pin.platforms.${platform};

    # As release files name the variants (scripts/build-pi.sh, CPU_VARIANT). Every build here is the baseline one: code tuned for
    # its builder's CPU could not be shared or substituted, and the derivation would have to name that CPU.
    variant =
      if jit then
        "${arch}-jit"
      else if arch == "x64" then
        "x64-baseline"
      else
        arch;

    # Deduplicate identical derivations, not names: different patched versions must not silently replace one another.
    closure = builtins.genericClosure {
      startSet = map (plugin: {
        key = toString plugin;
        inherit plugin;
      }) finalAttrs.plugins;
      operator =
        { plugin, ... }:
        map (dep: {
          key = toString dep;
          plugin = dep;
        }) plugin.piBolt.dependencies;
    };
    byName = lib.groupBy (
      { plugin, ... }:
      plugin.piBolt.name
        or (throw "pi-bolt: ${plugin.name or "a plugin"} is not a buildPiBoltPlugin derivation")
    ) closure;
    conflicts = lib.attrNames (lib.filterAttrs (_: entries: lib.length entries > 1) byName);
    checkedClosure =
      assert lib.assertMsg (
        conflicts == [ ]
      ) "pi-bolt: different plugin derivations share a name: ${lib.concatStringsSep ", " conflicts}";
      closure;
    registered = map (plugin: plugin.piBolt.name) finalAttrs.plugins;

    plan = writeText "pi-bolt-plugins.json" (
      builtins.toJSON {
        plugins = map (
          { plugin, ... }:
          {
            name = plugin.piBolt.name;
            src = "${plugin}";
            register = lib.elem plugin.piBolt.name registered;
            inherit (plugin.piBolt)
              entry
              packageName
              builtin
              workers
              ;
            deps = map (dep: dep.piBolt.name) plugin.piBolt.dependencies;
          }
        ) checkedClosure;
      }
    );

    unwrapped = stdenv.mkDerivation {
      pname = "pi-bolt-unwrapped";
      inherit version;

      dontUnpack = true;
      nativeBuildInputs = [
        python3
        patchelf
        autoPatchelfHook
      ];
      # The native module Pi's TUI loads to read the keyboard's modifiers under X11.
      buildInputs = [ libxcb ];

      buildPhase = ''
        runHook preBuild
        export HOME=$TMPDIR
        mkdir kit runtime
        tar -xzf ${release.kit} -C kit --strip-components=1
        tar -xzf ${release.runtime} -C runtime --strip-components=1
        chmod -R u+w kit
        # Before compiling: rewriting the compiled executable would damage its AOT image.
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" runtime/bun
        ${lib.optionalString (maxAotCandidateBytecodeSize != null) ''
          export BUN_JSC_maximumAOTCandidateBytecodeSize=${toString maxAotCandidateBytecodeSize}
        ''}
        python3 ${./build.py} --kit kit --bun runtime/bun --plan ${plan} --out pi \
          --version ${version} --variant ${variant} --jit ${if jit then "on" else "off"} --cpu baseline \
          --runtime-stamp ${pin.runtimeStamp}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # What lies beside the executable (Pi's docs, themes, native modules) is the release's.
        # No launcher here: a launcher sets PATH, and this output is what a consumer wraps or copies.
        mkdir -p $out/lib/pi-bolt
        tar -xJf ${release.release} -C $out/lib/pi-bolt --strip-components=1
        install -m755 pi $out/lib/pi-bolt/pi
        {
          head -n1 $out/lib/pi-bolt/pi-bolt.txt
          echo "Built with Nix: ${variant}${
            lib.optionalString (
              registered != [ ]
            ) ", plugins compiled in: ${lib.concatStringsSep ", " registered}"
          }"
        } > pi-bolt.txt
        mv pi-bolt.txt $out/lib/pi-bolt/pi-bolt.txt
        runHook postInstall
      '';

      # The executable is an AOT image: stripping or patching it damages it. Only the native modules are patched.
      dontStrip = true;
      dontPatchELF = true;
      dontAutoPatchelf = true;
      postFixup = ''
        autoPatchelf $out/lib/pi-bolt/native
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        # As build-pi.sh checks: it runs, as this version, from its compiled code.
        said=$(HOME=$TMPDIR BUN_STATIC_HEAP_VERBOSE=1 $out/lib/pi-bolt/pi --version 2>&1)
        printf '%s\n' "$said"
        grep -q 'image registered: true' <<< "$said"
        grep -q 'Pi-Bolt ${version},' <<< "$said"
        runHook postInstallCheck
      '';

      passthru = {
        inherit plan variant;
        plugins = finalAttrs.plugins;
        runtimeInputs = toolInputs;
      };
      meta = meta // {
        description = "${meta.description} (the compiled executable, without its launcher)";
      };
    };

    toolInputs = lib.unique (
      runtimeInputs ++ lib.concatMap (plugin: plugin.piBolt.runtimeInputs) finalAttrs.plugins
    );

    meta = {
      description = "Pi, the coding agent, compiled ahead of time";
      homepage = "https://github.com/opensec-git/Pi-Bolt";
      license = lib.licenses.mit;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      # The kit is Pi's built JavaScript and the runtime its patched Bun: neither is built here from source.
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  in
  {
    pname = "pi-bolt";
    inherit version plugins;

    dontUnpack = true;
    nativeBuildInputs = [ makeBinaryWrapper ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/bin
      cp -r ${unwrapped}/lib/pi-bolt $out/lib/pi-bolt
      chmod -R u+w $out/lib/pi-bolt
      # A binary wrapper costs one exec and leaves process.execPath alone, so assets still resolve.
      # PATH only: the package does not touch argv, so a launch is Pi's own.
      makeBinaryWrapper $out/lib/pi-bolt/pi $out/bin/pi-bolt \
        ${lib.optionalString (toolInputs != [ ]) "--prefix PATH : ${lib.makeBinPath toolInputs}"}
      ln -s pi-bolt $out/bin/pi
      runHook postInstall
    '';

    dontStrip = true;
    dontPatchELF = true;

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      said=$(HOME=$TMPDIR BUN_STATIC_HEAP_VERBOSE=1 $out/bin/pi --version 2>&1)
      grep -q 'image registered: true' <<< "$said"
      runHook postInstallCheck
    '';

    passthru = {
      inherit unwrapped;
      plugins = finalAttrs.plugins;
      runtimeInputs = toolInputs;
      # Through callPackage again, so that the result carries `override` too: `(pi-bolt.withPlugins f).override { jit = true; }`.
      withPlugins = select: callPackage ./package.nix (args // { plugins = select piBoltPlugins; });
    };

    meta = meta // {
      mainProgram = "pi-bolt";
    };
  }
)
