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

  # Bootnodes. `publicAddr` is the one setting that cannot be defaulted: it is
  # the address peers dial, so it has to be the machine's externally reachable
  # one, and it belongs here rather than in a group profile for the same reason
  # the hostname does. Give it the reserved static IP (or the DNS name) the
  # Terraform stack assigns to this instance — `/dns4/<name>/tcp/30333/ws` is
  # the form upstream publishes, and matches the `--port 30333` the `boot`
  # node-type profile passes.
  #
  # The peer ID half of the multiaddr other nodes will use is *not* set here:
  # it comes from the node-key in this host's `-boot-node-keys` secret. Read it
  # off the running node (`journalctl -u midnight-node | grep 'Local node
  # identity'`) once the machine is up, and only then hand out the full
  # multiaddr.
  gcp-midnight-preview-boot-instance00 = {
    networking.hostName = "gcp-midnight-preview-boot-instance00";

    services.midnight-node = {
      nodeName = "gcp-midnight-preview-boot-0";
      publicAddr = "/dns4/REPLACE-ME-preview-bootnode-hostname/tcp/30333/ws";
    };
  };

  gcp-midnight-preprod-boot-instance00 = {
    networking.hostName = "gcp-midnight-preprod-boot-instance00";

    services.midnight-node = {
      nodeName = "gcp-midnight-preprod-boot-0";
      publicAddr = "/dns4/REPLACE-ME-preprod-bootnode-hostname/tcp/30333/ws";
    };
  };

  gcp-midnight-mainnet-boot-instance00 = {
    networking.hostName = "gcp-midnight-mainnet-boot-instance00";

    services.midnight-node = {
      nodeName = "gcp-midnight-mainnet-boot-0";
      publicAddr = "/dns4/REPLACE-ME-mainnet-bootnode-hostname/tcp/30333/ws";
    };
  };
}
