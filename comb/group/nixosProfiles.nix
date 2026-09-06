# Per-group values.
#
# This is the one file in the repo that carries deployment-specific
# configuration: which GCP project, which database endpoint, which secrets.
# None of it is confidential — secrets are referenced by *ID*, and the values
# themselves are fetched at boot straight into 0600 files (see
# ../lib/modules/gcp-secrets.nix).
#
# Everything marked REPLACE-ME must be pointed at your own infrastructure
# before a deploy will do anything useful.
{
  inputs,
  cell,
  ...
}: let
  p = inputs.cells.lib.nixosProfiles;
  inherit (inputs.cells.lib.helpers) secretIds;

  # GCP project holding the instances and their secrets.
  project = "REPLACE-ME-gcp-project";

  # Cloud SQL private endpoint cardano-db-sync writes cexplorer to. The
  # Terraform stack creates one instance per node, and a node on one network
  # has no business reading another's cexplorer, so this is per network.
  postgresHosts = {
    preview = "REPLACE-ME-cloudsql-private-ip-preview";
    preprod = "REPLACE-ME-cloudsql-private-ip-preprod";
    mainnet = "REPLACE-ME-cloudsql-private-ip-mainnet";
  };

  dbHost = network: {
    services.cardano-db-sync.database.host = postgresHosts.${network};
  };

  # Platform and observability: true of every machine in this repo, whatever
  # it runs and whichever chain it is on.
  platform = [
    p.common
    p.gcp
    p.metrics
    p.ops-agent
  ];

  # Secret IDs are derived from the node's hostname, so a new instance needs no
  # extra wiring here. See ../lib/helpers.nix for the naming arguments.
  #
  # NB: the hostname set in ../host/nixosProfiles.nix already carries the full
  # `gcp-midnight-<network>-` naming — adding a prefix here doubles it.
  nodeSecretIds = config:
    secretIds {
      base = config.networking.hostName;
    };

  # Node types other than validator have no use for the validator keys.
  baseSecrets = config: let
    ids = nodeSecretIds config;
  in {
    inherit (ids) node db;
  };

  # Preview-network nodes, minus the node-type profile.
  previewBase =
    platform
    ++ [
      p.midnight-stack
      p.network-preview
      (dbHost "preview")
    ];

  # A bootnode group, one per network. `p.boot-<network>` is the whole node —
  # stack, network and the `boot` node type — so all that is left here is the
  # deployment's own half: project, database endpoint, secret IDs.
  #
  # `bootNodeKeys` is the one that matters: it carries the node-key that fixes
  # this machine's peer ID, which is the identity every other node has in its
  # --bootnodes list. No validator keys and no seed phrases — a bootnode does
  # not author blocks.
  #
  # The peer ID a group advertises, and the address it is reachable at, are
  # per-machine: see `publicAddr` in ../host/nixosProfiles.nix.
  bootGroup = network: {config, ...}: {
    imports =
      platform
      ++ [
        p."boot-${network}"
        (dbHost network)
      ];

    midnight.gcp = {
      enable = true;
      inherit project;
      secrets =
        (baseSecrets config)
        // {
          inherit (nodeSecretIds config) bootNodeKeys;
        };
    };
  };
in {
  gcp-midnight-preview-vali = {config, ...}: {
    imports = previewBase ++ [p.node-validator];

    midnight.gcp = {
      enable = true;
      inherit project;
      secrets =
        (baseSecrets config)
        // {
          inherit (nodeSecretIds config) validatorKeys validatorSeedPhrases;
        };
    };
  };

  gcp-midnight-preview-rpc = {config, ...}: {
    imports = previewBase ++ [p.node-rpc];

    midnight.gcp = {
      enable = true;
      inherit project;
      secrets = baseSecrets config;
    };

    # The deliberate exposure decision: bind JSON-RPC to 0.0.0.0. Leave this
    # false unless the endpoint is genuinely meant to be public, and prefer an
    # explicit origin list over "all".
    services.midnight-node.rpc = {
      external = true;
      cors = "all";
    };
  };

  gcp-midnight-preview-boot = bootGroup "preview";
  gcp-midnight-preprod-boot = bootGroup "preprod";
  gcp-midnight-mainnet-boot = bootGroup "mainnet";
}
