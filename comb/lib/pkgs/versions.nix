# Pinned upstream artifacts.
#
# Everything here is a public release artifact — no credentials, no internal
# hostnames. Bump a version and its hash together; `nix build` fails loudly if
# the two disagree.
#
# To refresh a hash without nix:
#   curl -sSL <url> | sha256sum | cut -d' ' -f1 | xxd -r -p | base64 -w0
# and prefix the result with "sha256-".
{
  midnight-node = {
    version = "1.0.1";
    # The upstream tag is `node-<version>`; the asset drops the prefix.
    urlTemplate = "https://github.com/midnightntwrk/midnight-node/releases/download/node-@version@/midnight-node-@version@-linux-amd64.tar.gz";
    hash = "sha256-fJEfZOFkNuEAWDL4W1Q42c/jiFeCXCEpeQK1Y1NP7Nk=";
  };

  cardano-node = {
    version = "11.0.1";
    urlTemplate = "https://github.com/IntersectMBO/cardano-node/releases/download/@version@/cardano-node-@version@-linux-amd64.tar.gz";
    hash = "sha256-QOiKVDVkJRM4xIiO95/eUdIwbBi0isMIyeqzIg46E/A=";
  };

  cardano-db-sync = {
    version = "13.7.1.0";
    urlTemplate = "https://github.com/IntersectMBO/cardano-db-sync/releases/download/@version@/cardano-db-sync-@version@-linux.tar.gz";
    hash = "sha256-LjW9/pFJCsr6Awr6B7uaUEpu1I2Ppe6w7O5lsDSXW3U=";
  };

  # db-sync-config.json is NOT part of the cardano-node release tarball, so it
  # is fetched separately, from the Cardano environments book.
  # NB: this URL is mutable upstream; a hash mismatch here means the served
  # file changed, not that anything is broken locally.
  db-sync-config = {
    preview = "sha256-MVccFM94pCZtZzp+AC8bg5VYn3zRzgpiJto/QXJRseE=";
    preprod = "sha256-uD9ulm1LSsSph8H26TmGnGTILyWDsqjRy4Ccf9/NMEg=";
    mainnet = "sha256-kJS9uadVwjvo7LcbgDYugPs0Fdem/+nSVkaEgHimX2M=";
  };
}
