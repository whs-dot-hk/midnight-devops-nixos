# Overlay exposing the node packages on `pkgs`.
#
# divnix/hive's beeModule deliberately blocks `nixpkgs.overlays` inside a host
# config and asks you to hand it an already-configured nixpkgs instead — so
# this overlay is applied once, in comb/lib/helpers.nix, when building the
# `bee.pkgs` passed to every host.
#
# Names are suffixed `-bin` where nixpkgs already ships a from-source package
# of the same name, so it is always obvious which one a host is running.
final: _prev: import ./. {pkgs = final;}
