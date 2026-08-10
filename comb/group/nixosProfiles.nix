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
  # Terraform stack creates one instance per node, so this is per group.
  postgresHost = "REPLACE-ME-cloudsql-private-ip";

  # Settings shared by every group in this repo.
  shared = {
    services.cardano-db-sync.database.host = postgresHost;
  };

  # Secret IDs are derived from the node's hostname, so a new instance needs no
  # extra wiring here. See ../lib/helpers.nix for the naming arguments.
  #
  # NB: the hostname set in ../host/nixosProfiles.nix already carries the full
  # `gcp-midnight-preview-` naming — adding a prefix here doubles it.
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
  previewBase = [
    p.common
    p.gcp
    p.metrics
    p.ops-agent
    p.midnight-stack
    p.network-preview
    shared
  ];
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
}
