{ config, pkgs, lib, ... }:

let
  domain = "mair.io";
  matrixDomain = "matrix.${domain}";
  authDomain = "auth.${domain}";
  adminDomain = "admin.${domain}";
in

{
  sops.secrets = {
    # Owned here — used in sops template placeholders for the Synapse extra config
    "matrix/synapse_client_secret" = { owner = "matrix-synapse"; };
    "matrix/synapse_admin_token"   = { owner = "matrix-synapse"; };
    # matrix/postgres_password is owned by postgres (postgres.nix) — used here via placeholder
  };

  # Synapse reads the client_secret from an environment variable injected via
  # EnvironmentFile. This avoids putting secrets in the Nix-store-resident config.
  sops.templates."synapse-secrets-env" = {
    content = ''
      SYNAPSE_CLIENT_SECRET=${config.sops.placeholder."matrix/synapse_client_secret"}
      SYNAPSE_ADMIN_TOKEN=${config.sops.placeholder."matrix/synapse_admin_token"}
      POSTGRES_PASSWORD=${config.sops.placeholder."matrix/postgres_password"}
    '';
    owner = "matrix-synapse";
    mode = "0400";
  };

  services.matrix-synapse = {
    enable = true;

    # Synapse environment file — secrets injected via $SYNAPSE_* env vars.
    # Note: matrix-synapse NixOS module doesn't directly support environmentFile,
    # so we use extraConfigFiles to read secrets from a sops-rendered file.
    # See the extraConfig block below for env var usage workaround.
    extraConfigFiles = [
      # Additional YAML config rendered by sops template (see bottom of this file)
      config.sops.templates."synapse-extra-config".path
    ];

    settings = {
      server_name = domain;  # "mair.io" — Matrix IDs are @user:mair.io
      public_baseurl = "https://${matrixDomain}";

      # Listeners: HTTP (Caddy-proxied) + metrics (Prometheus, internal only)
      listeners = [
        {
          port = 8008;
          bind_addresses = [ "127.0.0.1" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [{
            names = [ "client" "federation" ];
            compress = false;
          }];
        }
        {
          port = 9092;
          bind_addresses = [ "127.0.0.1" ];
          type = "metrics";
          resources = [];
        }
      ];

      # MAS handles all authentication — disable Synapse's own auth
      enable_registration = false;
      enable_metrics = true;

      # Appservice registrations (bridges + double puppet)
      app_service_config_files = [
        "/var/lib/matrix-synapse/appservices/doublepuppet.yaml"
        "/var/lib/matrix-synapse/appservices/telegram-registration.yaml"
        "/var/lib/matrix-synapse/appservices/whatsapp-registration.yaml"
        "/var/lib/matrix-synapse/appservices/signal-registration.yaml"
        "/var/lib/matrix-synapse/appservices/discord-registration.yaml"
      ];

      # PostgreSQL connection — password read from sops-rendered extra config
      database = {
        name = "psycopg2";
        args = {
          user = "synapse";
          database = "synapse";
          host = "localhost";
          cp_min = 5;
          cp_max = 10;
          # password is injected via extraConfigFiles (see synapse-extra-config template)
        };
      };

      # Rate limiting — increase burst for Element Call
      rc_message = {
        per_second = 0.5;
        burst_count = 15;
      };

      # Element Call support
      max_event_delay_duration = "24h";

      experimental_features = {
        msc3266_enabled = true;
        msc4222_enabled = true;
        msc4140_enabled = true;
        # msc3861 (MAS delegation) is injected via sops extraConfigFiles below
      };

      # Media store
      media_store_path = "/var/lib/matrix-synapse/media";
      max_upload_size = "100M";

      # Federation
      federation_domain_whitelist = null;  # allow all federation
      allow_public_rooms_over_federation = true;
    };

  };

  # The sops template renders the Synapse extra config file with secrets.
  # matrix-synapse reads this via extraConfigFiles above.
  sops.templates."synapse-extra-config" = {
    content = ''
      # MAS authentication delegation (MSC3861)
      experimental_features:
        msc3861:
          enabled: true
          issuer: "https://${authDomain}/"
          client_id: "0000000000000000000SYNAPSE"
          client_auth_method: client_secret_basic
          client_secret: "${config.sops.placeholder."matrix/synapse_client_secret"}"
          admin_token: "${config.sops.placeholder."matrix/synapse_admin_token"}"

      # PostgreSQL password (separate from settings.database.args to keep out of Nix store)
      database:
        name: psycopg2
        args:
          user: synapse
          password: "${config.sops.placeholder."matrix/postgres_password"}"
          database: synapse
          host: localhost
          cp_min: 5
          cp_max: 10
    '';
    owner = "matrix-synapse";
    mode = "0400";
  };

  # Ensure appservice directory exists with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/matrix-synapse/appservices 0750 matrix-synapse matrix-synapse -"
  ];
}
