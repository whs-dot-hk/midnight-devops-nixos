# Profiles: values set on the interfaces the modules declare.
#
# Nothing here is deployment-specific. Anything that identifies a particular
# project, host, address or endpoint belongs in ../midnight/groups.nix (fleet
# shape) or ../host (per-machine), never in a shared profile.
#
# The set is `rec` so the composite profiles at the bottom can name the halves
# they are built from; nothing here is recursive beyond that.
{
  inputs,
  cell,
  ...
}: rec {
  # --------------------------------------------------------------------------
  # Baseline: applies to every machine in the fleet.
  # --------------------------------------------------------------------------
  common = {pkgs, ...}: {
    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true;
      # Chain nodes are long-lived and rebuilt rarely; keeping a wide window of
      # generations makes rollback cheap.
      keep-outputs = true;
      keep-derivations = true;
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

    environment.systemPackages = with pkgs; [
      curl
      jq
      git
      vim
      htop
      lsof
      btrfs-progs
      dnsutils
    ];

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        # colmena deploys over SSH with a key; never a password.
        PermitRootLogin = "prohibit-password";
      };
    };

    networking.firewall.enable = true;

    # Journald: chain nodes are chatty and the root disk is small.
    services.journald.extraConfig = ''
      SystemMaxUse=2G
      MaxRetentionSec=1month
    '';

    security.sudo.wheelNeedsPassword = false;
  };

  # --------------------------------------------------------------------------
  # Platform.
  # --------------------------------------------------------------------------
  gcp = {lib, ...}: {
    # Serial console output is the only way to debug a node that fails before
    # sshd is up, and it is what `gcloud compute instances get-serial-port-output`
    # reads.
    boot.kernelParams = ["console=ttyS0,115200n8"];

    # Metadata-server DNS name used by the secret fetcher.
    networking.nameservers = lib.mkDefault ["169.254.169.254"];

    services.resolved.enable = lib.mkDefault false;
  };

  # --------------------------------------------------------------------------
  # Observability. Both metrics endpoints are local for now and this opens no
  # ports: node_exporter binds 127.0.0.1, midnight-node keeps upstream's default
  # local bind (no --prometheus-external), and the ops agent scrapes both over
  # loopback.
  #
  # Revisit if these hosts are ever managed by midnight-iac's instance groups.
  # There, 9615 is the MIG's auto-healing TCP health check
  # (modules/gcp/main.tf: google_compute_health_check.midnight, 30s interval,
  # unhealthy after 3) and is also scraped by the central prometheus-server in
  # gcp/shared/europe-west1. Under that setup a node that does not answer on
  # 9615 is declared dead and the instance is recreated, so going local means
  # restoring --prometheus-external *and* opening the port here — the VPC rule
  # allowing 9615 is necessary but not sufficient.
  #
  # Telemetry is unrelated to all of this: --telemetry-url is an outbound wss://
  # connection to the telemetry board and needs nothing open.
  # --------------------------------------------------------------------------
  metrics = {...}: {
    services.prometheus.exporters.node = {
      enable = true;

      # Disk only, for now. `enabledCollectors` *adds* to node_exporter's
      # default-on set rather than replacing it, so restricting the surface
      # takes --collector.disable-defaults; without it this list would be a
      # no-op (filesystem and diskstats are both on by default) and we would
      # be scraping all ~40 default collectors.
      #
      # Chain nodes fill disks — that is the failure mode worth alerting on:
      #   filesystem  node_filesystem_{avail,size,files}_bytes  (space left)
      #   diskstats   node_disk_{read,written}_bytes_total, io_time_seconds
      # Add collectors here as the alerting story grows (`systemd` for
      # per-unit state, `cpu`/`meminfo` for saturation).
      enabledCollectors = ["filesystem" "diskstats"];
      extraFlags = ["--collector.disable-defaults"];

      listenAddress = "127.0.0.1";
      port = 9100;
    };
  };

  # Ship the above to Cloud Monitoring, and the stack units' journal to Cloud
  # Logging. Kept separate from `metrics` on purpose: exposing metrics on the
  # node and forwarding them to a particular cloud are two decisions, and only
  # the second one is GCP-specific. Scraping is over loopback, so this opens
  # nothing — but it does mean the instance service account needs
  # roles/monitoring.metricWriter and roles/logging.logWriter.
  ops-agent = {...}: {
    midnight.opsAgent.enable = true;
  };

  # --------------------------------------------------------------------------
  # The stack itself. `midnight-stack` is the common half; the per-network and
  # per-node-type profiles below layer onto it.
  # --------------------------------------------------------------------------
  # The modules themselves are imported by ../group/nixosModules.nix; this
  # profile only turns the node on.
  midnight-stack = {...}: {
    services.midnight-node.enable = true;
  };

  # --------------------------------------------------------------------------
  # Networks. Public protocol parameters only.
  # --------------------------------------------------------------------------
  # The bootnode lists below are the ones the pinned midnight-node release
  # ships in `res/<network>/bootnodes-config.json`; preprod and mainnet also
  # carry them inside `chain-spec-raw.json`, so passing --bootnodes there is
  # belt-and-braces rather than load-bearing. Preview's shipped chain spec has
  # an empty `bootNodes`, which is why it *must* be listed here. Re-check these
  # against `res/` whenever comb/lib/pkgs/versions.nix bumps the node.
  network-preview = {...}: {
    services.midnight-node = {
      chainNetwork = "preview";
      cfgPreset = "preview";
      bootNodes = [
        "/dns/bootnode-1.preview.midnight.network/tcp/30333/ws/p2p/12D3KooWK66i7dtGVNSwDh9tTeqov1q6LSdWsRLJvTyzTCaywYgK"
        "/dns/bootnode-2.preview.midnight.network/tcp/30333/ws/p2p/12D3KooWHqFfXFwb7WW4jwR8pr4BEf562v5M6c8K3CXAJq4Wx6ym"
      ];
    };

    services.cardano-node.network = "preview";
  };

  network-preprod = {...}: {
    services.midnight-node = {
      chainNetwork = "preprod";
      cfgPreset = "preprod";
      bootNodes = [
        "/dns/bootnode-1.preprod.midnight.network/tcp/30333/ws/p2p/12D3KooWQxxUgq7ndPfAaCFNbAxtcKYxrAzTxDfRGNktF75SxdX5"
        "/dns/bootnode-2.preprod.midnight.network/tcp/30333/ws/p2p/12D3KooWNrUBs22FfmgjqFMa9ZqKED2jnxwsXWw5E4q2XVwN35TJ"
      ];
    };

    services.cardano-node.network = "preprod";
  };

  network-mainnet = {...}: {
    services.midnight-node = {
      chainNetwork = "mainnet";
      cfgPreset = "mainnet";

      # Mainnet's chain spec is `id = "midnight"`, not `midnight_mainnet` like
      # the testnets, so the node's on-disk chain directory does not follow
      # from CFG_PRESET here. Spelled out so the node key is written where the
      # node will actually look for it.
      chainDirName = "midnight";

      # Two `.mainnet.` and two `.bn.` hostnames — both sets are upstream's.
      bootNodes = [
        "/dns4/bootnode-whippet-bengal.mainnet.midnight.network/tcp/30333/ws/p2p/12D3KooWMmfho3eEFvcnThAfzc9QfieTc91fdhvByL4a2naRjbr2"
        "/dns4/bootnode-labrador-marten.mainnet.midnight.network/tcp/30333/ws/p2p/12D3KooWK2c9vf4UtrjGB27A8weKd6eiBnRQSfeR4TVmQv9MDdDt"
        "/dns4/bootnode-glider-spaniel.bn.midnight.network/tcp/30333/ws/p2p/12D3KooWHif7N1ZPhrB8WxTFqjWTxo2U2a2FtJuSA8XRBdFMss6i"
        "/dns4/bootnode-dog-pelican.bn.midnight.network/tcp/30333/ws/p2p/12D3KooWQ2NCZCnqkYKHKsYVUc8amBKAk4jhEMJyYDAJjmSuM4uK"
      ];
    };

    services.cardano-node.network = "mainnet";
  };

  # --------------------------------------------------------------------------
  # Node types: which services run, which ports open, which secrets are wanted.
  # --------------------------------------------------------------------------
  node-validator = {config, ...}: {
    services.midnight-node.nodeType = "validator";

    # A validator follows Cardano itself.
    services.cardano-node.enable = true;
    services.cardano-db-sync.enable = true;

    networking.firewall.allowedTCPPorts = [
      config.services.midnight-node.p2pPort
      config.services.cardano-node.port
    ];
  };

  node-rpc = {
    config,
    lib,
    ...
  }: {
    services.midnight-node = {
      nodeType = "rpc";
      # Binding JSON-RPC to 0.0.0.0 is a deliberate exposure decision — make it
      # per-group, not a property of being an rpc node.
      rpc.external = lib.mkDefault false;
    };

    services.cardano-node.enable = true;
    services.cardano-db-sync.enable = true;

    networking.firewall.allowedTCPPorts =
      [config.services.cardano-node.port]
      ++ lib.optional config.services.midnight-node.rpc.external
      config.services.midnight-node.rpc.port;
  };

  node-boot = {config, ...}: {
    services.midnight-node.nodeType = "boot";

    services.cardano-node.enable = true;
    services.cardano-db-sync.enable = true;

    networking.firewall.allowedTCPPorts = [
      config.services.midnight-node.p2pPort
      config.services.cardano-node.port
    ];
  };

  node-relay = {config, ...}: {
    services.midnight-node.nodeType = "relay";

    # Relays run no Cardano stack of their own: they read ariadne data from a
    # validator's db-sync database, or fall back to the follower mock.
    services.cardano-node.enable = false;
    services.cardano-db-sync.enable = false;

    networking.firewall.allowedTCPPorts = [
      config.services.midnight-node.p2pPort
    ];
  };

  # --------------------------------------------------------------------------
  # Bootnodes: a whole node, network included.
  # --------------------------------------------------------------------------
  # A bootnode is what other nodes dial to find the network, so which chain it
  # is on is not an orthogonal choice the way it is for a validator — the
  # address a peer is given and the network it joins are the same fact. These
  # bundle the three halves that always travel together (the stack, one
  # network, the `boot` node type) and leave the platform-specific profiles
  # (`gcp`, `metrics`, `ops-agent`) and the deployment's own values to the
  # group importing them.
  #
  # A bootnode is *not* a validator: no session keys, no seed phrases. It does
  # need a stable peer ID, which is the `node-key` in its `bootNodeKeys`
  # secret — regenerate that and every peer's --bootnodes entry is stale.
  boot-preview = {
    imports = [midnight-stack network-preview node-boot];
  };

  boot-preprod = {
    imports = [midnight-stack network-preprod node-boot];
  };

  boot-mainnet = {
    imports = [midnight-stack network-mainnet node-boot];
  };
}
