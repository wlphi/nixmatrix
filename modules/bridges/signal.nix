{ config, pkgs, lib, ... }:

# mautrix-signal — megabridge format.
#
# DB auth: Unix socket peer auth (mautrix-signal OS user = mautrix-signal PG user).
# No DB password needed in config. See postgres.nix for user setup.
#
# Double puppet: inject token at runtime via ExecStartPre.
#
# NOTE: mautrix-signal communicates with Signal via signald or signal-cli.
# The NixOS module handles this dependency — verify after first deploy:
#   systemctl status mautrix-signal

let
  domain = "mair.io";
  port = 29328;
in

{
  # bridges/doublepuppet_as_token is owned by matrix-synapse (doublepuppet.nix).
  # A per-service sops template copy below makes it readable by mautrix-signal.
  sops.templates."signal-dp-token" = {
    content = config.sops.placeholder."bridges/doublepuppet_as_token";
    owner = "mautrix-signal";
    mode = "0400";
  };

  services.mautrix-signal = {
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

      # Socket peer auth — no password. PG user mautrix-signal owns the signal DB.
      database = {
        type = "postgres";
        uri = "postgresql:///mautrix-signal?host=/run/postgresql";
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
  systemd.services.mautrix-signal.serviceConfig.ExecStartPre =
    let
      injectScript = pkgs.writeShellScript "signal-inject-secrets" ''
        set -euo pipefail
        cfg=/var/lib/mautrix-signal/config.yaml

        dp_token=$(< ${lib.escapeShellArg config.sops.templates."signal-dp-token".path})

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
