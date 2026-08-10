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
}
