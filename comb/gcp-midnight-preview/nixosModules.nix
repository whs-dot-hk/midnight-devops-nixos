# Generated per-instance targets for every group in ./groups.nix.
# Add a line here whenever a group is added.
{
  inputs,
  cell,
  ...
} @ a:
{}
// (cell.groups.vali.nixosModules a)
// (cell.groups.rpc.nixosModules a)
