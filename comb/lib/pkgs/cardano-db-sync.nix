# cardano-db-sync, from the upstream linux release tarball.
#
# Statically linked, like cardano-node. `schema/` holds the SQL migrations
# db-sync applies to cexplorer on startup; it is passed via --schema-dir.
{
  lib,
  stdenv,
  fetchurl,
  versions ? import ./versions.nix,
}: let
  spec = versions.cardano-db-sync;
  url = builtins.replaceStrings ["@version@"] [spec.version] spec.urlTemplate;
in
  stdenv.mkDerivation {
    pname = "cardano-db-sync-bin";
    inherit (spec) version;

    src = fetchurl {
      inherit url;
      inherit (spec) hash;
    };

    sourceRoot = ".";

    dontFixup = true;

    installPhase = ''
      runHook preInstall

      install -Dm0755 bin/cardano-db-sync "$out/bin/cardano-db-sync"
      install -Dm0755 bin/cardano-db-tool "$out/bin/cardano-db-tool"

      mkdir -p "$out/share/cardano-db-sync"
      cp -r schema "$out/share/cardano-db-sync/schema"

      runHook postInstall
    '';

    passthru.schemaDir = "share/cardano-db-sync/schema";

    meta = {
      description = "Cardano DB Sync (upstream static release binary)";
      homepage = "https://github.com/IntersectMBO/cardano-db-sync";
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      mainProgram = "cardano-db-sync";
    };
  }
