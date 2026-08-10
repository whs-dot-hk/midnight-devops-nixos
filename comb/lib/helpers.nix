# Shared helpers. `group.new` is the entry point every cell uses to declare a
# fleet of identical nodes.
{
  inputs,
  cell,
  ...
}: let
  # A fully-configured nixpkgs, overlay included.
  #
  # divnix/hive's beeModule refuses `nixpkgs.overlays` inside a host config and
  # asks for an already-instantiated nixpkgs instead, so the overlay carrying
  # midnight-node / cardano-node-bin / cardano-db-sync-bin is applied here,
  # once, for every host in the fleet.
  mkPkgs = system:
    import inputs.nixpkgs.path {
      inherit system;
      overlays = [(import ./pkgs/overlay.nix)];
      config = {};
    };

  supportedSystems = ["x86_64-linux"];

  bySystem = inputs.nixpkgs.lib.genAttrs supportedSystems mkPkgs;

  # The shape hive's `bee.pkgs` option wants: an instantiated nixpkgs (its
  # type check looks for `path`) that ALSO carries per-system attributes (its
  # `apply` picks `x.${system}`). That is exactly what paisano's deSystemize
  # produces for `<input>.legacyPackages`, which is what the hive-group README
  # passes — reproduce it here so the overlay comes along.
  pkgs = bySystem // bySystem.x86_64-linux;

  defaultSecretSuffixes = {
    node = "secrets";
    validatorKeys = "validator-keys";
    validatorSeedPhrases = "validator-seed-phrases";
    relayKeys = "relay-keys";
    bootNodeKeys = "boot-node-keys";
    db = "db-credentials";
  };
in {
  # Fleet declaration. These are only defaults — an importing flake can
  # override `stateVersion` and `system` per call. `prefix` has none: it has to
  # agree with the name of the cell declaring the group, so every caller passes
  # it (see ../gcp-midnight-preview/groups.nix).
  group.new = args:
    inputs.hive-group.group.new ({
        inherit pkgs;
        stateVersion = "26.05";
        system = "x86_64-linux";
      }
      // args);

  # Derive a node's Secret Manager IDs from one base name, usually the
  # hostname. Every deployment names its secrets differently, so the scheme is
  # an argument rather than something baked into a module:
  #
  #   secretIds { base = config.networking.hostName; }
  #     => { node = "<host>-secrets"; db = "<host>-db-credentials"; ... }
  #
  # Feed the result straight to `midnight.gcp.secrets`; drop the keys a node
  # type has no use for.
  secretIds = {
    base,
    prefix ? "",
    # Prepended to the db ID alone, for schemes that scope it differently.
    dbPrefix ? prefix,
    suffixes ? {},
    separator ? "-",
  }: let
    s = defaultSecretSuffixes // suffixes;
    id = p: suffix: "${p}${base}${separator}${suffix}";
  in {
    node = id prefix s.node;
    validatorKeys = id prefix s.validatorKeys;
    validatorSeedPhrases = id prefix s.validatorSeedPhrases;
    relayKeys = id prefix s.relayKeys;
    bootNodeKeys = id prefix s.bootNodeKeys;
    db = id dbPrefix s.db;
  };
}
