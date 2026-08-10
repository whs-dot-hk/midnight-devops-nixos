# cardano-db-sync — populates the `cexplorer` database the midnight node's
# main-chain follower reads.
#
# The database itself lives on Cloud SQL (private IP, TLS required) and is
# managed by Terraform, not here. This module only runs the syncer; the password
# arrives at boot from Secret Manager via ./gcp-secrets.nix, which writes the
# pgpass file referenced below.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types concatStringsSep;

  cfg = config.services.cardano-db-sync;
  common = config.midnight;
  node = config.services.cardano-node;

  args =
    [
      "--config ${cfg.configFile}"
      "--socket-path ${cfg.socketPath}"
      # db-sync state lives in a SIBLING directory, not under cardano-node's
      # --database-path. If db-sync's state-dir is created inside that path
      # before cardano-node initialises its own DB, the node aborts with
      # NoDbMarkerAndNotEmpty ("folder was not empty" / no protocolMagicId) and
      # never starts — which then blocks db-sync and the midnight node too.
      # Keeping them separate removes that ordering hazard entirely.
      "--state-dir ${cfg.stateDir}"
      "--schema-dir ${cfg.package}/share/cardano-db-sync/schema"
    ]
    ++ cfg.extraArgs;
in {
  imports = [./common.nix];

  options.services.cardano-db-sync = {
    enable = mkEnableOption "cardano-db-sync";

    package = mkOption {
      type = types.package;
      default = pkgs.cardano-db-sync-bin;
      defaultText = lib.literalExpression "pkgs.cardano-db-sync-bin";
      description = "cardano-db-sync package to run.";
    };

    configFile = mkOption {
      type = types.path;
      default = "${node.configDir}/db-sync-config.json";
      defaultText = lib.literalExpression "\"\${config.services.cardano-node.configDir}/db-sync-config.json\"";
      description = ''
        db-sync configuration. Its NodeConfigFile entry is a relative path, so
        this file must sit alongside the node's config.json — which is what
        ../pkgs/cardano-configs.nix guarantees.
      '';
    };

    socketPath = mkOption {
      type = types.path;
      default = node.socketPath;
      defaultText = lib.literalExpression "config.services.cardano-node.socketPath";
      description = "cardano-node socket to follow.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "${common.dataDir}/dbsync";
      defaultText = lib.literalExpression "\"\${config.midnight.dataDir}/dbsync\"";
      description = "db-sync ledger state directory. Must NOT live under the Cardano node's --database-path.";
    };

    database = {
      host = mkOption {
        type = types.str;
        example = "10.0.0.3";
        description = "PostgreSQL host (Cloud SQL private IP or its DNS name).";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };

      name = mkOption {
        type = types.str;
        default = "cexplorer";
        description = "Database db-sync writes to.";
      };

      user = mkOption {
        type = types.str;
        default = "cardano";
        description = "PostgreSQL user.";
      };

      sslMode = mkOption {
        type = types.str;
        default = "require";
        description = "PGSSLMODE for db-sync's connection.";
      };
    };

    pgpassFile = mkOption {
      type = types.path;
      default = "${common.cardanoHome}/dbsync/.pgpassfile";
      defaultText = lib.literalExpression "\"\${config.midnight.cardanoHome}/dbsync/.pgpassfile\"";
      description = ''
        Path to the pgpass file db-sync reads its full connection string from
        (`host:port:db:user:password`). Written at boot, mode 0600, by
        ./gcp-secrets.nix — it is never present in the Nix store.
      '';
    };

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Start on boot.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra CLI arguments for cardano-db-sync.";
    };
  };

  config = mkIf cfg.enable {
    # psql is on PATH for operators debugging cexplorer by hand; the
    # wait-for-dbsync gate in ./midnight-node.nix uses its own pinned copy.
    environment.systemPackages = [cfg.package pkgs.postgresql];

    systemd.tmpfiles.rules = [
      "d ${common.cardanoHome}/dbsync 0750 ${common.user} ${common.group} -"
      "d ${cfg.stateDir} 0750 ${common.user} ${common.group} -"
    ];

    systemd.services.cardano-db-sync = {
      description = "Cardano DB Sync";
      wants = ["network-online.target"];
      after = ["network-online.target" "cardano-node.service"];
      wantedBy = lib.optional cfg.autoStart "multi-user.target";

      environment = {
        PGPASSFILE = cfg.pgpassFile;
        PGSSLMODE = cfg.database.sslMode;
      };

      serviceConfig = {
        Type = "simple";
        User = common.user;
        Group = common.group;
        WorkingDirectory = common.cardanoHome;
        ExecStart = "${cfg.package}/bin/cardano-db-sync ${concatStringsSep " " args}";
        Restart = "on-failure";
        # db-sync is expensive to restart-loop against a not-yet-ready node;
        # back off a full minute.
        RestartSec = "60s";
        SyslogIdentifier = "cardano-db-sync";
        LimitNOFILE = 1048576;
      };
    };
  };
}
