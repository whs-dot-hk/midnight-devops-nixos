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
}
