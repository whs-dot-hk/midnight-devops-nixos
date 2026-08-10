# Per-machine overrides.
#
# hive-group looks up `<prefix><group>-instanceNN` here for every instance and
# imports it if present, so a host that needs nothing can simply be omitted.
#
# The hostname matters beyond cosmetics: ../group/nixosProfiles.nix derives
# each node's Secret Manager IDs from `config.networking.hostName`, following
# the `<node>-secrets` / `<node>-validator-keys` naming.
{
  inputs,
  cell,
  ...
}: {
  gcp-midnight-preview-vali-instance00 = {
    networking.hostName = "gcp-midnight-preview-vali-instance00";

    # Label shown on the telemetry board.
    services.midnight-node.nodeName = "gcp-midnight-preview-vali-0";
  };

  gcp-midnight-preview-rpc-instance00 = {
    networking.hostName = "gcp-midnight-preview-rpc-instance00";

    services.midnight-node.nodeName = "gcp-midnight-preview-rpc-0";
  };
}
