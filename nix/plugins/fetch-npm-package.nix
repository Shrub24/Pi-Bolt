# fetchNpmPackage: one package from the npm registry, unpacked: the source of a plugin published to npm, or a library a plugin
# imports.
#
#   fetchNpmPackage { pname = "@narumitw/pi-tui-kit"; version = "0.65.5"; hash = "sha512-..."; }
#
# The hash is the registry's own (`npm view <pname>@<version> dist.integrity`), or any SRI hash of the tarball.
{
  lib,
  fetchurl,
  stdenvNoCC,
}:
{
  pname,
  version,
  hash,
  # The registry to fetch from.
  registry ? "https://registry.npmjs.org",
}:
stdenvNoCC.mkDerivation {
  pname = lib.strings.sanitizeDerivationName (lib.removePrefix "@" pname);
  inherit version;
  src = fetchurl {
    url = "${registry}/${pname}/-/${lib.last (lib.splitString "/" pname)}-${version}.tgz";
    inherit hash;
  };
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    cp -r . $out
    runHook postInstall
  '';
  passthru.packageName = pname;
}
