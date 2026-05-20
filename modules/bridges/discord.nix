{ config, pkgs, lib, ... }:

# mautrix-discord — megabridge format.
#
# DB auth: Unix socket peer auth (mautrix-discord OS user = mautrix-discord PG user).
# No DB password needed in config. See postgres.nix for user setup.
#
# Double puppet: inject token at runtime via ExecStartPre.

let
  domain = "mair.io";
  port = 29334;
in

{
  # bridges/doublepuppet_as_token is owned by matrix-synapse (doublepuppet.nix).
  # A per-service sops template copy below makes it readable by mautrix-discord.
  sops.templates."discord-dp-token" = {
    content = config.sops.placeholder."bridges/doublepuppet_as_token";
    owner = "mautrix-discord";
    mode = "0400";
  };

  services.mautrix-discord = {
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

      # Socket peer auth — no password. PG user mautrix-discord owns the discord DB.
      database = {
        type = "postgres";
        uri = "postgresql:///mautrix-discord?host=/run/postgresql";
      };

      bridge = {
        permissions = {
          "*" = "relaybot";
          ${domain} = "admin";
        };

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

      logging = {
        min_level = "info";
        writers = [{ type = "stdout"; format = "pretty-colored"; }];
      };
    };
  };

  # Inject doublepuppet token into the generated config before the bridge starts
  systemd.services.mautrix-discord.serviceConfig.ExecStartPre =
    let
      injectScript = pkgs.writeShellScript "discord-inject-secrets" ''
        set -euo pipefail
        cfg=/var/lib/mautrix-discord/config.yaml

        dp_token=$(< ${lib.escapeShellArg config.sops.templates."discord-dp-token".path})

        ${pkgs.python3}/bin/python3 - "$cfg" "$dp_token" <<'PYEOF'
import sys, yaml, pathlib

cfg_path = pathlib.Path(sys.argv[1])
data = yaml.safe_load(cfg_path.read_text())

domain = data.get("homeserver", {}).get("domain", "")
data.setdefault("bridge", {}).setdefault("double_puppet", {}).setdefault("secrets", {})[
    domain
] = "as_token:" + sys.argv[2]

cfg_path.write_text(yaml.dump(data, default_flow_style=False, allow_unicode=True))
PYEOF
      '';
    in
    lib.mkAfter [ (toString injectScript) ];
}
