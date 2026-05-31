{ config, pkgs, lib, ... }:

let
  domain = config.nixmatrix.domain;
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

    # MSC3861 (delegating auth to MAS) requires the `authlib` Python dep, which
    # ships in the "oidc" extra. The module only auto-adds "oidc" when
    # settings.oidc_providers is set — but we enable MSC3861 via extraConfigFiles,
    # so it must be requested explicitly or Synapse refuses to start:
    #   "MSC3861 is enabled but authlib is not installed".
    extras = [ "systemd" "postgres" "url-preview" "oidc" ];

    # Synapse environment file — secrets injected via $SYNAPSE_* env vars.
    # Note: matrix-synapse NixOS module doesn't directly support environmentFile,
    # so we use extraConfigFiles to read secrets from a sops-rendered file.
    # See the extraConfig block below for env var usage workaround.
    extraConfigFiles = [
      # Additional YAML config rendered by sops template (see bottom of this file)
      config.sops.templates."synapse-extra-config".path
    ];

    settings = {
      server_name = domain;  # Matrix IDs are @user:<domain>
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
          # Explicit tls = false: the NixOS listener submodule defaults tls to
          # true, which makes Synapse demand a tls_certificate_path and refuse
          # to start (we terminate TLS at Caddy, so Synapse listeners are plain).
          tls = false;
          resources = [];
        }
      ];

      # MAS handles all authentication — disable Synapse's own auth
      enable_registration = false;
      enable_metrics = true;

      # Appservice registrations. Only the double-puppet registration is listed
      # manually here. Each ENABLED mautrix bridge appends its own registration
      # automatically via the module's registerToSynapse option (correct path +
      # startup ordering), so a disabled bridge contributes nothing and can never
      # block Synapse from starting. Listing the bridge files here unconditionally
      # was a bug: it pointed at paths nothing creates → Synapse FileNotFoundError.
      app_service_config_files = [
        "/var/lib/matrix-synapse/appservices/doublepuppet.yaml"
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

  # Synapse connects as the `synapse` PG user, whose password is set at runtime
  # by postgresql-set-passwords. Without this ordering the first start can race
  # ahead of the password being set and fail auth (recovers on restart, but a
  # clean boot should have zero failed attempts).
  systemd.services.matrix-synapse = {
    after = [ "postgresql-set-passwords.service" ];
    requires = [ "postgresql-set-passwords.service" ];
  };
}
