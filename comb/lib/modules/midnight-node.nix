# midnight-node — runs on every node type.
#
# Arguments are assembled in a fixed order — common args, then the per-nodeType
# args, then port/public-addr/name, then extras — so the rendered ExecStart for
# a given role is stable and diffable across rebuilds.
#
# Secrets never appear here. Everything sensitive (node key, validator seeds,
# database password) is written at boot to files/`environmentFiles` by
# ./gcp-secrets.nix; this module only references the paths.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types optional optionals concatStringsSep;

  cfg = config.services.midnight-node;
  common = config.midnight;
  dbSync = config.services.cardano-db-sync;

  isValidator = cfg.nodeType == "validator";

  chainSpec =
    if cfg.chainSpec != null
    then cfg.chainSpec
    else "${cfg.package}/share/midnight-node/res/${cfg.chainNetwork}/chain-spec-raw.json";

  commonArgs =
    [
      "--db-cache ${toString cfg.dbCache}"
      "--pool-limit ${toString cfg.poolLimit}"
      "--tx-ban-seconds ${toString cfg.txBanSeconds}"
      "--trie-cache-size 0"
    ]
    # No --prometheus-external, so the metrics endpoint stays on 127.0.0.1
    # (upstream default; the endpoint itself is on unless --no-prometheus). The
    # ops agent scrapes it over loopback. See the `metrics` profile for why this
    # may need revisiting if these hosts are managed by the Terraform stack's
    # instance groups.
    ++ map (b: "--bootnodes ${b}") cfg.bootNodes
    ++ optional (cfg.telemetryUrl != null) "--telemetry-url '${cfg.telemetryUrl}'";

  # The per-role argument sets.
  argsByNodeType = {
    boot = [
      "--state-pruning archive"
      "--blocks-pruning archive"
      "--rpc-cors=all"
    ];
    # An rpc node serves JSON-RPC: archive pruning plus connection/method
    # limits. --rpc-external is what makes midnight-node bind 0.0.0.0 rather
    # than 127.0.0.1, so it is gated on the endpoint actually being exposed.
    rpc =
      [
        "--state-pruning archive"
        "--blocks-pruning archive"
        "--rpc-max-connections ${toString cfg.rpc.maxConnections}"
        "--rpc-methods ${cfg.rpc.methods}"
      ]
      ++ optionals cfg.rpc.external [
        "--rpc-external"
        "--rpc-cors=${cfg.rpc.cors}"
      ];
    relay = [];
    validator = ["--validator"];
  };

  nodeTypeArgs = argsByNodeType.${cfg.nodeType};

  runArgs =
    commonArgs
    ++ nodeTypeArgs
    ++ optional (builtins.elem cfg.nodeType ["relay" "boot"]) "--port ${toString cfg.p2pPort}"
    ++ optional (cfg.publicAddr != null) "--public-addr ${cfg.publicAddr}"
    ++ optional (cfg.nodeName != null) "--name ${cfg.nodeName}"
    ++ cfg.extraArgs;

  secretsDir = "${common.appHome}/secrets";

  # Non-secret environment only. Anything with a credential in it is written
  # to cfg.environmentFiles at boot instead.
  baseEnv =
    {
      CFG_PRESET = cfg.cfgPreset;
      BASE_PATH = cfg.basePath;
      CARDANO_SECURITY_PARAMETER = toString cfg.cardano.securityParameter;
      CARDANO_ACTIVE_SLOTS_COEFF = cfg.cardano.activeSlotsCoeff;
      MC__FIRST_EPOCH_NUMBER = toString cfg.mainChain.firstEpochNumber;
      MC__FIRST_SLOT_NUMBER = toString cfg.mainChain.firstSlotNumber;
      ALLOW_NON_SSL =
        if cfg.allowNonSsl
        then "true"
        else "false";
    }
    # Zero means "use the node default" — emit nothing at all.
    // lib.optionalAttrs (cfg.cardano.blockStabilityMargin > 0) {
      BLOCK_STABILITY_MARGIN = toString cfg.cardano.blockStabilityMargin;
    }
    // lib.optionalAttrs (cfg.mainChain.firstEpochTimestampMillis > 0) {
      MC__FIRST_EPOCH_TIMESTAMP_MILLIS = toString cfg.mainChain.firstEpochTimestampMillis;
    }
    // lib.optionalAttrs (cfg.mainChain.epochDurationMillis > 0) {
      MC__EPOCH_DURATION_MILLIS = toString cfg.mainChain.epochDurationMillis;
    }
    // lib.optionalAttrs (cfg.mainChain.slotDurationMillis > 0) {
      MC__SLOT_DURATION_MILLIS = toString cfg.mainChain.slotDurationMillis;
    }
    // lib.optionalAttrs (cfg.sidechainBlockBeneficiary != null) {
      SIDECHAIN_BLOCK_BENEFICIARY = cfg.sidechainBlockBeneficiary;
    }
    // lib.optionalAttrs cfg.useMainChainFollowerMock {
      USE_MAIN_CHAIN_FOLLOWER_MOCK = "true";
    }
    // lib.optionalAttrs (cfg.validatorBootnode != null) {
      VALIDATOR_BOOTNODE = cfg.validatorBootnode;
    }
    // lib.optionalAttrs (builtins.elem cfg.nodeType ["relay" "boot"]) {
      P2P_PORT = toString cfg.p2pPort;
    }
    # Seed *paths*, not seeds. The files are written 0600 at boot.
    // lib.optionalAttrs isValidator {
      AURA_SEED_FILE = "${secretsDir}/aura-seed-phrase";
      GRANDPA_SEED_FILE = "${secretsDir}/grandpa-seed-phrase";
      CROSS_CHAIN_SEED_FILE = "${secretsDir}/cross-chain-seed-phrase";
    }
    # Non-secret halves of the db-sync connection, for the wait gate below.
    // lib.optionalAttrs cfg.waitForDbSync.enable {
      POSTGRES_HOST = dbSync.database.host;
      POSTGRES_PORT = toString dbSync.database.port;
      POSTGRES_DB = dbSync.database.name;
      POSTGRES_USER = dbSync.database.user;
    };

  # Blocks until cardano-db-sync has caught up to the Cardano tip. The node's
  # main-chain follower needs cexplorer populated to the tip, otherwise its
  # essential task fails and the unit crash-loops.
  waitForDbSync = pkgs.writeShellApplication {
    name = "wait-for-dbsync";
    runtimeInputs = [pkgs.postgresql];
    text = ''
      # Read from the unit's environment; the password half comes from the
      # runtime environment file written by gcp-secrets.nix.
      threshold="''${DBSYNC_READY_LAG:-${toString cfg.waitForDbSync.maxLagSeconds}}"
      host="''${POSTGRES_HOST:-${dbSync.database.host}}"
      port="''${POSTGRES_PORT:-${toString dbSync.database.port}}"
      user="''${POSTGRES_USER:-${dbSync.database.user}}"
      db="''${POSTGRES_DB:-${dbSync.database.name}}"
      PGPASSWORD="''${POSTGRES_PASSWORD:-}"
      PGSSLMODE="''${PGSSLMODE:-${dbSync.database.sslMode}}"
      export PGPASSWORD PGSSLMODE

      while :; do
        lag=$(psql -h "$host" -p "$port" -U "$user" -d "$db" \
          -tAc "SELECT COALESCE(EXTRACT(EPOCH FROM (now()-max(time)))::bigint, 999999999) FROM block" \
          2>/dev/null | tr -d '[:space:]') || lag=""
        case "$lag" in
          "" | *[!0-9]*) lag=999999999 ;;
          *) ;;
        esac

        if [ "$lag" -lt "$threshold" ]; then
          echo "[wait-for-dbsync] caught up (lag ''${lag}s) — starting node"
          exit 0
        fi
        echo "[wait-for-dbsync] db-sync lag ''${lag}s > ''${threshold}s; waiting..."
        sleep ${toString cfg.waitForDbSync.intervalSeconds}
      done
    '';
  };
