# cardano-node — the partner-chain's view of Cardano.
#
# Runs on validator / boot / rpc nodes. Relays do not run it (they read
# ariadne data from a validator's db-sync database instead).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types concatStringsSep;

  cfg = config.services.cardano-node;
  common = config.midnight;

  args =
    [
      "--topology ${cfg.configDir}/topology.json"
      "--config ${cfg.configDir}/config.json"
      "--database-path ${cfg.databasePath}"
      "--port ${toString cfg.port}"
      "--socket-path ${cfg.socketPath}"
    ]
    ++ cfg.extraArgs;
in {
  imports = [./common.nix];

  options.services.cardano-node = {
    enable = mkEnableOption "the Cardano node";

    package = mkOption {
      type = types.package;
      default = pkgs.cardano-node-bin;
      defaultText = lib.literalExpression "pkgs.cardano-node-bin";
      description = "cardano-node package to run.";
    };

    network = mkOption {
      type = types.enum ["preview" "preprod" "mainnet"];
      default = "preview";
      description = "Cardano network this node follows.";
    };

    configDir = mkOption {
      type = types.path;
      default = pkgs.cardano-configs.${cfg.network};
      defaultText = lib.literalExpression "pkgs.cardano-configs.\${network}";
      description = ''
        Directory holding config.json, topology.json, the genesis files and
        db-sync-config.json. Built by ../pkgs/cardano-configs.nix.
      '';
    };

    databasePath = mkOption {
      type = types.path;
      default = "${common.dataDir}/cardano";
      defaultText = lib.literalExpression "\"\${config.midnight.dataDir}/cardano\"";
      description = "Cardano node chain database directory.";
    };

    socketPath = mkOption {
      type = types.path;
      default = "${common.cardanoHome}/node.socket";
      defaultText = lib.literalExpression "\"\${config.midnight.cardanoHome}/node.socket\"";
      description = "Node socket. cardano-db-sync connects to this.";
    };

    port = mkOption {
      type = types.port;
      default = 3001;
      description = "Cardano P2P port.";
    };

    prometheusPort = mkOption {
      type = types.port;
      default = 12798;
      description = ''
        Port cardano-node serves prometheus metrics on. Informational here —
        the listen address is baked into configDir by cardano-configs.nix;
        this option exists so profiles can open the matching firewall port.
      '';
    };

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start on boot. Set false to leave the unit installed but inert, for
        manual bring-up.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra CLI arguments appended to `cardano-node run`.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    systemd.tmpfiles.rules = [
      "d ${cfg.databasePath} 0750 ${common.user} ${common.group} -"
    ];

    systemd.services.cardano-node = {
      description = "Cardano Node";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      wantedBy = lib.optional cfg.autoStart "multi-user.target";

      serviceConfig = {
        Type = "simple";
        User = common.user;
        Group = common.group;
        WorkingDirectory = common.cardanoHome;
        ExecStart = "${cfg.package}/bin/cardano-node run ${concatStringsSep " " args}";
        Restart = "on-failure";
        RestartSec = "5s";
        SyslogIdentifier = "cardano-node";
        LimitNOFILE = 65535;
      };
    };
  };
}
