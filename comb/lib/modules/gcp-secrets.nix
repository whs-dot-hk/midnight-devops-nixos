# Boot-time secret delivery from GCP Secret Manager.
#
# This is the one module that touches credentials, so it is worth being
# explicit about the trust boundary:
#
#   * Nothing secret is in this repository. Only *secret IDs* are configured
#     here; the secrets themselves are created by Terraform.
#   * Nothing secret is in the Nix store. The store is world-readable; every
#     value fetched below is written straight to a 0600 file outside it.
#   * Authentication is the instance's own service account, read from the GCE
#     metadata server. No key file exists on disk to leak.
#
# The work itself is done by `midnight-fetch-secrets`, a small Rust program
# (../pkgs/midnight-fetch-secrets). It speaks the Secret Manager REST API
# directly rather than driving the gcloud CLI: the same requests, without
# pulling a ~1GB SDK into every node's closure. This module's job is to hand it
# a config file — the non-secret half: project, secret IDs, paths, database
# endpoint — and to order the unit correctly.
#
# Secret payload shapes, as stored in Secret Manager:
#   node / validatorKeys / relayKeys / bootNodeKeys
#       {"aura": ..., "grandpa": ..., "crossChain": ..., "node-key": ...}
#     each value being either a bare string or {"secretSeed": "..."}
#   validatorSeedPhrases
#       {"aura": ..., "grandpa": ..., "crossChain": ...}
#   db
#       {"username": ..., "password": ..., "database": ...}
#
# Precedence for aura/grandpa/crossChain, lowest to highest:
#   node  ->  validatorKeys  ->  validatorSeedPhrases
# and for node-key:
#   node  ->  validatorKeys / relayKeys / bootNodeKeys (by node type)
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.midnight.gcp;
  common = config.midnight;
  node = config.services.midnight-node;
  dbSync = config.services.cardano-db-sync;

  wantsDb = dbSync.enable || cfg.secrets.db != null;

  # The non-secret half of the job, handed to the fetcher as JSON. It lands in
  # the (world-readable) store, which is exactly why only secret *IDs* appear
  # here and never a secret.
  fetchConfig = pkgs.writeText "midnight-secrets.json" (builtins.toJSON {
    inherit (cfg) project;
    inherit (common) user group;

    env_file = cfg.runtimeEnvFile;
    node_type = node.nodeType;

    secrets = {
      inherit (cfg.secrets) node db;
      validator_keys = cfg.secrets.validatorKeys;
      validator_seed_phrases = cfg.secrets.validatorSeedPhrases;
      relay_keys = cfg.secrets.relayKeys;
      boot_node_keys = cfg.secrets.bootNodeKeys;
    };

    # Seed phrases are a validator-only concern; null turns those files off.
    secrets_dir =
      if node.nodeType == "validator"
      then "${common.appHome}/secrets"
      else null;

    network_dir = "${node.basePath}/chains/midnight_${node.cfgPreset}/network";
    chains_dir = "${node.basePath}/chains";

    db =
      if wantsDb
      then {
        inherit (dbSync.database) host port name user;
        ssl_mode = dbSync.database.sslMode;
        pgpass_file = dbSync.pgpassFile;
      }
      else null;
  });
in {
  imports = [./common.nix];

  options.midnight.gcp = {
    enable = mkEnableOption "fetching node secrets from GCP Secret Manager at boot";

    project = mkOption {
      type = types.str;
      example = "my-gcp-project";
      description = ''
        GCP project holding the secrets. Not confidential, but deployment
        specific — set it per group rather than hardcoding it in a profile.
      '';
    };

    runtimeEnvFile = mkOption {
      type = types.str;
      default = "/run/midnight-node/env";
      description = ''
        Where the credential-bearing environment file is written. Must be on
        tmpfs so it does not survive a reboot; it is recreated on every boot.
      '';
    };

    secrets = {
      node = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "validator-0-secrets";
        description = "Secret ID holding the node's base key material.";
      };

      validatorKeys = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Secret ID for validator keys. Validators only.";
      };

      validatorSeedPhrases = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Secret ID for validator seed phrases. Highest precedence.";
      };

      relayKeys = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Secret ID for relay node keys. Relays only.";
      };

      bootNodeKeys = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Secret ID for boot node keys. Boot nodes only.";
      };

      db = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "validator-0-db-credentials";
        description = "Secret ID for the Cloud SQL credentials.";
      };
    };
  };

  config = mkIf cfg.enable {
    # The node unit reads its credentials from here.
    services.midnight-node.environmentFiles = [cfg.runtimeEnvFile];

    systemd.services.midnight-secrets = {
      description = "Fetch Midnight node secrets from GCP Secret Manager";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      before =
        ["midnight-node.service"]
        ++ lib.optional dbSync.enable "cardano-db-sync.service";
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe pkgs.midnight-fetch-secrets} ${fetchConfig}";
        # Runs as root: it writes into /opt and /var/lib on behalf of the node
        # user and chowns the results.
        User = "root";
      };
    };

    # Hard dependency, not just ordering: starting the node without its keys
    # produces a node with a fresh identity, which is worse than not starting.
    systemd.services.midnight-node = {
      after = ["midnight-secrets.service"];
      requires = ["midnight-secrets.service"];
    };

    systemd.services.cardano-db-sync = mkIf dbSync.enable {
      after = ["midnight-secrets.service"];
      requires = ["midnight-secrets.service"];
    };
  };
}
