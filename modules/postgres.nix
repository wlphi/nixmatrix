{ config, pkgs, lib, ... }:

{
  sops.secrets = {
    "matrix/postgres_password" = { owner = "postgres"; group = "postgres"; };
    # Bridge DB users use socket peer auth — no passwords needed here.
  };

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    settings = {
      max_connections = 100;
      shared_buffers = "256MB";
      log_timezone = "UTC";
    };

    # Allow local (peer) connections from the postgres unix socket,
    # and password-authenticated TCP connections from localhost only.
    authentication = lib.mkOverride 10 ''
      local  all  all                   peer
      host   all  all  127.0.0.1/32     scram-sha-256
      host   all  all  ::1/128          scram-sha-256
    '';

    ensureDatabases = [
      "synapse"
      "mas"
      # Bridge DB names match the NixOS service user names — required for ensureDBOwnership
      # and for socket peer auth (OS user = PG user = DB name convention)
      "mautrix-telegram"
      "mautrix-whatsapp"
      "mautrix-signal"
      "mautrix-discord"
      "authelia"
    ];

    # Per-service users — each service only accesses its own database.
    # Passwords are set at runtime via postgresql-set-passwords.service (see below).
    # Using per-bridge users instead of a shared `synapse` user (security hardening).
    ensureUsers = [
      { name = "synapse";           ensureDBOwnership = true; }
      { name = "mas";               ensureDBOwnership = true; }
      # Bridge users match the NixOS service user names — enables socket peer auth
      # (OS user mautrix-telegram = PostgreSQL user mautrix-telegram, no password needed)
      { name = "mautrix-telegram";  ensureDBOwnership = true; }
      { name = "mautrix-whatsapp";  ensureDBOwnership = true; }
      { name = "mautrix-signal";    ensureDBOwnership = true; }
      { name = "mautrix-discord";   ensureDBOwnership = true; }
      { name = "authelia";          ensureDBOwnership = true; }
    ];

    initdbArgs = [ "--encoding=UTF-8" "--lc-collate=C" "--lc-ctype=C" ];
  };

  # Set PostgreSQL user passwords from sops secrets at runtime.
  # Uses pkgs.writeShellScript so the script lives in its own store path,
  # avoiding Nix/bash string-escaping conflicts ('' in bash comments terminates
  # Nix indented strings; ${var} bash substitution conflicts with Nix interpolation).
  systemd.services.postgresql-set-passwords =
    let
      # Each single-quote in the password is doubled for SQL literal safety.
      # \x27 is the hex escape for ' — avoids having '' in the Nix string.
      pgSetPasswordsScript = pkgs.writeShellScript "pg-set-passwords" ''
        set -euo pipefail
        set_password() {
          local user=$1
          local secret_file=$2
          local password escaped
          password=$(< "$secret_file")
          escaped=$(printf '%s' "$password" | sed 's/\x27/\x27\x27/g')
          psql -v ON_ERROR_STOP=1 -c "ALTER USER $user WITH ENCRYPTED PASSWORD '$escaped';"
        }
        set_password synapse ${lib.escapeShellArg config.sops.secrets."matrix/postgres_password".path}
        set_password mas     ${lib.escapeShellArg config.sops.secrets."matrix/postgres_password".path}
      '';
    in
    {
      description = "Set PostgreSQL user passwords from sops secrets";
      after = [ "postgresql.service" "sops-install-secrets.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        ExecStart = toString pgSetPasswordsScript;
      };
    };

  # Daily PostgreSQL backups to /var/backup/postgresql/
  services.postgresqlBackup = {
    enable = true;
    databases = [ "synapse" "mas" "mautrix-telegram" "mautrix-whatsapp" "mautrix-signal" "mautrix-discord" "authelia" ];
    backupAll = false;
    location = "/var/backup/postgresql";
    compression = "zstd";
    compressionLevel = 6;
    startAt = "03:00";
  };
}
