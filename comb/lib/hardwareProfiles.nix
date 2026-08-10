# Hardware / platform profiles.
{
  inputs,
  cell,
  ...
}: {
  # Google Compute Engine guest.
  #
  # nixpkgs' google-compute-config.nix already declares everything a GCE
  # instance needs — the ext4 root on /dev/disk/by-label/nixos with
  # autoResize, GRUB on /dev/sda, serial console, the guest agent, OS Login,
  # the metadata host entry and the 1460 MTU. Reuse it rather than
  # reimplementing it.
  #
  # It assumes the root disk is a prebuilt image it does not own, though, so
  # the two places it hard-codes that assumption are overridden below. Both
  # collide with the `gcp-root` disko configuration, which describes the boot
  # disk declaratively (GPT + ESP, UEFI). See ./diskoConfigurations.nix.
  gcp = {
    lib,
    modulesPath,
    ...
  }: {
    imports = [
      (modulesPath + "/virtualisation/google-compute-config.nix")
    ];

    # It sets `fileSystems."/".device = "/dev/disk/by-label/nixos"`, disko sets
    # `/dev/disk/by-partlabel/disk-root-root`; neither is a default, so the
    # module system reports conflicting definitions. Both name the same
    # filesystem — the ext4 root is created with `-L nixos` — so pick the
    # label, which is what the rest of the GCE module expects (`autoResize`
    # resolves it from initrd) and leaves behaviour unchanged.
    fileSystems."/".device = lib.mkForce "/dev/disk/by-label/nixos";

    # It also installs GRUB in BIOS mode on /dev/sda. There is no BIOS boot
    # partition in this layout, so point GRUB at the ESP instead. Installed as
    # removable (/EFI/BOOT/BOOTX64.EFI) because GCE does not persist NVRAM boot
    # entries — the same thing google-compute-image.nix does for `efi = true`.
    boot.loader.grub = {
      device = lib.mkForce "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
    };

    # google-compute-config.nix turns the NixOS firewall off in favour of GCP's
    # (`mkDefault false`). Terraform still owns the VPC firewall rules, but a
    # chain node holding validator keys is worth defending twice — the
    # `common` profile re-enables it, and the node-type profiles open exactly
    # the ports that node is supposed to serve.

    # Only the guest agent's account daemon needs mutable users; everything
    # else in this fleet is declarative.
    users.mutableUsers = lib.mkDefault false;
  };
}
