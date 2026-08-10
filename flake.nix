{
  description = "Midnight and Cardano nodes on NixOS, organised with divnix/hive";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    hive.url = "github:divnix/hive";
    hive-group.url = "github:whs-dot-hk/hive-group";
    colmena.url = "github:zhaofengli/colmena";
    disko.url = "github:nix-community/disko";

    hive.inputs.nixpkgs.follows = "nixpkgs";
    hive.inputs.colmena.follows = "colmena";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    hive,
    self,
    ...
  } @ inputs:
    hive.growOn {
      inherit inputs;

      cellsFrom = ./comb;

      systems = ["x86_64-linux"];

      cellBlocks = [
        hive.blockTypes.nixosConfigurations
        hive.blockTypes.colmenaConfigurations
        hive.blockTypes.diskoConfigurations

        {
          name = "groups";
          type = "groups";
        }
        {
          name = "helpers";
          type = "helpers";
        }
        {
          name = "hardwareProfiles";
          type = "hardwareProfile";
        }
        {
          name = "nixosModules";
          type = "nixosModule";
        }
        {
          name = "nixosProfiles";
          type = "nixosProfile";
        }
        {
          name = "packages";
          type = "package";
          ci.build = true;
        }
      ];
    }
    {
      # `colmena apply` reads this: the evaluated hive schema.
      colmenaHive = hive.collect self "colmenaConfigurations";
    };
}
