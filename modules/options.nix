{ config, lib, ... }:

# Central configuration options for the nixMatrix stack.
#
# Set these once in your host config (hosts/matrix-server.nix). Every module
# reads them via `config.nixmatrix.*` so you never have to hand-edit service
# files when deploying to your own domain.

{
  options.nixmatrix = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = ''
        The base domain for the Matrix deployment. Matrix user IDs are
        `@user:<domain>` and all service subdomains are derived from it
        (matrix.<domain>, auth.<domain>, element.<domain>, etc.).

        This is the single value you must change to deploy your own instance.
      '';
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@${config.nixmatrix.domain}";
      defaultText = lib.literalExpression ''"admin@''${config.nixmatrix.domain}"'';
      example = "you@example.com";
      description = ''
        Contact email passed to Let's Encrypt / ACME for TLS certificate
        registration and expiry notices. Defaults to admin@<domain>.
      '';
    };

    externalProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Put this stack behind a reverse proxy you already run (nginx, Apache,
          another Caddy, …) that handles TLS for your other sites too.

          When off (the default), the built-in Caddy gets Let's Encrypt
          certificates and serves HTTPS directly — nothing else needed.

          When on, the built-in Caddy stops touching certificates and serves
          plain HTTP on `externalProxy.port` instead. Your own proxy terminates
          HTTPS and forwards each Matrix subdomain to that port. Ready-to-use
          nginx and Apache configs are in `examples/reverse-proxy/`.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = ''
          The local HTTP port the built-in Caddy listens on when
          `externalProxy.enable` is set. Your reverse proxy forwards the Matrix
          subdomains here. Only used in external-proxy mode.
        '';
      };
    };

    turn = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable LiveKit's built-in TURN server so voice/video calls work for
          users behind strict NAT or firewalls.

          Without it, calls rely on a direct media path and can silently fail on
          home/CGNAT connections. With it, those clients fall back through TURN.

          Requires `turn.udpPort` reachable from the internet. Calls also still
          need the existing media ports open (TCP 7881, UDP 50100–50200).
          Only takes effect when Element Call (LiveKit) is in use.
        '';
      };
      udpPort = lib.mkOption {
        type = lib.types.port;
        default = 3478;
        description = ''
          UDP port for the TURN server. 3478 is the standard TURN port. Setting
          it to 443 maximises the chance of getting through restrictive
          firewalls, but only do that in external-proxy mode where Caddy isn't
          already using 443. This port must be open to the internet.
        '';
      };
      relayRange = lib.mkOption {
        type = lib.types.str;
        default = "30000-31000";
        example = "30000-31000";
        description = ''
          UDP port range (start-end) TURN uses to relay media to the SFU. Must
          be open to the internet. Kept small by default; widen it for many
          concurrent calls.
        '';
      };
    };

    openRegistration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow anyone to self-register an account through MAS (public signups).

        OFF by default — only an admin can create accounts
        (`mas-cli manage register-user` on the server). Turn this on for a public
        homeserver where you want open signups. When enabled, MAS shows a
        "Create account" flow at auth.<domain>.

        Note: spam/abuse is your responsibility on an open server; consider
        requiring email verification (configure MAS's email/SMTP settings) before
        opening registration to the public.
      '';
    };

    sso.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Authelia as an upstream SSO / OIDC identity provider for MAS.

        OFF by default: a fresh deploy runs Synapse + MAS (with MAS's own native
        login) + clients, with no SSO layer. Turn this on only if you want users
        to authenticate through Authelia instead.

        When enabled, Authelia ships with a single example account
        (admin / changeme) seeded into /var/lib/authelia-main/users.yaml —
        CHANGE that password before exposing it. MAS is wired to Authelia as an
        upstream OIDC provider automatically.
      '';
    };

    bridges = lib.mkOption {
      description = ''
        Which bridges to enable. All default to OFF — enable only what you use.
        A disabled bridge contributes nothing and can never prevent Synapse from
        starting.

        The four mautrix bridges (telegram/whatsapp/signal/discord) register
        themselves with Synapse automatically. The Telegram one additionally
        needs real API credentials in secrets.yaml (bridges/telegram_api_id,
        bridges/telegram_api_hash) from https://my.telegram.org.

        hookshot bridges Matrix to GitHub, GitLab, Jira, generic webhooks, and
        RSS feeds (it is NOT a chat-network bridge). Out of the box it enables
        generic incoming webhooks; the service integrations are configured per
        room from the bridge bot once it's running.
      '';
      default = { };
      type = lib.types.submodule {
        options = {
          telegram.enable = lib.mkEnableOption "the mautrix-telegram bridge";
          whatsapp.enable = lib.mkEnableOption "the mautrix-whatsapp bridge";
          signal.enable = lib.mkEnableOption "the mautrix-signal bridge";
          discord.enable = lib.mkEnableOption "the mautrix-discord bridge";
          hookshot.enable = lib.mkEnableOption "matrix-hookshot (GitHub/GitLab/Jira/webhooks/RSS)";
        };
      };
    };
  };
}
