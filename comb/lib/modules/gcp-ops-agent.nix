# Metrics and logs into Google Cloud Operations.
#
# This is the ops-agent equivalent, not the Ops Agent. Google ships
# `google-cloud-ops-agent` only as a .deb/.rpm bundle (fluent-bit + otelopscol
# + a Go config generator, ~550MB installed, FHS paths and writable state dirs);
# it is not in nixpkgs. Rather than autoPatchelf an Ubuntu bundle onto NixOS, we
# run the collector Google's agent is itself built around —
# opentelemetry-collector-contrib — with the two GCP pipelines that matter:
#
#   metrics   prometheus receiver  ->  googlecloud exporter  ->  Cloud Monitoring
#   logs      journald receiver    ->  googlecloud exporter  ->  Cloud Logging
#
# Two consequences of not being the official agent, both deliberate:
#
#   * Metrics land under `workload.googleapis.com/*`, not the free
#     `agent.googleapis.com/*` prefix reserved for Google's own agents. They are
#     billed as custom metrics, and GCP's built-in VM dashboards will not
#     auto-populate — build dashboards against the prefix below instead.
#   * Nothing here is generated at runtime. The collector config is a store path
#     rendered from `settings`, validated by `otelcol validate` at *build* time
#     (see validateConfigFile), so a malformed pipeline fails the deploy rather
#     than a node.
#
# Metrics are scraped, not collected directly: the node_exporter in the
# `metrics` profile is already filtered to disk collectors, so pointing the
# collector at :9100 keeps one definition of "which host metrics we care about"
# instead of a second, parallel hostmetrics config that would drift from it.
#
# Authentication is the instance's own service account via the GCE metadata
# server — the same trust boundary as ../modules/gcp-secrets.nix, and for the
# same reason: no key file on disk to leak. The service account needs
#   roles/monitoring.metricWriter   (metrics pipeline)
#   roles/logging.logWriter         (logs pipeline)
# and the `resourcedetection` processor needs to reach 169.254.169.254 so both
# signals attach to the right `gce_instance` rather than a bare `generic_node`.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.midnight.opsAgent;
  node = config.services.midnight-node;
  cardano = config.services.cardano-node;
  nodeExporter = config.services.prometheus.exporters.node;

  exporterTarget = "127.0.0.1:${toString nodeExporter.port}";
