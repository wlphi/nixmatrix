{ config, pkgs, lib, ... }:

let
  domain = "mair.io";
  autheliaPort = 9091;
in

{
  sops.secrets = {
    "authelia/jwt_secret"              = { owner = "authelia-main"; };
    "authelia/session_secret"          = { owner = "authelia-main"; };
    "authelia/storage_encryption_key"  = { owner = "authelia-main"; };
    "authelia/oidc_client_secret"      = { owner = "authelia-main"; };
    # matrix/postgres_password is owned by postgres (postgres.nix).
    # Authelia needs its own readable copy — rendered via sops template below.
  };

  # Authelia needs to read the DB password as a file but can't own the postgres-owned
  # master secret. A sops template writes a per-service copy owned by authelia-main.
  sops.templates."authelia-pg-password" = {
    content = config.sops.placeholder."matrix/postgres_password";
    owner = "authelia-main";
    mode = "0400";
  };

  services.authelia.instances.main = {
    enable = true;

    secrets = {
      jwtSecretFile              = config.sops.secrets."authelia/jwt_secret".path;
      sessionSecretFile          = config.sops.secrets."authelia/session_secret".path;
      storageEncryptionKeyFile   = config.sops.secrets."authelia/storage_encryption_key".path;
      # oidcHmacSecretFile and oidcIssuerPrivateKeyFile are optional but recommended
      # for production OIDC; omit if using just client_secret_basic.
    };

    settings = {
      theme = "dark";
      default_redirection_url = "https://element.${domain}";
      default_2fa_method = "totp";

      server.address = "tcp://127.0.0.1:${toString autheliaPort}";

      log.level = "info";

      session = {
        name = "authelia_session";
        domain = domain;
        expiration = "1h";
        inactivity = "5m";
        redis = {
          host = "127.0.0.1";
          port = 6379;  # services.redis.servers.authelia
        };
      };

      storage.postgres = {
        address = "tcp://localhost:5432";
        database = "authelia";
        username = "authelia";
        # password_file is set via secrets.storageEncryptionKeyFile above;
        # for the DB connection password, use passwordFile
        password_file = config.sops.templates."authelia-pg-password".path;
      };

      access_control = {
        default_policy = "deny";
        rules = [
          {
            # MAS must reach Authelia's OIDC endpoints without 2FA
            domain = "authelia.${domain}";
            policy = "one_factor";
          }
          {
            # Monitoring behind one_factor auth
            domain = "monitoring.${domain}";
            policy = "one_factor";
          }
        ];
      };

      authentication_backend.file = {
        path = "/var/lib/authelia-main/users.yaml";
        password.algorithm = "argon2id";
      };

      notifier.filesystem = {
        filename = "/var/lib/authelia-main/notifications.txt";
      };

      # OIDC provider — MAS is the client
      identity_providers.oidc = {
        cors = {
          endpoints = [ "authorization" "token" "revocation" "introspection" "userinfo" ];
          allowed_origins_from_client_redirect_uris = true;
        };
        clients = [{
          client_id = "mas-client";
          client_name = "Matrix Authentication Service";
          # Client secret hash — generate with: authelia crypto hash generate argon2 --password '<secret>'
          # Or provide plaintext and let Authelia hash it (check module docs).
          # For sops injection: use client_secret_file if supported, else use the secrets.yaml
          client_secret = "$plaintext$REPLACE_WITH_AUTHELIA_OIDC_CLIENT_SECRET";
          # Note: replace above with actual hashed secret or use the secrets mechanism.
          # The oidc_client_secret from sops.secrets needs to be injected differently —
          # Authelia's NixOS module may support secretFile for OIDC clients; check the module.
          public = false;
          authorization_policy = "one_factor";
          redirect_uris = [
            "https://auth.${domain}/upstream/callback/01HQW90Z35CMXFJWQPHC3BGZGA"
          ];
          scopes = [ "openid" "profile" "email" "offline_access" ];
          response_types = [ "code" ];
          grant_types = [ "authorization_code" "refresh_token" ];
          token_endpoint_auth_method = "client_secret_basic";
          userinfo_signing_algorithm = "none";
        }];
      };
    };
  };
}
