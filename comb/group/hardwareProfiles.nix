# Platform per group.
{
  inputs,
  cell,
  ...
}: let
  h = inputs.cells.lib.hardwareProfiles;
in {
  gcp-midnight-preview-vali = h.gcp;
  gcp-midnight-preview-rpc = h.gcp;

  gcp-midnight-preview-boot = h.gcp;
  gcp-midnight-preprod-boot = h.gcp;
  gcp-midnight-mainnet-boot = h.gcp;
}
