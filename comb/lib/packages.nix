# The node binaries as a cell block, so they can be built and inspected on
# their own:
#
#   nix build .#x86_64-linux.lib.packages.midnight-node
#   nix build .#x86_64-linux.lib.packages.cardano-configs-preview
#
# Hosts do not consume these directly — they get the same derivations through
# the overlay applied in ./helpers.nix.
{
  inputs,
  cell,
  ...
}: let
  pkgs = inputs.nixpkgs;
  inherit (pkgs) lib;

  set = import ./pkgs {inherit pkgs;};
in
  {
    inherit (set) midnight-node midnight-fetch-secrets cardano-node-bin cardano-db-sync-bin;
  }
  # cardano-configs is keyed by network; flatten it, since a paisano block
  # target has to be a derivation rather than a nested attrset.
  // lib.mapAttrs'
  (network: drv: lib.nameValuePair "cardano-configs-${network}" drv)
  set.cardano-configs