in {
  options.midnight.opsAgent = {
    enable = mkEnableOption "shipping metrics and journald logs to Google Cloud Operations";

    project = mkOption {
      type = types.str;
      # `or ""` so the module still evaluates when imported without
      # ../modules/gcp-secrets.nix, which is what declares midnight.gcp.project.
      # The assertion below turns that into a message saying what to set.
      default = config.midnight.gcp.project or "";
      defaultText = lib.literalExpression "config.midnight.gcp.project";
      description = ''
        GCP project the metrics and logs are written to. Defaults to the project
        the node fetches its secrets from, which is what you want unless
        observability is deliberately centralised somewhere else.
      '';
    };

    scrapeInterval = mkOption {
      type = types.str;
      default = "60s";
      description = ''
        How often the Prometheus targets are scraped. Cloud Monitoring bills on
        ingest volume, so this is the main cost dial — 60s matches the official
        agent's default.
      '';
    };

    scrapeTargets = mkOption {
      type = types.attrsOf types.str;
      default =
        {
          node = exporterTarget;
        }
        // lib.optionalAttrs node.enable {
          midnight-node = "127.0.0.1:${toString node.prometheusPort}";
        };
      defaultText = lib.literalMD ''
        the local node_exporter, plus `midnight-node` when it is enabled. Add
        `cardano-node = "127.0.0.1:12798"` to include the Cardano metrics.
      '';
      description = ''
        Prometheus scrape targets, as job name -> host:port. All are scraped
        over loopback: nothing here needs a firewall hole.
      '';
    };

    logUnits = mkOption {
      type = types.listOf types.str;
      default =
        ["midnight-secrets.service"]
        ++ lib.optional node.enable "midnight-node.service"
        ++ lib.optionals cardano.enable [
          "cardano-node.service"
          "cardano-db-sync.service"
        ];
      defaultText = lib.literalMD ''
        the stack units that are actually enabled on the host.
      '';
      description = ''
        systemd units whose journal is shipped to Cloud Logging. Deliberately
        not the whole journal: chain nodes are chatty, Cloud Logging bills per
        GiB ingested, and journald already keeps everything locally under the
        cap set in the `common` profile. Set to `[]` to ship no logs.
      '';
    };

    logPriority = mkOption {
      type = types.str;
      default = "info";
      description = "Lowest journal priority shipped. `warning` cuts volume further.";
    };

    memoryLimitMiB = mkOption {
      type = types.int;
      default = 256;
      description = ''
        Soft cap for the collector's own heap, enforced by the memory_limiter
        processor. The chain process is the thing that wants RAM on these hosts;
        the collector should never be what starves it.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.project != "";
        message = ''
          midnight.opsAgent.project is empty. Set it, or set
          midnight.gcp.project — the ops agent inherits that by default, but
          only when ../modules/gcp-secrets.nix is also imported.
        '';
      }
    ];

    # Not an assertion: a target that nothing is listening on makes the scrape
    # fail, not the config invalid. Deliberately keyed on a target actually
    # pointing at the exporter, so scraping only midnight-node without a
    # node_exporter stays silent.
    warnings =
      lib.optional
      (!nodeExporter.enable
        && lib.elem exporterTarget (lib.attrValues cfg.scrapeTargets))
      ''
        midnight.opsAgent scrapes ${exporterTarget} but
        services.prometheus.exporters.node is disabled, so that job will fail
        every interval. Import the `metrics` profile, or drop the `node` entry
        from midnight.opsAgent.scrapeTargets.
      '';

    services.opentelemetry-collector = {
      enable = true;
      # Must be a contrib build: the googlecloud exporter and journald receiver
      # are not in the core distribution the NixOS module defaults to.
      package = pkgs.opentelemetry-collector-contrib;

      # Build-time `otelcol validate` against the settings below. This is the
      # only real check available without a GCE metadata server, so keep it on:
      # it catches every misspelled key and unknown component.
      validateConfigFile = true;

      settings = {
        receivers =
          lib.optionalAttrs (cfg.scrapeTargets != {}) {
            prometheus.config.scrape_configs =
              lib.mapAttrsToList (job: target: {
                job_name = job;
                scrape_interval = cfg.scrapeInterval;
                static_configs = [{targets = [target];}];
              })
              cfg.scrapeTargets;
          }
          // lib.optionalAttrs (cfg.logUnits != []) {
            journald = {
              units = cfg.logUnits;
              priority = cfg.logPriority;
            };
          };

        processors = {
          # Must stay first in every pipeline: it can only shed load it sees
          # before the rest of the chain has buffered it.
          memory_limiter = {
            check_interval = "5s";
            limit_mib = cfg.memoryLimitMiB;
          };

          # What turns both signals into `gce_instance` in the console. Without
          # it everything lands as an unlabelled generic_node.
          resourcedetection = {
            detectors = ["gcp"];
            timeout = "10s";
          };

          batch = {
            send_batch_size = 512;
            timeout = "10s";
          };
        };

        exporters.googlecloud = {
          project = cfg.project;
          # Third-party collectors cannot write to the free agent.googleapis.com
          # namespace, so these are custom metrics whatever we do here.
          metric.prefix = "workload.googleapis.com";
          log.default_log_name = "midnight-ops-agent";
        };

        service = {
          pipelines =
            lib.optionalAttrs (cfg.scrapeTargets != {}) {
              metrics = {
                receivers = ["prometheus"];
                processors = ["memory_limiter" "resourcedetection" "batch"];
                exporters = ["googlecloud"];
              };
            }
            // lib.optionalAttrs (cfg.logUnits != []) {
              logs = {
                receivers = ["journald"];
                processors = ["memory_limiter" "resourcedetection" "batch"];
                exporters = ["googlecloud"];
              };
            };

          # The collector's own metrics would themselves be billed custom
          # metrics; its logs go to the journal, which is enough to debug it.
          telemetry.metrics.level = "none";
        };
      };
    };

    systemd.services.opentelemetry-collector = {
      # The journald receiver shells out to `journalctl` — it is not a libsystemd
      # binding. Without systemd on PATH the logs pipeline dies at startup.
      path = [config.systemd.package];

      # Nothing to export before the metadata server is reachable: the gcp
      # resource detector needs it, and it is also how the collector gets its
      # credentials.
      wants = ["network-online.target"];
      after = ["network-online.target"];

      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
