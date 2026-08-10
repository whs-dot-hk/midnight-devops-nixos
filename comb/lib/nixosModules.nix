# The reusable modules: they declare the interface (options) for the stack.
#
# Profiles in ./nixosProfiles.nix set values on this interface; groups in
# ../group pick which combination a class of machines gets.
#
# Kept as plain paths under ./modules so they stay importable from a vanilla
# NixOS configuration, with no hive involved.
{
  inputs,
  cell,
  ...
}: {
  common = ./modules/common.nix;
  midnight-node = ./modules/midnight-node.nix;
  cardano-node = ./modules/cardano-node.nix;
  cardano-db-sync = ./modules/cardano-db-sync.nix;
  gcp-secrets = ./modules/gcp-secrets.nix;
  gcp-ops-agent = ./modules/gcp-ops-agent.nix;
}
