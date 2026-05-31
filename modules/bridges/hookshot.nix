{ config, pkgs, lib, ... }:

# matrix-hookshot — bridges Matrix to GitHub, GitLab, Jira, generic webhooks,
# and RSS feeds. NOT a chat-network bridge like the mautrix ones.
#
# Opt-in: nixmatrix.bridges.hookshot.enable (default off).
#
# Unlike the mautrix bridges, hookshot has no registerToSynapse helper, so we
# render its appservice registration from sops (like doublepuppet) and add it to
# Synapse's app_service_config_files below. Synapse delivers events to hookshot
# at url: http://localhost:9993.
#
# Per-service integrations (GitHub app, GitLab webhooks, Jira, …) are configured
# at runtime from the hookshot bot in a Matrix room — they need no static config
# here. Generic incoming webhooks are enabled out of the box on localhost:9000;
# expose that path through your reverse proxy if you want to receive them.

let
  domain = config.nixmatrix.domain;
  appservicePort = 9993; # Synapse → hookshot
  webhookPort = 9000;    # inbound webhooks (localhost; proxy to expose)
in

lib.mkIf config.nixmatrix.bridges.hookshot.enable {
  sops.secrets = {
    # Appservice tokens shared between Synapse and hookshot. Owned by
    # matrix-synapse because Synapse reads the registration file directly.
    "bridges/hookshot_as_token" = { owner = "matrix-synapse"; };
    "bridges/hookshot_hs_token" = { owner = "matrix-synapse"; };
  };

  # Appservice registration, rendered with secrets and read by Synapse on start.
  # (Also read by hookshot itself — both sides must see the same tokens.)
  sops.templates."hookshot-registration" = {
    content = ''
      id: matrix-hookshot
      as_token: "${config.sops.placeholder."bridges/hookshot_as_token"}"
      hs_token: "${config.sops.placeholder."bridges/hookshot_hs_token"}"
      namespaces:
        rooms: []
        users:
          - regex: "@_webhooks_.*:${domain}"
            exclusive: true
          - regex: "@hookshot:${domain}"
            exclusive: true
      sender_localpart: hookshot
      url: "http://localhost:${toString appservicePort}"
      rate_limited: false
    '';
    path = "/var/lib/matrix-synapse/appservices/hookshot-registration.yaml";
    owner = "matrix-synapse";
    group = "matrix-synapse";
    mode = "0600";
  };

  # Synapse must load the hookshot registration. The list in synapse.nix only
  # has doublepuppet; append this when hookshot is enabled (list-merges).
  services.matrix-synapse.settings.app_service_config_files = [
    config.sops.templates."hookshot-registration".path
  ];

  services.matrix-hookshot = {
    enable = true;
    # hookshot reads the same registration file Synapse does.
    registrationFile = config.sops.templates."hookshot-registration".path;
    settings = {
      bridge = {
        domain = domain;
        url = "http://localhost:8008";
        mediaUrl = "https://matrix.${domain}";
        port = appservicePort;
        bindAddress = "127.0.0.1";
      };
      # Generic incoming webhooks, on localhost. Expose /webhook through your
      # reverse proxy (or a dedicated subdomain) if you want to receive them.
      generic = {
        enabled = true;
        urlPrefix = "https://matrix.${domain}/webhook";
      };
      listeners = [
        {
          port = webhookPort;
          bindAddress = "127.0.0.1";
          resources = [ "webhooks" ];
        }
      ];
      # passFile defaults to /var/lib/matrix-hookshot/passkey.pem (auto-generated).
    };
  };
}
