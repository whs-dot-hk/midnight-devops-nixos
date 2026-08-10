# Disk layouts.
#
# Both disks a node carries are described here: the root/boot disk
# (`gcp-root`) and the chain-data disk (`gcp-chain-data`). `gcp-root-and-
# chain-data` is the pair, and is what the groups use — with it, disko
# describes the whole machine, so a blank boot disk can be partitioned and
# installed with `nixos-anywhere`/`disko-install` rather than only booting a
# prebuilt NixOS GCE image.
#
# IMPORTANT: importing a disko configuration does NOT format anything. It
# declares the filesystem so NixOS mounts it. Running disko's format script
# against a node that already holds chain data would destroy it; that is an
# explicit operator action, never part of a deploy.
{
  inputs,
  cell,
  ...
}: let
  # Mount options shared by the filesystem and every subvolume on it. disko
  # emits one `fileSystems` entry per mountpoint with exactly these options
  # plus `subvol=`, so they have to be repeated rather than inherited.
  chainDataMountOptions = [
    # Chain databases are write-heavy and compress well; zstd at its default
    # level costs little CPU next to the persistent-disk IO it saves.
    "compress=zstd"
    "noatime"
    # The node must still boot if the data disk is late or absent, otherwise a
    # detached disk turns into an unreachable machine.
    "nofail"
    "x-systemd.device-timeout=30"
  ];

  # The root/boot disk of a GCE instance, UEFI-booting: GPT, a 512M ESP at
  # /boot, and ext4 filling the rest.
  #
  # GCE names the boot disk `persistent-disk-0` unless Terraform sets
  # `boot_disk.device_name`, and the google-guest-configs udev rules turn that
  # into `/dev/disk/by-id/google-persistent-disk-0`.
  #
  # NB: those rules ship with `google-compute-config.nix`, so the symlink exists
  # on a booted node but NOT in a generic installer/kexec environment, where
  # only stock udev has run. When formatting from such an environment, override
  # the device with a path that does exist there:
  #
  #   disko.devices.disk.root.device = lib.mkForce "/dev/nvme0n1";
  #
  # `/dev/sda` (SCSI-attached), `/dev/nvme0n1` (gen-3 machine types such as C3
  # and N4) and `/dev/disk/by-id/scsi-0Google_PersistentDisk_persistent-disk-0`
  # (stock udev, SCSI) are the usual candidates.
  gcp-root = {
    disko.devices.disk.root = {
      type = "disk";
      device = "/dev/disk/by-id/google-persistent-disk-0";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            size = "512M";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              extraArgs = ["-n" "ESP"];
              # The ESP holds the bootloader and kernels and is world-readable
              # by default on vfat; 0077 keeps it root-only and silences
              # systemd-gpt-auto-generator's permissions warning.
              mountOptions = ["umask=0077"];
            };
          };

          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              # The label `google-compute-config.nix` mounts / by. See the
              # `gcp` hardware profile.
              extraArgs = ["-L" "nixos"];
            };
          };
        };
      };
    };

    # NB: nothing extra is needed in initrd for gen-3 machine types, where the
    # persistent disk attaches over NVMe rather than SCSI — `nvme` is already
    # in nixpkgs' default `boot.initrd.availableKernelModules`.
    #
    # The two collisions this layout has with `google-compute-config.nix` (the
    # root device and the BIOS-mode GRUB target) are resolved in the `gcp`
    # hardware profile, next to the import that causes them.
  };

  # A node with a dedicated chain-data persistent disk.
  #
  # Modeled on disko's example/btrfs-subvolumes.nix, minus the GPT table and
  # ESP: this is a data disk, not a boot disk, so the device is formatted whole
  # and mounted directly with no partition table in between.
  #
  # btrfs rather than a single flat filesystem because the three consumers of
  # this disk grow and fail independently:
  #
  #   /node     midnight-node database    (services.midnight-node.basePath)
  #   /cardano  cardano-node database     (services.cardano-node.databasePath)
  #   /dbsync   db-sync ledger state      (services.cardano-db-sync.stateDir)
  #
  # Subvolumes give each one its own snapshot boundary and quota target, and
  # make the sibling rule structural: db-sync's state directory *cannot* end up
  # inside cardano-node's --database-path, which is what produces
  # `NoDbMarkerAndNotEmpty` and a node that never starts.
  gcp-chain-data = {
    disko.devices.disk.chain-data = {
      type = "disk";
      # Stable across instance recreation; /dev/sdb and /dev/nvme0n2 are not.
      device = "/dev/disk/by-id/google-chain-data";
      content = {
        type = "btrfs";
        # Label kept stable so any by-label lookups still resolve. btrfs caps
        # labels at 255 bytes, so the 12-character XFS limit that used to
        # constrain this name no longer applies.
        extraArgs = ["-L" "midnightdata"];

        # NB: disko's example passes `-f` here to clobber whatever is on the
        # partition. That is deliberately omitted — this disk holds chain data.
        # disko's btrfs create step already skips mkfs when `blkid` reports any
        # existing TYPE=, and `-f` is the one flag that would override that
        # guard on an empty-looking-but-not-empty device.

        # The filesystem root (subvol=/) is mounted at the disk's mount point,
        # matching `midnight.dataDir`'s contract ("mount point of the chain-data
        # disk") and giving operators one path from which to manage snapshots.
        mountpoint = "/var/lib/midnight";
        mountOptions = chainDataMountOptions;

        subvolumes = {
          "/node" = {
            mountpoint = "/var/lib/midnight/node";
            mountOptions = chainDataMountOptions;
          };

          "/cardano" = {
            mountpoint = "/var/lib/midnight/cardano";
            mountOptions = chainDataMountOptions;
          };

          "/dbsync" = {
            mountpoint = "/var/lib/midnight/dbsync";
            mountOptions = chainDataMountOptions;
          };
        };
      };
    };
  };
in {
  inherit gcp-root gcp-chain-data;

  # The whole machine: boot disk plus chain-data disk. This is what the groups
  # use, and what makes `nixos-anywhere --flake .#<host>` able to install onto
  # a blank instance — disko has to describe every disk it is expected to
  # partition, root included.
  gcp-root-and-chain-data = {
    imports = [gcp-root gcp-chain-data];
  };

  # A node that keeps chain data on the root disk. Fine for a throwaway relay,
  # not for anything that has to survive an instance replacement.
  gcp-root-only = gcp-root;
}
