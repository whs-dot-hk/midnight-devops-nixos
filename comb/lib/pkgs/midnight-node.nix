# midnight-node, from the upstream linux-amd64 release tarball.
#
# The binary is a dynamically-linked PIE (libssl.so.3, libcrypto.so.3,
# libgcc_s, libm, libc), so it needs autoPatchelfHook. The tarball also ships
# `res/`, which holds the per-network chain specs and config presets the node
# reads at runtime (`res/<network>/chain-spec-raw.json`).
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  openssl,
  versions ? import ./versions.nix,
}: let
  spec = versions.midnight-node;
  url = builtins.replaceStrings ["@version@"] [spec.version] spec.urlTemplate;
in
  stdenv.mkDerivation {
    pname = "midnight-node";
    inherit (spec) version;

    src = fetchurl {
      inherit url;
      inherit (spec) hash;
    };

    # The archive has no single root directory: `midnight-node` and `res/` sit
    # side by side at the top level.
    sourceRoot = ".";

    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [
      (lib.getLib stdenv.cc.cc)
      openssl
    ];

    installPhase = ''
      runHook preInstall

      install -Dm0755 midnight-node "$out/bin/midnight-node"

      mkdir -p "$out/share/midnight-node"
      cp -r res "$out/share/midnight-node/res"

      runHook postInstall
    '';

    meta = {
      description = "Midnight partner-chain node (upstream release binary)";
      homepage = "https://github.com/midnightntwrk/midnight-node";
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      mainProgram = "midnight-node";
    };
  }
