{ config, pkgs, lib, ... }:

# Authelia — optional SSO / upstream OIDC provider for MAS (Phase 3).
#
# Wiring (see mas.nix upstream_oauth2):
#   MAS  ──OIDC──▶  Authelia (client_id "mas-client")
#   Users authenticate at authelia.<domain>, MAS consumes the identity.
#
# Secrets (all from sops):
#   jwt_secret, session_secret, storage_encryption_key  — core Authelia secrets
#   oidc_hmac_secret                                     — signs OIDC tokens
#   oidc_issuer_private_key                              — RSA key; the module
#       derives the required OIDC `jwks` from it automatically
#   oidc_client_secret                                   — hashed, shared with MAS
#   matrix/postgres_password                             — DB connection (via env)

let
  domain = config.nixmatrix.domain;
  autheliaPort = 9091;
in

lib.mkIf config.nixmatrix.sso.enable {
  sops.secrets = {
    "authelia/jwt_secret"              = { owner = "authelia-main"; };
    "authelia/session_secret"          = { owner = "authelia-main"; };
    "authelia/storage_encryption_key"  = { owner = "authelia-main"; };
    "authelia/oidc_hmac_secret"        = { owner = "authelia-main"; };
    "authelia/oidc_issuer_private_key" = { owner = "authelia-main"; };
    # oidc_client_secret is the HASHED client secret (see secrets.yaml notes).
    "authelia/oidc_client_secret"      = { owner = "authelia-main"; };
    # matrix/postgres_password is owned by postgres (postgres.nix).
  };

  # Authelia reads the Postgres password from an env var pointing at a file.
  # It can't own the postgres-owned master secret, so render a per-service copy.
  sops.templates."authelia-pg-password" = {
    content = config.sops.placeholder."matrix/postgres_password";
    owner = "authelia-main";
    mode = "0400";
  };

  # The DB connection password and the OIDC client secret are injected via
  # environment, not via the (world-readable) settings file.
  sops.templates."authelia-env" = {
    content = ''
      AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE=${config.sops.templates."authelia-pg-password".path}
    '';
    owner = "authelia-main";
    mode = "0400";
  };

  services.authelia.instances.main = {
    enable = true;

    secrets = {
      jwtSecretFile            = config.sops.secrets."authelia/jwt_secret".path;
      sessionSecretFile        = config.sops.secrets."authelia/session_secret".path;
      storageEncryptionKeyFile = config.sops.secrets."authelia/storage_encryption_key".path;
      oidcHmacSecretFile       = config.sops.secrets."authelia/oidc_hmac_secret".path;
      # The module derives the required OIDC `jwks` entry from this key.
      oidcIssuerPrivateKeyFile = config.sops.secrets."authelia/oidc_issuer_private_key".path;
    };

    # Pulls in AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE.
    environmentVariables = { };
    settingsFiles = [ ];

    settings = {
      theme = "dark";
      # NB: no top-level default_redirection_url — with the multi-domain
      # `session.cookies` config below, the redirection URL must be set
      # per-cookie only; setting both fails validation.
      default_2fa_method = "totp";

      server.address = "tcp://127.0.0.1:${toString autheliaPort}";

      log.level = "info";

      session = {
        name = "authelia_session";
        # v4.38+ multi-domain cookie config (the old flat `domain` is deprecated).
        cookies = [{
          domain = domain;
          authelia_url = "https://authelia.${domain}";
          default_redirection_url = "https://element.${domain}";
        }];
        expiration = "1h";
        inactivity = "5m";
        redis = {
          host = "127.0.0.1";
          port = 6379; # services.redis.servers.authelia
        };
      };

      storage.postgres = {
        address = "tcp://localhost:5432";
        database = "authelia";
        username = "authelia";
        # password comes from AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE (env), not here.
      };

      access_control = {
        default_policy = "deny";
        rules = [
          { domain = "authelia.${domain}"; policy = "one_factor"; }
          { domain = "monitoring.${domain}"; policy = "one_factor"; }
        ];
      };

      authentication_backend.file = {
        path = "/var/lib/authelia-main/users.yaml";
        password.algorithm = "argon2id";
      };

      notifier.filesystem = {
        filename = "/var/lib/authelia-main/notifications.txt";
      };

      # OIDC provider — MAS is the client.
      identity_providers.oidc = {
        # `jwks` is supplied automatically by the module from oidcIssuerPrivateKeyFile.
        cors = {
          endpoints = [ "authorization" "token" "revocation" "introspection" "userinfo" ];
          allowed_origins_from_client_redirect_uris = true;
        };
        clients = [{
          client_id = "mas-client";
          client_name = "Matrix Authentication Service";
          # Shared secret with MAS. The `$plaintext$` prefix tells Authelia this
          # is a plaintext secret (same value MAS sends as its upstream
          # client_secret). Authelia accepts it (warns it would prefer a hash —
          # harmless). Both sides therefore use authelia/oidc_client_secret.
          # NB: "$plaintext$" + placeholder via concatenation — a literal
          # "$plaintext$${...}" would be Nix's escape for a literal ${ and skip
          # the interpolation entirely.
          client_secret = "$plaintext$" + config.sops.placeholder."authelia/oidc_client_secret";
          public = false;
          authorization_policy = "one_factor";
          redirect_uris = [
            "https://auth.${domain}/upstream/callback/01HQW90Z35CMXFJWQPHC3BGZGA"
          ];
          scopes = [ "openid" "profile" "email" "offline_access" ];
          response_types = [ "code" ];
          grant_types = [ "authorization_code" "refresh_token" ];
          token_endpoint_auth_method = "client_secret_basic";
          userinfo_signed_response_alg = "none";
        }];
      };
    };
  };

  # Inject the DB password env file into the unit (the module doesn't template
  # arbitrary settings values, so the connection password rides in via env),
  # and order after the password is actually set in Postgres — otherwise the
  # first start races ahead and fails auth (recovers on restart, but a clean
  # boot should have zero failed attempts).
  systemd.services.authelia-main = {
    serviceConfig.EnvironmentFile = config.sops.templates."authelia-env".path;
    after = [ "postgresql-set-passwords.service" ];
    requires = [ "postgresql-set-passwords.service" ];
    # The file auth backend needs a NON-EMPTY users.yaml on first boot — Authelia
    # rejects both a missing file and an empty `users: {}` ("non zero value
    # required"), failing its startup check. Seed one example user so the optional
    # SSO starts cleanly out of the box; never clobber an existing DB (operators
    # replace this and add real accounts via `authelia crypto hash generate`).
    # Example login: admin / changeme  — CHANGE THIS before exposing Authelia.
    preStart = lib.mkBefore ''
      users_file=/var/lib/authelia-main/users.yaml
      if [ ! -e "$users_file" ]; then
        cat > "$users_file" <<'USERS'
      users:
        admin:
          displayname: "Example Admin (CHANGE ME)"
          # password is "changeme" — replace via: authelia crypto hash generate argon2 --password '<new>'
          password: "$argon2id$v=19$m=65536,t=3,p=4$LmQX39eWJfRvnIWw4s6zlQ$0h1ZitRciCev+9hRxDYPlPsIEXujs6lkoZ/LjR5SerM"
          email: admin@localhost
          groups:
            - admins
      USERS
        # NB: the surrounding Nix indented string already strips the common
        # leading indentation at build time, so the heredoc lands as valid YAML
        # (users key at column 0). Do NOT strip leading whitespace here.
        chmod 600 "$users_file"
      fi
    '';
  };
}
