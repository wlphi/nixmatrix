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
        Which mautrix bridges to enable. All default to OFF — enable only the
        networks you actually use. Each enabled bridge registers itself with
        Synapse automatically (via the module's registerToSynapse). A disabled
        bridge contributes nothing and can never prevent Synapse from starting.

        Note: the Telegram bridge additionally needs real API credentials in
        secrets.yaml (bridges/telegram_api_id, bridges/telegram_api_hash) from
        https://my.telegram.org before it will start.
      '';
      default = { };
      type = lib.types.submodule {
        options = {
          telegram.enable = lib.mkEnableOption "the mautrix-telegram bridge";
          whatsapp.enable = lib.mkEnableOption "the mautrix-whatsapp bridge";
          signal.enable = lib.mkEnableOption "the mautrix-signal bridge";
          discord.enable = lib.mkEnableOption "the mautrix-discord bridge";
        };
      };
    };
  };
}
