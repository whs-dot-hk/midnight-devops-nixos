# midnight-devops-nixos

Midnight and Cardano nodes as NixOS machines, organised with
[divnix/hive](https://github.com/divnix/hive) and
[whs-dot-hk/hive-group](https://github.com/whs-dot-hk/hive-group), deployed with
[colmena](https://github.com/zhaofengli/colmena).

Provisioning is split along the line each tool is good at. Terraform keeps the
cloud resources — VPC, instances, disks, Cloud SQL, KMS, Secret Manager,
firewalls, load balancers — and Nix takes over what happens *inside* the
machine. Instances boot bare, with no cloud-init provisioning of their own,
ready to be configured out-of-band by this repo.

## What a node looks like

One layout for every node, whichever role it runs:

| Path | Contents |
|---|---|
| `/var/lib/midnight` | chain-data disk: midnight node DB, Cardano node DB, db-sync ledger state |
| `/opt/midnight-node` | `res/` (symlink into the store), `secrets/` |
| `/opt/cardano` | `node.socket`, `dbsync/.pgpassfile` |
| `/run/midnight-node/env` | credential-bearing environment, tmpfs, 0600, rewritten each boot |

Services, by node type:

| | midnight-node | cardano-node | cardano-db-sync |
|---|---|---|---|
| validator | `--validator` | yes | yes |
| rpc | archive pruning, JSON-RPC | yes | yes |
| boot | archive pruning | yes | yes |
| relay | — | no | no |

`midnight-node.service` waits on `cardano-db-sync` catching up to the Cardano
tip before it starts (`ExecStartPre=wait-for-dbsync`). Without that gate the
main-chain follower's essential task fails against a cold `cexplorer` and the
unit crash-loops.

`cardano-db-sync`'s `--state-dir` is a **sibling** of cardano-node's
`--database-path`, never a child. If db-sync's state directory is created
inside that path before cardano-node initialises its own DB, the node aborts
with `NoDbMarkerAndNotEmpty` and never starts.

## Secrets

Nothing confidential lives in this repository, and nothing confidential reaches
the Nix store (which is world-readable on the node).

`comb/lib/modules/gcp-secrets.nix` installs a `midnight-secrets.service`
oneshot that runs before `midnight-node.service` and `cardano-db-sync.service`.
The module supplies only a JSON config file — project, secret IDs, paths,
database endpoint, none of it confidential; the work is done by
`midnight-fetch-secrets`, a Rust program in
`comb/lib/pkgs/midnight-fetch-secrets`. It authenticates as the instance's own
service account via the GCE metadata server — no key file on disk — and reads
Secret Manager over its REST API, in-process over rustls, so the unit's runtime
closure is the binary alone. It then writes, all 0600 and owned by `midnight`:

- `/run/midnight-node/env` — `NODE_KEY`, `POSTGRES_PASSWORD`,
  `DB_SYNC_POSTGRES_CONNECTION_STRING`
- `/opt/midnight-node/secrets/{aura,grandpa,cross-chain}-seed-phrase` (validators)
- `/var/lib/midnight/node/chains/midnight_<preset>/network/secret_ed25519`
- `/opt/cardano/dbsync/.pgpassfile`

Only *secret IDs* are configured, in `comb/group/nixosProfiles.nix`, derived
from each node's hostname (`<node>-secrets`, `<node>-validator-keys`,
`midnight-<node>-db-credentials`) so a new instance needs no extra wiring.
Precedence for aura/grandpa/crossChain is `node` → `validatorKeys` →
`validatorSeedPhrases`.

`midnight-node.service` `Requires=` the secrets unit rather than merely
ordering after it: a node that starts without its keys comes up with a fresh
identity, which is worse than not starting.

A secret that is absent or denied is not fatal — a validator's keys are often
added by hand after the first apply — so the fetcher logs and carries on, and
the node unit simply does not start until they are there.

## Observability

Two profiles, deliberately separate: `metrics` serves metrics on the node,
`ops-agent` forwards them to Google Cloud. Serving and forwarding are different
decisions, and only the second is GCP-specific.

**Both endpoints are local**, and neither profile opens a firewall port:

| | bind | firewall | consumers |
|---|---|---|---|
| node_exporter `9100` | `127.0.0.1` | closed | the ops agent, over loopback |
| midnight-node `9615` | `127.0.0.1` (upstream default) | closed | the ops agent, over loopback |

The metrics endpoint is on unless `--no-prometheus`; `--prometheus-external` only
widens the bind from `127.0.0.1` to `::`, and is deliberately not passed.

**One thing to know before deploying onto Terraform-managed instances.** In
`midnight-iac`, 9615 is the managed instance group's auto-healing TCP health
check (`modules/gcp/main.tf`, 30s interval, unhealthy after 3, gated on
`enable_startup_services` which defaults true) and is also scraped by the central
`prometheus-server` in `gcp/shared/europe-west1`. Under that setup a node that
does not answer on 9615 is declared dead and the instance is recreated — an
instance-rebuild loop, not merely missing graphs. Going local there means
restoring `--prometheus-external` **and** opening the port in this profile: the
VPC rule permitting 9615 is necessary but not sufficient. 9100 has no counterpart
in the Terraform stack at all.

Telemetry is a separate, outbound mechanism and needs nothing open:
`--telemetry-url` is a `wss://` connection the node dials out to the telemetry
board. It is unaffected by `--prometheus-external`.

`metrics` runs node_exporter on `127.0.0.1:9100`, **filtered to disk collectors only** —
`filesystem` and `diskstats`, via `--collector.disable-defaults`. That flag is
the load-bearing part: `enabledCollectors` in NixOS *adds* to node_exporter's
default-on set rather than replacing it, so without it the list is a no-op and
all ~40 default collectors are exposed. Filtered, a node serves ~136 series
instead of ~525. Chain nodes fill disks; that is the failure mode worth
alerting on. Add collectors to the list as the alerting story grows —
`systemd` for per-unit state, `cpu`/`meminfo` for saturation.

`ops-agent` is the Ops Agent's job, not the Ops Agent. Google ships
`google-cloud-ops-agent` only as a .deb/.rpm bundle (~550MB installed, FHS
paths, a runtime config generator) and it is not in nixpkgs, so
`comb/lib/modules/gcp-ops-agent.nix` runs the collector that agent is itself
built around — `opentelemetry-collector-contrib` — with two pipelines:

| | source | destination |
|---|---|---|
| metrics | `prometheus` receiver, scraping `127.0.0.1:9100` and midnight-node's `127.0.0.1:9615` | Cloud Monitoring |
| logs | `journald` receiver, stack units only | Cloud Logging |

Metrics are scraped rather than collected directly so the disk filtering above
stays the single definition of which host metrics matter, instead of a parallel
`hostmetrics` config that would drift from it. Logs are restricted to the stack
units (`midnight-node`, `cardano-node`, `cardano-db-sync`, `midnight-secrets`)
because chain nodes are chatty and Cloud Logging bills per GiB — journald still
keeps everything locally under the `common` profile's 2G/1month cap.

Both pipelines are optional: clearing `scrapeTargets` gives logs-only, clearing
`logUnits` gives metrics-only, and the collector config drops the unused
receiver and pipeline entirely.

Authentication is the instance's own service account via the GCE metadata
server — the same trust boundary as [Secrets](#secrets), no key file on disk.
The service account needs:

| Role | For |
|---|---|
| `roles/monitoring.metricWriter` | the metrics pipeline |
| `roles/logging.logWriter` | the logs pipeline |

Missing credentials fail the unit at startup (it restarts every 10s, so it is
visible in `systemctl status`); missing *IAM* instead lets the collector run and
log export errors to the journal, so check there first if the console stays
empty.

Two things to know before building dashboards. Metrics land under
`workload.googleapis.com/*`, not the free `agent.googleapis.com/*` prefix
reserved for Google's own agents — so they are billed as custom metrics, and
GCP's built-in VM dashboards will not auto-populate. And the
`resourcedetection` processor needs to reach `169.254.169.254`, or both signals
attach to a bare `generic_node` instead of the right `gce_instance`.

The collector config is not generated at runtime: it is a store path rendered
from Nix and checked by `otelcol validate` during the build, so a malformed
pipeline fails the deploy rather than a node.

```sh
# what the node will actually run
nix eval --raw .#colmenaHive.nodes.gcp-midnight-preview-vali-instance00\
.config.systemd.services.opentelemetry-collector.serviceConfig.ExecStart
```

## Layout

```
comb/
├── lib/                     everything reusable
│   ├── helpers.nix          group.new — the entry point for declaring a fleet
│   ├── modules/             option interfaces (plain NixOS modules)
│   │   ├── common.nix           midnight user, group, directory layout
│   │   ├── midnight-node.nix    the node: args, env, unit, db-sync gate
│   │   ├── cardano-node.nix
│   │   ├── cardano-db-sync.nix
│   │   ├── gcp-secrets.nix      boot-time Secret Manager delivery
│   │   └── gcp-ops-agent.nix    metrics + logs into Cloud Operations
│   ├── pkgs/                pinned upstream release binaries + config
│   ├── nixosModules.nix     modules/, as a cell block
│   ├── nixosProfiles.nix    values: common, gcp, metrics, ops-agent,
│   │                        network-*, node-*
│   ├── hardwareProfiles.nix GCE guest
│   └── diskoConfigurations.nix  the root disk and the chain-data disk
│   ├── packages.nix         the node binaries, as a cell block
│   └── pkgs/midnight-fetch-secrets/  the boot-time Secret Manager client (Rust)
├── gcp-midnight-preview/    the fleet: groups.nix + generated block targets
├── group/                   per-class composition + deployment specifics
└── host/                    per-machine overrides (hostname, telemetry name)
```

The three-level `lib` / `group` / `host` split is hive-group's: `lib` holds
everything, `group` picks what a class of machines gets, `host` carries the
per-machine differences.

Naming, for `prefix = "gcp-midnight-preview-"` and `groupName = "vali"` in cell
`gcp-midnight-preview`. The node name is `<cell>-<groupName>-instanceNN` — the
cell directory name, not `prefix`; `prefix` builds the group/host lookup keys
and the tags, so the two have to agree:

| | |
|---|---|
| key in `comb/group/*.nix` | `gcp-midnight-preview-vali` |
| key in `comb/host/*.nix` | `gcp-midnight-preview-vali-instance00` |
| colmena node / `nixosConfigurations` | `gcp-midnight-preview-vali-instance00` |
| colmena tags | `@gcp-midnight-preview-vali-group-a`, `@gcp-midnight-preview-group-a` |

## Packages

Upstream release tarballs, pinned by version *and* hash in
`comb/lib/pkgs/versions.nix`:

| | version | notes |
|---|---|---|
| `midnight-node` | 1.0.1 | dynamically linked, autoPatchelf'd; ships `res/` |
| `cardano-node-bin` | 11.0.1 | statically linked; ships `share/<network>/` |
| `cardano-db-sync-bin` | 13.7.1.0 | statically linked; ships `schema/` |
| `cardano-configs-<network>` | — | built from the two above |

`1.0.1` is the current stable `node-*` release; the `0.20.x` assets are no
longer published upstream.

`cardano-configs` does at **build** time what would otherwise happen on every
boot:
takes `share/<network>/` from the cardano-node tarball as a version-matched
set, applies the prometheus/P2P `jq` patch, and drops in the separately-fetched
`db-sync-config.json`. Config drift becomes a build failure instead of a node
that will not start.

```sh
nix build .#x86_64-linux.lib.packages.midnight-node
nix build .#x86_64-linux.lib.packages.cardano-configs-preview
```

`midnight-fetch-secrets` is built from source in this repo rather than fetched:
see [Secrets](#secrets).

## Names live outside this repo

Nothing here names a real machine. The fleet in `comb/gcp-midnight-preview`,
`comb/group` and `comb/host` is a **worked example** — two preview nodes, placeholder
addresses, `REPLACE-ME` for the GCP project and Cloud SQL host. Every identifier
a deployment cares about is an input:

| What | Set where |
|---|---|
| group key prefix | `prefix` argument to `group.new` (must match the cell name) |
| group / instance names | `groupName`, `instancePrefix`, `start` to `group.new` |
| hostnames | `comb/host/nixosProfiles.nix` |
| GCP project, Cloud SQL host | `comb/group/nixosProfiles.nix` |
| Secret Manager IDs | `secretIds` in `comb/lib/helpers.nix` |
| telemetry name, public addr | `services.midnight-node.{nodeName,publicAddr}` |

Secret IDs are derived rather than listed. `secretIds` turns one base name into
the whole set, and takes the naming scheme as arguments, so a deployment whose
secrets are named differently changes one call instead of six strings:

```nix
secretIds {
  base     = config.networking.hostName;
  prefix   = "";                              # prepended to every ID
  dbPrefix = "";                              # prepended to the db ID alone
  suffixes = { node = "node-secrets"; };      # override individual kinds
}
# => { node = "<base>-node-secrets"; db = "<base>-db-credentials"; ... }
```

`base` is normally the hostname, which `group.new` has **already** prefixed —
don't add that prefix again in `prefix`/`dbPrefix` or the ID comes out doubled.

### Importing it

`flake.nix` exports one output, `colmenaHive` — this repo deploys its own fleet
rather than serving as a library. A separate (private) flake that wants the
mechanics reaches into the cells directly:

```nix
{
  inputs.midnight-devops-nixos.url = "github:whs-dot-hk/midnight-devops-nixos";

  # in your own comb/lib cell, as `self.x86_64-linux.lib.<block>`:
  #   .nixosModules          midnight-node, cardano-node, cardano-db-sync,
  #                          gcp-secrets, gcp-ops-agent, common — plain paths,
  #                          hive not required
  #   .nixosProfiles         common, gcp, metrics, ops-agent, network-*, node-*
  #   .hardwareProfiles.gcp
  #   .diskoConfigurations   gcp-root-and-chain-data, gcp-root, gcp-chain-data
  #   .helpers               group.new, secretIds
  #   .packages              the node binaries
}
```

One constraint worth knowing before you plan that split: hive-group resolves a
group through `inputs.cells.group.<block>.<fullGroupName>` and
`inputs.cells.host.nixosProfiles.<host>` **by name**, in the flake that calls
`group.new`. So a consuming flake needs its own `group` and `host` cells — those
two cannot be inherited from here. Only `comb/lib` is portable; the three
fleet cells are the part you rewrite, which is exactly the part that carries
names.

## Using it

Replace every `REPLACE-ME` first — they are in `comb/group/nixosProfiles.nix`
(GCP project, Cloud SQL host) and `comb/gcp-midnight-preview/groups.nix`
(instance IPs).

```sh
nix flake check              # evaluate every host
colmena build                # build the whole fleet
colmena apply --on @gcp-midnight-preview-vali-group-a
colmena apply --on gcp-midnight-preview-vali-instance00

# single host, from the host itself
nixos-rebuild switch --flake .#gcp-midnight-preview-vali-instance00
```

### Adding a node

1. Add or extend a `group.new` in `comb/gcp-midnight-preview/groups.nix` (one IP
   per instance).
2. If it is a new group, add its `cell.groups.<name>.<block> a` line to each of
   the six files in `comb/gcp-midnight-preview/`, and a key in each
   `comb/group/*.nix`.
3. Add the hostname in `comb/host/nixosProfiles.nix`.

### Adding a network

`comb/lib/nixosProfiles.nix` already carries `network-preview`,
`network-preprod` and `network-mainnet`. Only preview has bootnodes filled in —
they are public protocol parameters, unlike anything in `comb/group`.

The network is part of the cell name, so a second network is a second fleet
cell: copy `comb/gcp-midnight-preview/` to e.g. `comb/gcp-midnight-preprod/`,
set `prefix = "gcp-midnight-preprod-"` to match, and give it its own keys in
`comb/group/*.nix` and `comb/host/nixosProfiles.nix`.

## Disks

`comb/lib/diskoConfigurations.nix` describes both disks a node carries. The
groups use `gcp-root-and-chain-data`, the pair of them, so disko has a complete
picture of the machine and `nixos-anywhere` can install onto a blank instance
rather than requiring a prebuilt NixOS GCE image.

### Root disk (`gcp-root`)

UEFI-booting GPT on `/dev/disk/by-id/google-persistent-disk-0` — GCE's default
device name for the boot disk, unless Terraform sets `boot_disk.device_name`:

| partition | size | contents |
|---|---|---|
| `ESP` (`EF00`) | 512M | vfat labelled `ESP`, mounted `/boot`, `umask=0077` |
| `root` | rest | ext4 labelled `nixos`, mounted `/` |

nixpkgs' `google-compute-config.nix` assumes the root disk is an image it does
not own, so two of its settings are overridden in the `gcp` hardware profile —
next to the import that pulls them in — to match this layout:

- `fileSystems."/".device` — it hard-codes `/dev/disk/by-label/nixos` while
  disko would set `/dev/disk/by-partlabel/disk-root-root`. Neither is a
  default, so the module system reports conflicting definitions. Both name the
  same filesystem (the ext4 above is created with `-L nixos`), so the label
  wins: it is what `autoResize` resolves from initrd, and behaviour is
  unchanged.
- `boot.loader.grub.device` — it installs GRUB in BIOS mode on `/dev/sda`, and
  this layout has no BIOS boot partition. GRUB is pointed at the ESP instead
  (`device = "nodev"`, `efiSupport`, `efiInstallAsRemovable`), the same shape
  `google-compute-image.nix` uses for `efi = true`. Removable install because
  GCE does not persist NVRAM boot entries.

The `google-*` names under `/dev/disk/by-id` come from the google-guest-configs
udev rules, which ship with `google-compute-config.nix`. They exist on a booted
node but **not** in a generic installer/kexec environment, where only stock
udev has run. Formatting from such an environment needs the device overridden
to something that resolves there — `/dev/sda`, `/dev/nvme0n1` (gen-3 machine
types such as C3 and N4), or `/dev/disk/by-id/scsi-0Google_PersistentDisk_persistent-disk-0`:

```nix
# comb/host/nixosProfiles.nix
disko.devices.disk.root.device = lib.mkForce "/dev/nvme0n1";
```

### Chain-data disk (`gcp-chain-data`)

The data disk is formatted whole, with no partition table, as btrfs labelled
`midnightdata` — so `/dev/disk/by-id/google-chain-data`, the disk the Terraform
stack attaches, is mounted directly with nothing in between.

Layout follows disko's `example/btrfs-subvolumes.nix`, minus the GPT table and
ESP (this is a data disk, not a boot disk). One subvolume per consumer:

| subvolume | mountpoint | option it backs |
|---|---|---|
| `/node` | `/var/lib/midnight/node` | `services.midnight-node.basePath` |
| `/cardano` | `/var/lib/midnight/cardano` | `services.cardano-node.databasePath` |
| `/dbsync` | `/var/lib/midnight/dbsync` | `services.cardano-db-sync.stateDir` |

The filesystem root (`subvol=/`) is also mounted at `/var/lib/midnight`, which
keeps `midnight.dataDir`'s contract intact and gives snapshot management one
place to work from. Every mount carries
`compress=zstd,noatime,nofail,x-systemd.device-timeout=30`; `nofail` is
repeated per subvolume because disko emits one `fileSystems` entry per
mountpoint rather than inheriting.

Splitting db-sync's state onto its own subvolume also makes the sibling rule
from above structural rather than conventional — it can no longer land inside
cardano-node's `--database-path`.

Unlike the disko example, `-f` is **not** passed to `mkfs.btrfs`. disko already
skips mkfs when `blkid` reports an existing `TYPE=`, and `-f` is the one flag
that would override that guard on a disk holding chain data.

**Importing a disko configuration does not format anything.** It declares the
filesystem so NixOS mounts it. Running disko's format script against a node
holding chain data would destroy it; that is an explicit operator action, never
part of a deploy.

### Running disko

Reach the scripts through `nixosConfigurations`, not through the
`diskoConfigurations` flake output:

```sh
nixos-anywhere --flake .#gcp-midnight-preview-vali-instance00 root@<ip>

# or, by hand, from the installer environment
nix build .#nixosConfigurations.gcp-midnight-preview-vali-instance00.config.system.build.diskoScript
sudo ./result
```

hive-group emits `diskoConfigurations.<host>` as a NixOS module fragment
(`{imports = [...];}`), which is what `nixosConfigurations` needs but not the
bare `{disko.devices = ...;}` tree that `disko --flake .#<host>` expects — that
invocation fails on this repo. `nixos-anywhere` and `disko-install` both read
`config.system.build.diskoScript`, so they work.

Both `mkfs` steps are guarded by disko's `blkid … TYPE=` check, so re-running
the script over an installed disk will not silently reformat it — but `disko`
in `destroy` / `zap_create_mount` mode will, root disk included.

## Verification status

Built and checked on x86_64-linux:

- both hosts evaluate to a `config.system.build.toplevel` derivation
- the packages build; `midnight-node --version`, `cardano-node --version`
  and `cardano-db-sync --version` run from the store
- `cardano-configs-preview/config.json` carries
  `hasPrometheus=["0.0.0.0",12798]` and `EnableP2P=true`; `db-sync-config.json`
  sits beside it so its relative `NodeConfigFile` resolves
- `midnight-fetch-secrets` builds and its unit tests pass (payload unwrapping,
  precedence, URI encoding, pgpass escaping, hex decoding); run off GCE it logs
  the missing token and leaves a 0600 empty env file behind, exit 0
- the JSON the module renders deserialises into the program's config for both
  node types, and `ExecStart` is the binary plus that file
- `colmenaHive` emits schema `v0.5`
- rendered `ExecStart` lines carry the intended arguments for each node type
- with both disks declared, `fileSystems` resolves to `/` on
  `by-label/nixos` (ext4, `autoResize`), `/boot` on `by-partlabel/disk-root-ESP`
  (vfat) and the four btrfs mounts; GRUB comes out `nodev` + `efiSupport` +
  `efiInstallAsRemovable`, with no conflicting-definition errors
- `system.build.diskoScript` builds, and partitions/formats/mounts what the
  table above describes

Not verified: an actual deploy to a running instance, or a `nixos-anywhere`
install against a real boot disk — both need real GCP infrastructure.

## Notes

- The NixOS firewall is left **on**. `google-compute-config.nix` disables it in
  favour of GCP's; a node holding validator keys is worth defending twice, and
  the node-type profiles open exactly the ports that node serves.
- `CARDANO_ACTIVE_SLOTS_COEFF` is a string, not a float: `toString 0.05` in Nix
  renders `0.050000`, and the value is passed to the node verbatim.
- Do not run `deadnix --edit` over `comb/*/*.nix`. Paisano type-checks that
  every cell-block file accepts both `inputs` and `cell`, so the headers that
  look unused are load-bearing.
