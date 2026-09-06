# Fleet shape: one `group.new` per class of identical machines.
#
# The network is part of the cell name, so each Midnight network is its own
# fleet cell. This one carries the mainnet bootnode; add `vali` / `rpc` groups
# here (and keys in ../group/*.nix) if this network grows other node types.
#
# hive-group turns each entry into instance00..instanceNN (one per IP) and
# generates the matching diskoConfigurations / hardwareProfiles / nixosModules
# / nixosProfiles / nixosConfigurations / colmenaConfigurations targets.
#
# Naming, for `prefix = "gcp-midnight-mainnet-"` and `groupName = "boot"` in
# this cell:
#   group key in ../group/*.nix    gcp-midnight-mainnet-boot
#   host key in ../host/*.nix      gcp-midnight-mainnet-boot-instance00
#   colmena node                   gcp-midnight-mainnet-boot-instance00
#   colmena tags                   @gcp-midnight-mainnet-boot-group-a,
#                                  @gcp-midnight-mainnet-group-a
#
# NB: the node name is `<cell>-<groupName>-instanceNN` — the cell directory
# name, not `prefix`. `prefix` only builds the group/host lookup keys and the
# fleet-wide tag, so the two have to agree: this cell is `gcp-midnight-mainnet`,
# so the prefix is `gcp-midnight-mainnet-`.
#
# The IP below is colmena's SSH target. It is a placeholder — replace it with
# the real private address (or a reachable DNS name) of the instance. The
# address *peers* dial is a different setting: `publicAddr`, in
# ../host/nixosProfiles.nix.
{
  inputs,
  cell,
  ...
}: let
  inherit (inputs.cells.lib.helpers) group;

  # hive-group asserts the prefix ends in "-".
  prefix = "gcp-midnight-mainnet-";
in {
  boot = group.new {
    inherit prefix;
    groupName = "boot";
    ips = [
      "10.2.0.11"
    ];
  };
}
