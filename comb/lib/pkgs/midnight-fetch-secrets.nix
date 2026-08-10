# The boot-time Secret Manager client, run by midnight-secrets.service.
#
# Talks HTTPS in-process (rustls, with the roots the crate bundles), so the
# unit's runtime closure is the binary alone — no curl, jq, coreutils or system
# CA bundle. See ./midnight-fetch-secrets/src/main.rs.
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "midnight-fetch-secrets";
  version = "0.1.0";

  src = ./midnight-fetch-secrets;

  cargoLock.lockFile = ./midnight-fetch-secrets/Cargo.lock;

  meta = {
    description = "Fetch Midnight node secrets from GCP Secret Manager at boot";
    mainProgram = "midnight-fetch-secrets";
    platforms = lib.platforms.linux;
  };
}
