#!/usr/bin/env python3
"""The Nix build of Pi-Bolt: `pi-bolt compile` (packages/coding-agent/src/pi-bolt-compile.ts), with the plugins a Nix
expression chose instead of the ones installed on a machine.

It stages each plugin into the compile kit's tree, as scripts/lib/common.sh's stage_plugins does, writes the manifest and the
entry point, and runs the kit's compile command with the release's runtime.

Usage: build.py --kit DIR --bun FILE --plan FILE --out FILE --version V --variant V --jit on|off --cpu native|baseline
                [--runtime-stamp STAMP]

  --kit DIR   an unpacked, writable compile kit (pi-bolt-kit-<platform>)
  --plan FILE JSON written by nix/package.nix:
              { "plugins": [ { "name", "src", "entry", "register", "builtin", "packageName", "deps", "workers" } ] }
              Every plugin in the closure is staged; only those with "register" are named in the manifest (the others are
              there to be imported).
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

# The packages Pi provides to extensions (scripts/make-kit.mjs, PROVIDED): a plugin imports them from Pi, and a copy in its
# node_modules would be a second Pi (duplicate classes and registries), so none is staged.
PROVIDED = re.compile(r"^(@earendil-works/pi-[^/]+|typebox)$")
KIT_FOLDER = "@KIT@"


def die(message: str) -> None:
    sys.stderr.write(f"error: {message}\n")
    sys.exit(1)


def stage_plugin(plugin: dict, by_name: dict, src_root: pathlib.Path) -> pathlib.Path:
    """Copies a plugin's tree into the kit, without the plugin dependencies it links in node_modules (relinked below to their
    own staged copies, so each module is compiled once) and without any copy of Pi."""
    dest = src_root / plugin["name"]
    source = pathlib.Path(plugin["src"])
    dep_packages = {by_name[dep]["packageName"] for dep in plugin["deps"] if by_name[dep].get("packageName")}

    def ignore(directory: str, names: list) -> set:
        skipped = {".git"} & set(names)
        parts = pathlib.Path(directory).relative_to(source).parts
        # node_modules/<name> and node_modules/@scope/<name>, at any depth; dependency links only in the plugin's own.
        if parts and parts[-1] == "node_modules":
            scope, own = None, len(parts) == 1
        elif len(parts) >= 2 and parts[-2] == "node_modules" and parts[-1].startswith("@"):
            scope, own = parts[-1], len(parts) == 2
        else:
            return skipped
        for name in names:
            package = f"{scope}/{name}" if scope else name
            if PROVIDED.match(package) or (own and package in dep_packages):
                skipped.add(name)
        return skipped

    # (Symlinks followed: a plugin's node_modules are links into the store, and the bundler resolves a link to where it
    # points, which would be outside the kit's tree, where Pi's packages do not resolve.)
    shutil.copytree(source, dest, symlinks=False, ignore=ignore, ignore_dangling_symlinks=True)
    for path in [dest, *dest.rglob("*")]:
        if not path.is_symlink():
            path.chmod(path.stat().st_mode | 0o200)

    check_package_name(plugin, dest)

    for dep in plugin["deps"]:
        package = by_name[dep].get("packageName")
        if not package:
            continue
        # (Nothing to replace: the copy above skipped this exact path for a plugin dependency.)
        link = dest / "node_modules" / package
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(os.path.relpath(src_root / dep, link.parent))
    return dest


def check_package_name(plugin: dict, dest: pathlib.Path) -> None:
    """A declared packageName is how other plugins import this one, so a mismatch with its own package.json would link the
    wrong module: the dependency would resolve to a name this plugin does not answer to."""
    declared = plugin.get("packageName")
    manifest = dest / "package.json"
    if not declared or not manifest.is_file():
        return
    try:
        actual = json.loads(manifest.read_text()).get("name")
    except json.JSONDecodeError as error:
        die(f"{plugin['name']}: package.json is not JSON: {error}")
    if isinstance(actual, str) and actual != declared:
        die(
            f"{plugin['name']}: packageName is {declared!r} but its package.json names {actual!r};"
            f" a plugin importing it as {declared!r} would link the wrong module"
        )


def write_manifest(stage: pathlib.Path, plugins: list) -> None:
    registered = [p for p in plugins if p["register"]]
    imports = "".join(f'import plugin_{i} from "./{p["name"]}/{p["entry"]}";\n' for i, p in enumerate(registered))

    def row(i, p):
        # A named plugin is a built-in extension, builtin:<name> (scripts/lib/common.sh, stage_plugins).
        builtin = "true" if p["builtin"] else "false"
        return f'\t{{ name: {json.dumps(p["name"])}, factory: plugin_{i}, builtin: {builtin}, replaceable: true }},\n'

    (stage / "src" / "plugins.ts").write_text(
        "// Generated by nix/build.py: the plugins a Nix expression compiles into Pi-Bolt.\n"
        'import type { InlineExtension } from "@earendil-works/pi-coding-agent";\n'
        f"{imports}\n"
        f"const plugins: InlineExtension[] = [\n{''.join(row(i, p) for i, p in enumerate(registered))}];\n\n"
        "export default plugins;\n"
    )
    # Pi's Bun entry (packages/coding-agent/src/bun/cli.ts), with the plugins passed to main(), as stage_plugins writes it.
    (stage / "entry.ts").write_text(
        "// Generated by nix/build.py: Pi's Bun entry, with extensions compiled in.\n"
        'import "../dist/bun/sandbox-env-setup.js";\n'
        'import "../dist/bun/version-fast-path.js";\n'
        'import "../dist/bun/runtime-setup.js";\n'
        'import { setupCli } from "../dist/cli/setup.js";\n'
        'import { main } from "../dist/main.js";\n'
        'import plugins from "./src/plugins.ts";\n\n'
        "setupCli();\n"
        "main(process.argv.slice(2), { extensionFactories: plugins });\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    for name in ["kit", "bun", "plan", "out", "version", "variant", "jit", "cpu"]:
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--runtime-stamp", default="")
    options = parser.parse_args()
    jit = options.jit == "on"

    kit_dir = pathlib.Path(options.kit).resolve()
    bun = str(pathlib.Path(options.bun).resolve())
    out_file = str(pathlib.Path(options.out).resolve())
    kit = json.loads((kit_dir / "kit.json").read_text())
    if kit["piBolt"] != options.version:
        die(f"the kit is for Pi-Bolt {kit['piBolt']}, and this is a build of {options.version}")
    agent = kit_dir / kit["agent"]
    plan = json.loads(pathlib.Path(options.plan).read_text())
    plugins = plan["plugins"]
    by_name = {p["name"]: p for p in plugins}

    entries = list(kit["entries"])
    if plugins:
        stage = agent / ".pibolt-plugins"
        shutil.rmtree(stage, ignore_errors=True)
        (stage / "src").mkdir(parents=True)
        for plugin in plugins:
            dest = stage_plugin(plugin, by_name, stage / "src")
            for worker in plugin["workers"]:
                if not (dest / worker).is_file():
                    die(f"{plugin['name']}: worker {worker} not found")
                entries.append(f"./.pibolt-plugins/src/{plugin['name']}/{worker}")
        write_manifest(stage, plugins)
        entries[0] = "./.pibolt-plugins/entry.ts"

    # The kit's environment is the release's default build; the variant's JIT and CPU are this build's (as pi-bolt compile).
    env = dict(os.environ)
    for name, value in kit["env"].items():
        env[name] = value.replace(KIT_FOLDER, str(kit_dir))
    env.pop("BUN_AOT_JIT", None)
    env.pop("BUN_AOT_CPU", None)
    if not jit:
        env["BUN_AOT_JIT"] = "0"
    if options.cpu == "baseline":
        env["BUN_AOT_CPU"] = "baseline"
    for name in ["BUN_BE_BUN", "BUN_INTERNAL_SPAWN_HELPER"]:
        env.pop(name, None)

    stamp = f" {options.runtime_stamp}" if options.runtime_stamp else ""
    args = [arg.replace(KIT_FOLDER, str(kit_dir)) for arg in kit["args"]]
    args += ["--define", f'PIBOLT_BUILD="{options.version} {options.variant} jit-{options.jit}{stamp}"']
    args += entries + ["--outfile", out_file]
    registered = [p["name"] for p in plugins if p["register"]]
    print(f"compiling Pi {kit['pi']} (Pi-Bolt {options.version} {options.variant}) with {len(registered)} plugin(s)"
          f"{': ' + ', '.join(registered) if registered else ''}", file=sys.stderr)
    log = pathlib.Path(env.get("TMPDIR", "/tmp")) / "pi-bolt-build.log"
    with open(log, "w") as out:
        result = subprocess.run([bun, *args], cwd=agent, env=env, stdout=out, stderr=subprocess.STDOUT)
    if result.returncode != 0 or not pathlib.Path(out_file).exists():
        lines = log.read_text(errors="replace").splitlines()
        # The reason is often an "AOT: " line (scripts/build-pi.sh): the compiler's last words, with those.
        sys.stderr.write("\n".join(lines[-40:]) + "\n")
        die("the build stopped (the compiler's last 40 lines are above)")


if __name__ == "__main__":
    main()
