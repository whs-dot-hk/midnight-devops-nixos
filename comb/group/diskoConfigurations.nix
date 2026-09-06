# Disk layout per group.
{
  inputs,
  cell,
  ...
}: let
  d = inputs.cells.lib.diskoConfigurations;
in {
  gcp-midnight-preview-vali = d.gcp-root-and-chain-data;
  gcp-midnight-preview-rpc = d.gcp-root-and-chain-data;

  # Bootnodes run the full Cardano stack too, so they carry the same pair of
  # disks as everything else.
  gcp-midnight-preview-boot = d.gcp-root-and-chain-data;
  gcp-midnight-preprod-boot = d.gcp-root-and-chain-data;
  gcp-midnight-mainnet-boot = d.gcp-root-and-chain-data;
}
