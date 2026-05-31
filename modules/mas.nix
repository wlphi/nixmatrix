{ config, pkgs, lib, ... }:

# Matrix Authentication Service — custom NixOS service.
# No official NixOS module yet (tracking: https://github.com/NixOS/nixpkgs/issues/376738).
# Uses pkgs.matrix-authentication-service (1.16+ in nixpkgs unstable).

let
  domain = config.nixmatrix.domain;
  authDomain = "auth.${domain}";
  masUser = "mas";
  masGroup = "mas";
  masDataDir = "/var/lib/matrix-authentication-service";
  # sops template writes the config here at runtime
  masConfigPath = config.sops.templates."mas-config".path;

  # Authelia upstream OIDC — only wired in when SSO is enabled (nixmatrix.sso.enable).
  # When off, MAS uses its own native login and never references Authelia (whose
  # service + secrets don't exist in that case).
  upstreamOAuth2Block =
    if config.nixmatrix.sso.enable then ''

      # Authelia upstream OIDC (Phase 3).
      # IMPORTANT: http://localhost for discovery_url — HTTPS to co-hosted Authelia fails on self-signed certs.
      # IMPORTANT: fetch_userinfo: true — Authelia doesn't embed claims in the token.
      upstream_oauth2:
        providers:
          - id: "01HQW90Z35CMXFJWQPHC3BGZGA"
            issuer: "https://authelia.${domain}"
            discovery_url: "http://localhost:9091/.well-known/openid-configuration"
            client_id: "mas-client"
            client_secret: "${config.sops.placeholder."authelia/oidc_client_secret"}"
            scope: "openid profile email offline_access"
            token_endpoint_auth_method: "client_secret_basic"
            fetch_userinfo: true
            claims_imports:
              localpart:
                action: force
                template: "{{ user.preferred_username }}"
              displayname:
                action: suggest
                template: "{{ user.name }}"
              email:
                action: force
                template: "{{ user.email }}"
                set_email_verification: always
    '' else "";
in

