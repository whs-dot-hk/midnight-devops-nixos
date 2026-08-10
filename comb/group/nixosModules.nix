# Which modules each group of machines gets — the interface half.
#
# Values for these options are set in ./nixosProfiles.nix.
{
  inputs,
  cell,
  ...
}: let
  m = inputs.cells.lib.nixosModules;

  # Every Midnight node runs the same five modules. cardano-node,
  # cardano-db-sync and gcp-ops-agent stay inert unless a profile enables them,
  # so a relay importing them costs nothing.
  stack = {
    imports = [
      m.common
      m.midnight-node
      m.cardano-node
      m.cardano-db-sync
      m.gcp-secrets
      m.gcp-ops-agent
    ];
  };
in {
  gcp-midnight-preview-vali = stack;
  gcp-midnight-preview-rpc = stack;
}
