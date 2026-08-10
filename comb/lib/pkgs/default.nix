# The package set, as a plain callPackage scope.
#
# Consumed two ways:
#   - ./overlay.nix, so NixOS modules can just say `pkgs.midnight-node`
#   - comb/lib/packages.nix, so `nix build .#midnight-node` works
{pkgs}: let
  inherit (pkgs) callPackage;
in rec {
  midnight-node = callPackage ./midnight-node.nix {};
  midnight-fetch-secrets = callPackage ./midnight-fetch-secrets.nix {};
  cardano-node-bin = callPackage ./cardano-node.nix {};
  cardano-db-sync-bin = callPackage ./cardano-db-sync.nix {};

  # Attrset keyed by network: cardano-configs.preview, .preprod, .mainnet.
  #
  # Imported directly rather than via callPackage: callPackage wraps its result
  # with makeOverridable, and for an attrset-of-derivations that means bogus
  # `override` / `overrideDerivation` entries showing up as if they were
  # networks.
  cardano-configs = import ./cardano-configs.nix {
    inherit (pkgs) lib runCommand fetchurl jq;
    inherit cardano-node-bin;
  };
}