{
  users.users.${masUser} = {
    isSystemUser = true;
    group = masGroup;
    home = masDataDir;
    createHome = false;
    description = "Matrix Authentication Service";
  };
  users.groups.${masGroup} = { };

  systemd.tmpfiles.rules = [
    # mode 755 is CRITICAL — MAS (uid mas) cannot enter a 700 directory
    "d ${masDataDir} 0755 ${masUser} ${masGroup} -"
  ];

  sops.secrets = {
    # mas_signing_key is referenced by path in the config (key_file) — must be a real file
    "matrix/mas_signing_key"       = { owner = masUser; mode = "0400"; };
    # These are only used as sops template placeholders — declaring once here so the
    # placeholder map is populated; they DON'T also appear in synapse.nix or authelia.nix
    "matrix/mas_secret_key"        = { owner = masUser; };
    # matrix/postgres_password is owned by postgres (postgres.nix) — used here via placeholder
    # matrix/synapse_client_secret is owned by matrix-synapse (synapse.nix) — used here via placeholder
    # authelia/oidc_client_secret is owned by authelia-main (authelia.nix) — used here via placeholder
  };

  # Full MAS config rendered at runtime with secrets injected.
  # mode 0644 is CRITICAL — MAS cannot read a 600 config file.
  # (crash-loop symptom: "missing field `secrets`" — misleading; real cause is EACCES)
  sops.templates."mas-config" = {
    content = ''
      http:
        listeners:
          - name: web
            resources:
              - name: discovery
              - name: human
              - name: oauth
              - name: compat
              - name: graphql
                playground: false
              - name: assets
              - name: adminapi
            binds:
              - address: "127.0.0.1:8080"
          - name: internal
            resources:
              - name: health
            binds:
              - address: "127.0.0.1:8081"

        public_base: "https://${authDomain}/"
        issuer: "https://${authDomain}/"

      database:
        uri: "postgresql://${masUser}:${config.sops.placeholder."matrix/postgres_password"}@localhost/mas"
        auto_migrate: true

      secrets:
        encryption: "${config.sops.placeholder."matrix/mas_secret_key"}"
        keys:
          - kid: "key-1"
            algorithm: rs256
            key_file: "${config.sops.secrets."matrix/mas_signing_key".path}"

      matrix:
        homeserver: "${domain}"
        endpoint: "http://localhost:8008"
        # MUST equal Synapse's msc3861.admin_token (synapse.nix) — MAS presents this
        # when calling Synapse's /_synapse/mas/* admin endpoints. A mismatch makes
        # Synapse reject every MAS admin call with 403 "must only be called by MAS",
        # which breaks user registration (mas-cli) and login.
        secret: "${config.sops.placeholder."matrix/synapse_admin_token"}"

      passwords:
        enabled: true
        minimum_complexity: 3
        schemes:
          - version: 1
            algorithm: argon2id

      account:
        # Open signups are gated by nixmatrix.openRegistration (default off).
        # BOTH this flag and policy.data.registration below must agree, or signups
        # silently fail (a recurring confusion in the upstream Docker project).
        password_registration_enabled: ${lib.boolToString config.nixmatrix.openRegistration}
        password_registration_email_required: false
        password_change_allowed: true
        password_recovery_enabled: false
        account_deactivation_allowed: true

      # CRITICAL: correct key is policy.data.registration (not policy.registration)
      # policy.registration is silently ignored — registration control breaks without this.
      policy:
        data:
          registration:
            enabled: ${lib.boolToString config.nixmatrix.openRegistration}

      email:
        from: '"Matrix" <noreply@${domain}>'
        transport: smtp
        hostname: "localhost"
        port: 25
        mode: plain

      branding:
        service_name: "Matrix"
        policy_uri: "https://${authDomain}/privacy"
        tos_uri: "https://${authDomain}/terms"

      clients:
        # Element Web + Element Desktop
        # http://localhost and http://127.0.0.1 required for Element Desktop native OIDC (RFC 8252)
        - client_id: "01HQW90Z35CMXFJWQPHC3BGZGQ"
          client_auth_method: none
          redirect_uris:
            - "https://element.${domain}"
            - "https://element.${domain}/mobile_guide/"
            - "io.element.app:/callback"
            - "http://localhost"
            - "http://127.0.0.1"

        # FluffyChat
        - client_id: "01FFCHAT00000000000000FC00"
          client_auth_method: none
          redirect_uris:
            - "https://chat.${domain}"
            - "https://chat.${domain}/"
            - "im.fluffychat://login"

        # Ketesa / element-admin
        # CRITICAL: 01ADMN (26 chars) NOT 01ADMIN (25 chars — invalid ULID, silently breaks)
        - client_id: "01ADMN00000000000000000000"
          client_auth_method: none
          redirect_uris:
            - "https://admin.${domain}/"
            - "https://admin.${domain}"

        # Synapse backend (confidential)
        - client_id: "0000000000000000000SYNAPSE"
          client_auth_method: client_secret_basic
          client_secret: "${config.sops.placeholder."matrix/synapse_client_secret"}"
      ${upstreamOAuth2Block}
    '';
    owner = masUser;
    group = masGroup;
    mode = "0644";
  };

  systemd.services.matrix-authentication-service = {
    description = "Matrix Authentication Service";
    after = [
      "network.target"
      "postgresql.service"
      # Must wait for the DB password to actually be set, or the first start
      # races ahead and fails with "password authentication failed for user mas"
      # (it recovers on restart, but a clean boot should have zero failures).
      "postgresql-set-passwords.service"
      "sops-install-secrets.service"
    ];
    requires = [ "postgresql.service" "postgresql-set-passwords.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = masUser;
      Group = masGroup;
      WorkingDirectory = masDataDir;

      # Run database migrations before starting the server
      ExecStartPre = "${pkgs.matrix-authentication-service}/bin/mas-cli database migrate --config ${masConfigPath}";
      ExecStart = "${pkgs.matrix-authentication-service}/bin/mas-cli server --config ${masConfigPath}";

      Restart = "on-failure";
      RestartSec = "5s";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ masDataDir ];
      ProtectHome = true;
    };
  };
}
