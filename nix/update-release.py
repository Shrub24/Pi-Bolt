#!/usr/bin/env python3
"""Pins nix/release.json to a Pi-Bolt release: the files the Nix build compiles with, by the hashes the release signed.

The Nix build compiles Pi-Bolt as `pi-bolt compile` does, from a release's compile kit and runtime, and takes the
release's own folder for the files beside the executable (docs, themes, native modules). This script reads the release's
SHA256SUMS, checks its signature by keys/release.pub (as the installers and `pi-bolt compile` do) and that its first line
names the version, and writes those files' hashes.

Usage: nix/update-release.py [--root DIR] [VERSION]     (default: this repository, and its VERSION file)
Needs: openssl (the signature), and network access to the release.

--root is what the flake app (nix run .#update-release) uses: it runs this script from the store, so the checkout to write
into is the caller's, not the script's own directory.
"""

import json
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASES = "https://github.com/opensec-git/Pi-Bolt/releases/download"
# The platforms the flake builds on, as release files name them. (darwin-arm64 has a kit too; its launcher is not packaged yet.)
PLATFORMS = ["linux-x64", "linux-arm64"]


def parse_args(argv: list) -> "tuple[pathlib.Path, str | None]":
    root, version = ROOT, None
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--root" or arg.startswith("--root="):
            value = arg.split("=", 1)[1] if "=" in arg else (args.pop(0) if args else None)
            if not value:
                sys.exit("error: --root needs a directory")
            root = pathlib.Path(value).resolve()
        elif version is None:
            version = arg
        else:
            sys.exit(f"error: unexpected argument {arg}")
    if not (root / "keys/release.pub").is_file():
        sys.exit(f"error: {root} does not look like a Pi-Bolt checkout (no keys/release.pub)")
    return root, version


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as response:
        return response.read()


def main() -> None:
    root, version = parse_args(sys.argv[1:])
    if version is None:
        version = (root / "VERSION").read_text().strip()
    base = f"{RELEASES}/bolt-v{version}"
    sums = fetch(f"{base}/SHA256SUMS")
    signature = fetch(f"{base}/SHA256SUMS.sig")
    with tempfile.TemporaryDirectory() as tmp:
        (pathlib.Path(tmp) / "sums").write_bytes(sums)
        (pathlib.Path(tmp) / "sig").write_bytes(signature)
        check = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(root / "keys/release.pub"), "-rawin",
             "-in", f"{tmp}/sums", "-sigfile", f"{tmp}/sig"],
            capture_output=True, text=True,
        )
    if check.returncode != 0:
        sys.exit(f"error: the signature of {base}/SHA256SUMS does not verify: {check.stdout}{check.stderr}")
    lines = sums.decode().splitlines()
    if lines[0] != f"# pi-bolt {version}":
        sys.exit(f"error: the checksums are not Pi-Bolt {version}'s (they begin {lines[0]!r})")
    sha = {}
    for line in lines[1:]:
        digest, _, name = line.partition("  ")
        if name:
            sha[name.strip()] = digest

    stamp = fetch(f"{base}/RUNTIME_STAMP").decode().strip()
    if sha.get("RUNTIME_STAMP") and len(stamp) != 16:
        sys.exit(f"error: RUNTIME_STAMP is not a stamp: {stamp!r}")

    platforms = {}
    for platform in PLATFORMS:
        files = {
            "kit": f"pi-bolt-kit-{platform}.tar.gz",
            "runtime": f"pi-bolt-runtime-{platform}.tar.gz",
            # Only for what lies beside the executable, which is the same in every variant of a platform.
            "release": f"pi-bolt-{platform}.tar.xz",
        }
        missing = [name for name in files.values() if name not in sha]
        if missing:
            sys.exit(f"error: release {version} has no {', '.join(missing)}")
        platforms[platform] = {key: {"name": name, "sha256": sha[name]} for key, name in files.items()}

    pin = {"version": version, "runtimeStamp": stamp, "platforms": platforms}
    (root / "nix/release.json").write_text(json.dumps(pin, indent=2) + "\n")
    print(f"nix/release.json: Pi-Bolt {version}")


if __name__ == "__main__":
    main()
