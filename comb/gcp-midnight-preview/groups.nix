# Fleet shape: one `group.new` per class of identical machines.
#
# hive-group turns each entry into instance00..instanceNN (one per IP) and
# generates the matching diskoConfigurations / hardwareProfiles / nixosModules
# / nixosProfiles / nixosConfigurations / colmenaConfigurations targets.
#
# Naming, for `prefix = "gcp-midnight-preview-"` and `groupName = "vali"` in
# this cell:
#   group key in ../group/*.nix    gcp-midnight-preview-vali
#   host key in ../host/*.nix      gcp-midnight-preview-vali-instance00
#   colmena node                   gcp-midnight-preview-vali-instance00
#   colmena tags                   @gcp-midnight-preview-vali-group-a,
#                                  @gcp-midnight-preview-group-a
#
# NB: the node name is `<cell>-<groupName>-instanceNN` — the cell directory
# name, not `prefix`. `prefix` only builds the group/host lookup keys and the
# fleet-wide tag, so the two have to agree: this cell is `gcp-midnight-preview`,
# so the prefix is `gcp-midnight-preview-`.
#
# The IPs below are colmena's SSH targets. They are placeholders — replace
# them with the real private addresses (or reachable DNS names) of the
# instances.
{
  inputs,
  cell,
  ...
}: let
  inherit (inputs.cells.lib.helpers) group;

  # hive-group asserts the prefix ends in "-".
  prefix = "gcp-midnight-preview-";
in {
  vali = group.new {
    inherit prefix;
    groupName = "vali";
    ips = [
      "10.0.0.11"
    ];
  };

  rpc = group.new {
    inherit prefix;
    groupName = "rpc";
    ips = [
      "10.0.0.12"
    ];
  };
}
