# cardano-node + cardano-cli, from the upstream linux-amd64 release tarball.
#
# These are statically linked Haskell binaries, so there is nothing to patchelf
# and nothing to strip — `dontFixup` keeps the release artifacts byte-identical.
#
# `share/<network>/` from this tarball is a consistent, version-matched config
# set (config.json, topology.json, *-genesis.json, checkpoints.json). Use it
# as-is rather than mixing in individually-fetched files from
# book.play.dev.cardano.org: that source drifts independently and the resulting
# mismatch (e.g. a GenesisMode config.json against an old topology.json, or a
# checkpoints hash the served file no longer matches) leaves the node unable to
# start. See ./cardano-configs.nix for the one file we do fetch.
{
  lib,
  stdenv,
  fetchurl,
  versions ? import ./versions.nix,
}: let
  spec = versions.cardano-node;
  url = builtins.replaceStrings ["@version@"] [spec.version] spec.urlTemplate;
in
  stdenv.mkDerivation {
    pname = "cardano-node-bin";
    inherit (spec) version;

    src = fetchurl {
      inherit url;
      inherit (spec) hash;
    };

    sourceRoot = ".";

    dontFixup = true;

    installPhase = ''
      runHook preInstall

      install -Dm0755 bin/cardano-node "$out/bin/cardano-node"
      install -Dm0755 bin/cardano-cli "$out/bin/cardano-cli"

      mkdir -p "$out/share"
      cp -r share/. "$out/share/"

      runHook postInstall
    '';

    meta = {
      description = "Cardano node and CLI (upstream static release binaries)";
      homepage = "https://github.com/IntersectMBO/cardano-node";
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      mainProgram = "cardano-node";
    };
  }
