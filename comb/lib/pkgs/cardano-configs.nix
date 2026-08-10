# Per-network Cardano config directory, assembled at build time.
#
# Assembling it in a derivation rather than on every boot with jq + curl means
# the config is pinned, identical on every node, and a bad upstream change fails
# the build rather than a running node.
#
# The result directory contains, for network N:
#   config.json          — from the cardano-node tarball, prometheus + P2P patched
#   topology.json        — from the tarball, untouched
#   *-genesis.json       — from the tarball, untouched
#   db-sync-config.json  — fetched separately (not shipped in the tarball)
#
# db-sync-config.json refers to the node config as a *relative* path
# ("NodeConfigFile": "config.json"), which db-sync resolves against the
# directory holding db-sync-config.json — so both must sit together, as here.
{
  lib,
  runCommand,
  fetchurl,
  jq,
  cardano-node-bin,
  versions ? import ./versions.nix,
  # Address:port cardano-node's prometheus endpoint binds to. The metrics
  # firewall rule in the nixos profile follows this port.
  prometheusListen ? ["0.0.0.0" 12798],
}: let
  networks = ["preview" "preprod" "mainnet"];

  dbSyncConfig = network:
    fetchurl {
      url = "https://book.play.dev.cardano.org/environments/${network}/db-sync-config.json";
      hash = versions.db-sync-config.${network};
    };

  # Null-safe on purpose: newer bundled configs use legacy tracing, where
  # .TraceOptions[""] is absent. Iterating .backends without `[]?` makes jq
  # abort with "Cannot iterate over null", which would silently leave the
  # prometheus/P2P settings unapplied and metrics unbound.
  patch = ''
    del(.TraceOptions[""].backends[]? | select(startswith("PrometheusSimple")))
    | .hasPrometheus = ${builtins.toJSON prometheusListen}
    | .EnableP2P = true
  '';

  mkConfig = network:
    runCommand "cardano-configs-${network}-${cardano-node-bin.version}" {
      nativeBuildInputs = [jq];
      meta.description = "Cardano ${network} node + db-sync configuration";
    } ''
      mkdir -p "$out"
      cp -r ${cardano-node-bin}/share/${network}/. "$out/"
      chmod -R u+w "$out"

      jq ${lib.escapeShellArg patch} \
        ${cardano-node-bin}/share/${network}/config.json > "$out/config.json"

      cp ${dbSyncConfig network} "$out/db-sync-config.json"
    '';
in
  lib.genAttrs networks mkConfig
