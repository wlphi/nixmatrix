{ config, pkgs, lib, ... }:

# mautrix-telegram — Go bridge (NOT the old Python bridge).
#
# DB auth: Unix socket peer auth (mautrix-telegram OS user = mautrix-telegram PG user).
# No DB password needed in config. See postgres.nix for user setup.
#
# Double puppet: inject token at runtime via ExecStartPre.
# The sops secret /run/secrets/bridges/doublepuppet_as_token is read and written
# into the generated config file before the bridge starts.

let
  domain = "mair.io";
  port = 29317;
in

{
  sops.secrets = {
    # Telegram API credentials — unique to this bridge
    "bridges/telegram_api_id"  = { owner = "mautrix-telegram"; };
    "bridges/telegram_api_hash" = { owner = "mautrix-telegram"; };
    # bridges/doublepuppet_as_token is owned by matrix-synapse (doublepuppet.nix).
    # A per-service sops template copy below makes it readable by mautrix-telegram.
  };

  # Per-service copy of the doublepuppet token — readable by mautrix-telegram only
  sops.templates."telegram-dp-token" = {
    content = config.sops.placeholder."bridges/doublepuppet_as_token";
    owner = "mautrix-telegram";
    mode = "0400";
  };

  services.mautrix-telegram = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://localhost:8008";
        domain = domain;
      };

      appservice = {
        address = "http://localhost:${toString port}";
        hostname = "127.0.0.1";
        port = port;
      };

      # Socket peer auth — no password. PG user mautrix-telegram owns the telegram DB.
      database = {
        type = "postgres";
        uri = "postgresql:///mautrix-telegram?host=/run/postgresql";
      };

      network = {
        # API credentials injected at runtime via ExecStartPre
        api_id = 0;         # placeholder — overwritten by ExecStartPre
        api_hash = "";      # placeholder — overwritten by ExecStartPre
        permissions = {
          "*" = "relaybot";
          ${domain} = "admin";
        };
      };

      bridge = {
        double_puppet = {
          secrets = {
            # Token injected at runtime via ExecStartPre
            ${domain} = "as_token:REPLACE_AT_RUNTIME";
          };
        };
      };

      encryption = {
        allow = false;
        default = false;
        msc4190 = false;
      };
    };
  };

  # Inject secrets into the generated config before the bridge starts
  systemd.services.mautrix-telegram.serviceConfig.ExecStartPre =
    let
      injectScript = pkgs.writeShellScript "telegram-inject-secrets" ''
        set -euo pipefail
        cfg=/var/lib/mautrix-telegram/config.yaml

        api_id=$(< ${lib.escapeShellArg config.sops.secrets."bridges/telegram_api_id".path})
        api_hash=$(< ${lib.escapeShellArg config.sops.secrets."bridges/telegram_api_hash".path})
        dp_token=$(< ${lib.escapeShellArg config.sops.templates."telegram-dp-token".path})

        # Use a Python one-liner for safe YAML field patching (no quoting nightmares)
        ${pkgs.python3}/bin/python3 - "$cfg" "$api_id" "$api_hash" "$dp_token" <<'PYEOF'
import sys, yaml, pathlib

cfg_path = pathlib.Path(sys.argv[1])
data = yaml.safe_load(cfg_path.read_text())

data.setdefault("network", {})["api_id"] = int(sys.argv[2])
data.setdefault("network", {})["api_hash"] = sys.argv[3]
data.setdefault("bridge", {}).setdefault("double_puppet", {}).setdefault("secrets", {})[
    data.get("homeserver", {}).get("domain", "")
] = "as_token:" + sys.argv[4]

cfg_path.write_text(yaml.dump(data, default_flow_style=False, allow_unicode=True))
PYEOF
      '';
    in
    lib.mkAfter [ (toString injectScript) ];
}
