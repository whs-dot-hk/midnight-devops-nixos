# Shared identity and filesystem layout for the Midnight/Cardano stack.
#
# Imported by every service module so the `midnight` user, its group and the
# three well-known directories are declared exactly once no matter which
# combination of services a host runs.
#
# The three well-known paths, fixed so operator tooling can rely on them:
#   /var/lib/midnight   chain-data disk mount — node DBs + db-sync ledger state
#   /opt/midnight-node  midnight-node config, res/, secrets/
#   /opt/cardano        cardano-node config, node.socket, dbsync/
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.midnight;
in {
  options.midnight = {
    user = mkOption {
      type = types.str;
      default = "midnight";
      description = "Unix user every node service runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "midnight";
      description = "Primary group for the node user.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/midnight";
      description = ''
        Mount point of the chain-data disk. Holds the midnight node database,
        the Cardano node database and cardano-db-sync's ledger state.
      '';
    };

    appHome = mkOption {
      type = types.path;
      default = "/opt/midnight-node";
      description = "Midnight node working directory: res/, secrets/.";
    };

    cardanoHome = mkOption {
      type = types.path;
      default = "/opt/cardano";
      description = "Cardano node working directory: node.socket, dbsync/.";
    };
  };

  config = {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/home/${cfg.user}";
      createHome = true;
      # An interactive shell so operators can `sudo -u midnight` and drive the
      # midnight-node key-generation wizards by hand.
      shell = pkgs.bashInteractive;
    };

    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.appHome} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.cardanoHome} 0750 ${cfg.user} ${cfg.group} -"
    ];
  };
}