in {
  imports = [./common.nix];

  options.services.midnight-node = {
    enable = mkEnableOption "the Midnight node";

    package = mkOption {
      type = types.package;
      default = pkgs.midnight-node;
      defaultText = lib.literalExpression "pkgs.midnight-node";
      description = "midnight-node package to run.";
    };

    nodeType = mkOption {
      type = types.enum ["validator" "rpc" "boot" "relay"];
      description = "Role this node plays. Selects the per-type CLI arguments.";
    };

    chainNetwork = mkOption {
      type = types.str;
      default = "preview";
      description = "Midnight network. Selects res/<network>/chain-spec-raw.json.";
    };

    cfgPreset = mkOption {
      type = types.str;
      default = "preview";
      description = ''
        CFG_PRESET. Also names the on-disk chain directory
        (<basePath>/chains/midnight_<cfgPreset>), so the node key lands in the
        right place.
      '';
    };

    chainSpec = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Explicit raw chain spec. Defaults to the one shipped in the node
        package's res/ directory for `chainNetwork`.
      '';
    };

    basePath = mkOption {
      type = types.path;
      default = "${common.dataDir}/node";
      defaultText = lib.literalExpression "\"\${config.midnight.dataDir}/node\"";
      description = "Node --base-path / BASE_PATH: the chain database.";
    };

    nodeName = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "validator-0";
      description = "Telemetry display name (--name).";
    };

    telemetryUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wss://telemetry.example.invalid/submit 1";
      description = "Telemetry endpoint and verbosity (--telemetry-url).";
    };

    bootNodes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Multiaddrs passed as --bootnodes.";
    };

    p2pPort = mkOption {
      type = types.port;
      default = 30333;
      description = "P2P port. Passed as --port for relay and boot nodes.";
    };

    publicAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/ip4/203.0.113.10/tcp/30333/ws";
      description = "Externally reachable multiaddr advertised via --public-addr.";
    };

    validatorBootnode = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "VALIDATOR_BOOTNODE — set on relays attached to a validator.";
    };

    dbCache = mkOption {
      type = types.int;
      default = 256;
      description = "--db-cache, in MiB.";
    };

    poolLimit = mkOption {
      type = types.int;
      default = 5;
      description = "--pool-limit.";
    };

    txBanSeconds = mkOption {
      type = types.int;
      default = 18000;
      description = "--tx-ban-seconds.";
    };

    prometheusPort = mkOption {
      type = types.port;
      default = 9615;
      description = "Prometheus metrics port. Bound on 127.0.0.1.";
    };

    rpc = {
      port = mkOption {
        type = types.port;
        default = 9944;
        description = "JSON-RPC port.";
      };

      external = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Bind JSON-RPC to 0.0.0.0 and set --rpc-cors. Only meaningful for
          nodeType = "rpc"; leave false unless the endpoint is deliberately
          exposed.
        '';
      };

      cors = mkOption {
        type = types.str;
        default = "all";
        description = "--rpc-cors value. Prefer an explicit origin list over \"all\".";
      };

      methods = mkOption {
        type = types.enum ["auto" "safe" "unsafe"];
        default = "safe";
        description = "--rpc-methods.";
      };

      maxConnections = mkOption {
        type = types.int;
        default = 100000;
        description = "--rpc-max-connections.";
      };
    };

    cardano = {
      securityParameter = mkOption {
        type = types.int;
        default = 432;
        description = "CARDANO_SECURITY_PARAMETER (k).";
      };

      activeSlotsCoeff = mkOption {
        type = types.str;
        default = "0.05";
        description = ''
          CARDANO_ACTIVE_SLOTS_COEFF, as a decimal string.

          A string rather than a float on purpose: `toString 0.05` in Nix
          renders "0.050000", and this value is passed to the node verbatim.
        '';
      };

      blockStabilityMargin = mkOption {
        type = types.int;
        default = 0;
        description = "BLOCK_STABILITY_MARGIN. 0 leaves it unset (node default).";
      };
    };

    mainChain = {
      firstEpochNumber = mkOption {
        type = types.int;
        default = 0;
        description = "MC__FIRST_EPOCH_NUMBER.";
      };

      firstSlotNumber = mkOption {
        type = types.int;
        default = 0;
        description = "MC__FIRST_SLOT_NUMBER.";
      };

      firstEpochTimestampMillis = mkOption {
        type = types.int;
        default = 0;
        description = "MC__FIRST_EPOCH_TIMESTAMP_MILLIS. 0 leaves it unset.";
      };

      epochDurationMillis = mkOption {
        type = types.int;
        default = 0;
        description = "MC__EPOCH_DURATION_MILLIS. 0 leaves it unset.";
      };

      slotDurationMillis = mkOption {
        type = types.int;
        default = 0;
        description = "MC__SLOT_DURATION_MILLIS. 0 leaves it unset.";
      };
    };

    sidechainBlockBeneficiary = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SIDECHAIN_BLOCK_BENEFICIARY. Not a secret — a payout address.";
    };

    allowNonSsl = mkOption {
      type = types.bool;
      default = false;
      description = "ALLOW_NON_SSL. Leave false against Cloud SQL.";
    };

    useMainChainFollowerMock = mkOption {
      type = types.bool;
      default = false;
      description = ''
        USE_MAIN_CHAIN_FOLLOWER_MOCK. For standalone relays with no access to
        a db-sync database. Will not produce a usable node on a real network.
      '';
    };

    waitForDbSync = {
      enable = mkOption {
        type = types.bool;
        default = config.services.cardano-db-sync.enable;
        defaultText = lib.literalExpression "config.services.cardano-db-sync.enable";
        description = ''
          Gate startup on cardano-db-sync having caught up to the Cardano tip.
          Without this the main-chain follower's essential task fails against a
          cold cexplorer and the unit crash-loops.
        '';
      };

      maxLagSeconds = mkOption {
        type = types.int;
        default = 600;
        description = "Accepted db-sync lag before the node is allowed to start.";
      };

      intervalSeconds = mkOption {
        type = types.int;
        default = 60;
        description = "Poll interval while waiting.";
      };
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Files loaded as EnvironmentFile, each marked optional. This is how
        credentials reach the unit — populated by ./gcp-secrets.nix at boot,
        never from the Nix store.
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
      description = "Extra CLI arguments for midnight-node.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.rpc.external -> cfg.nodeType == "rpc";
        message = "services.midnight-node.rpc.external only applies to nodeType = \"rpc\".";
      }
      {
        assertion = cfg.waitForDbSync.enable -> config.services.cardano-db-sync.enable;
        message = "services.midnight-node.waitForDbSync.enable requires cardano-db-sync on the same host.";
      }
    ];

    environment.systemPackages = [cfg.package];

    systemd.tmpfiles.rules = [
      "d ${cfg.basePath} 0750 ${common.user} ${common.group} -"
      "d ${secretsDir} 0700 ${common.user} ${common.group} -"
      # res/ is symlinked rather than copied so the node and the operator-facing
      # key-generation wizards both read the version that matches the binary.
      "L+ ${common.appHome}/res - - - - ${cfg.package}/share/midnight-node/res"
      "L+ /home/${common.user}/res - - - - ${cfg.package}/share/midnight-node/res"
    ];

    systemd.services.midnight-node = {
      description = "Midnight Node";
      wants = ["network-online.target"];
      after =
        ["network-online.target"]
        ++ optional cfg.waitForDbSync.enable "cardano-db-sync.service";
      wantedBy = lib.optional cfg.autoStart "multi-user.target";

      environment = baseEnv;

      serviceConfig = {
        Type = "simple";
        User = common.user;
        Group = common.group;
        WorkingDirectory = common.appHome;
        EnvironmentFile = map (f: "-${f}") cfg.environmentFiles;
        ExecStartPre =
          optional cfg.waitForDbSync.enable
          "${waitForDbSync}/bin/wait-for-dbsync";
        ExecStart = "${cfg.package}/bin/midnight-node --chain ${chainSpec} ${concatStringsSep " " runArgs}";
        Restart = "on-failure";
        RestartSec = "5s";
        LimitNOFILE = 65535;
        # The db-sync gate can legitimately block for hours on a cold chain.
        TimeoutStartSec = "infinity";
        SyslogIdentifier = "midnight-node";
      };

      # Never give up: a node that has been restarting all night must still be
      # trying in the morning.
      unitConfig.StartLimitIntervalSec = 0;
    };
  };
}
