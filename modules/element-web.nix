{ config, pkgs, lib, ... }:

let
  domain = config.nixmatrix.domain;
  elementPort = 8765;
  fluffychatPort = 8766;
  ketesaPort = 8767;

  elementWebPackage = pkgs.element-web.override {
    conf = {
      default_server_config = {
        "m.homeserver" = {
          base_url = "https://matrix.${domain}";
          server_name = domain;
        };
        "m.authentication" = {
          issuer = "https://auth.${domain}/";
        };
      };
      brand = "Matrix";
      default_theme = "dark";
      features = {
        feature_element_call_video_rooms = true;
      };
      element_call = {
        url = "https://call.${domain}";
        brand = "Element Call";
      };
    };
  };
in

{
  # nginx serves static files on localhost; Caddy proxies from the public domain.
  # nginx must NOT listen on 80/443 — Caddy owns those ports.
  services.nginx = {
    enable = true;

    virtualHosts."element.${domain}" = {
      listen = [{ addr = "127.0.0.1"; port = elementPort; }];
      root = "${elementWebPackage}";
      extraConfig = ''
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        location / {
          try_files $uri $uri/ /index.html =404;
        }
      '';
    };

    virtualHosts."admin.${domain}" = {
      listen = [{ addr = "127.0.0.1"; port = ketesaPort; }];
      root = "/var/www/ketesa";
      extraConfig = ''
        try_files $uri $uri/ /index.html =404;
      '';
    };
  };

  # FluffyChat via OCI container (no nixpkgs package available)
  # Pin version — check releases: https://github.com/krille-chan/fluffychat/releases
  virtualisation.oci-containers.containers.fluffychat = {
    image = "ghcr.io/krille-chan/fluffychat:v1.22.1";
    ports = [ "127.0.0.1:${toString fluffychatPort}:80" ];
  };
}
