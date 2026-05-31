{ config, pkgs, lib, ... }:

# Double puppet appservice registration.
#
# The double puppet appservice lets bridges act as Matrix users (puppet accounts).
# It is NOT a running service — it is just an appservice registration that Synapse loads.
#
# CRITICAL: url must be null — a real URL causes Synapse to send transaction callbacks
# for every puppeted event, triggering retry storms and log flooding.
#
# The registration file is rendered from sops secrets via a sops template.
# Synapse reads it on startup via app_service_config_files (set in synapse.nix).

let
  domain = config.nixmatrix.domain;
in

{
  sops.secrets = {
    "bridges/doublepuppet_as_token" = { owner = "matrix-synapse"; };
    "bridges/doublepuppet_hs_token" = { owner = "matrix-synapse"; };
  };

  sops.templates."doublepuppet-registration" = {
    content = ''
      id: doublepuppet
      url: null
      as_token: "${config.sops.placeholder."bridges/doublepuppet_as_token"}"
      hs_token: "${config.sops.placeholder."bridges/doublepuppet_hs_token"}"
      sender_localpart: doublepuppet
      rate_limited: false
      namespaces:
        users:
          - regex: "@.*:${domain}"
            exclusive: false
    '';
    path = "/var/lib/matrix-synapse/appservices/doublepuppet.yaml";
    owner = "matrix-synapse";
    group = "matrix-synapse";
    mode = "0600";
  };
}
