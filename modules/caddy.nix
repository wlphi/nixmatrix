{ config, pkgs, lib, ... }:

let
  domain = config.nixmatrix.domain;
  proxy = config.nixmatrix.externalProxy;

  # CORS headers applied to most Matrix API routes
  corsHeaders = ''
    header Access-Control-Allow-Origin "*"
    header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
    header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
  '';

  # Each vhost is keyed by hostname. Normally Caddy serves it over HTTPS and
  # fetches a certificate. In external-proxy mode we instead serve plain HTTP on
  # a shared local port (http://<host>:<port>) and let the upstream proxy do TLS.
  # mkHosts rewrites the keys accordingly without touching the vhost bodies.
  mkHosts = hosts:
    if proxy.enable
    then lib.mapAttrs' (name: v: lib.nameValuePair "http://${name}:${toString proxy.port}" v) hosts
    else hosts;
in

{
  services.caddy = {
    enable = true;
    # Let's Encrypt contact email (unused in external-proxy mode — no certs here)
    email = config.nixmatrix.acmeEmail;

    globalConfig = ''
      # Admin API on localhost only — never expose to external interfaces
      admin localhost:2019
    '' + lib.optionalString proxy.enable ''
      # External-proxy mode: the upstream proxy terminates TLS, so don't manage
      # certificates here. Trust X-Forwarded-* from local/private-range proxies
      # so MAS sees the real https:// host when building OAuth2 redirect URIs.
      auto_https off
      servers {
        trusted_proxies static private_ranges
      }
    '';

    virtualHosts = mkHosts ({

      # ── <domain> (apex) — well-known delegation only ────────────────────
      # server_name is the apex <domain> (Matrix IDs are @user:<domain>), but
      # Synapse runs on matrix.<domain>. Clients/servers fetch
      # /.well-known/matrix/* from the apex to discover the real homeserver.
      #
      # ⚠️ If your apex already hosts a website elsewhere, do NOT point its DNS
      # here (that would replace your site). Instead serve just these two
      # /.well-known/matrix/* routes from your existing apex site and delete
      # this vhost. See docs/DEPLOY.md §2 (DNS). Otherwise, point the apex at
      # this server and Caddy handles the delegation.
      "${domain}" = {
        extraConfig = ''
          handle /.well-known/matrix/client {
            header Content-Type application/json
            header Access-Control-Allow-Origin "*"
            respond `{"m.homeserver":{"base_url":"https://matrix.${domain}"},"m.authentication":{"issuer":"https://auth.${domain}/"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://rtc.${domain}/livekit/jwt"}]}`
          }

          handle /.well-known/matrix/server {
            header Content-Type application/json
            header Access-Control-Allow-Origin "*"
            respond `{"m.server":"matrix.${domain}:443"}`
          }

          handle {
            respond "${domain}" 200
          }
        '';
      };

      # ── matrix.example.com — Synapse + MAS compat endpoints ─────────────────
      "matrix.${domain}" = {
        extraConfig = ''
          # Preflight OPTIONS for Matrix API
          @preflight {
            method OPTIONS
            path_regexp matrix ^/_matrix/.*$
          }
          handle @preflight {
            ${corsHeaders}
            respond "" 204
          }

          # MAS compat endpoints — login/logout/refresh/register go to MAS (port 8080).
          # These MUST be before the catch-all /_matrix/* rule or they'll hit Synapse.
          @compat path /_matrix/client/v3/login* /_matrix/client/v3/logout* /_matrix/client/v3/refresh* /_matrix/client/v3/register* /_matrix/client/r0/login* /_matrix/client/r0/logout* /_matrix/client/r0/refresh* /_matrix/client/r0/register*
          handle @compat {
            ${corsHeaders}
            reverse_proxy 127.0.0.1:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Synapse admin API — CORS scoped to admin domain only (not "*").
          # IMPORTANT: use @admin_preflight (not @preflight) — duplicate named matchers
          # in the same site block crash Caddy with "matcher defined more than once".
          handle /_synapse/admin* {
            header Access-Control-Allow-Origin "https://admin.${domain}"
            header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
            header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
            @admin_preflight method OPTIONS
            respond @admin_preflight "" 204
            reverse_proxy 127.0.0.1:8008 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Well-known served here too (for clients that hit matrix.example.com directly)
          handle /.well-known/matrix/client {
            header Content-Type application/json
            header Access-Control-Allow-Origin "*"
            respond `{"m.homeserver":{"base_url":"https://matrix.${domain}"},"m.authentication":{"issuer":"https://auth.${domain}/"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://rtc.${domain}/livekit/jwt"}]}`
          }
          handle /.well-known/matrix/server {
            header Content-Type application/json
            header Access-Control-Allow-Origin "*"
            respond `{"m.server":"matrix.${domain}:443"}`
          }

          # All other Matrix API routes → Synapse
          @matrix_rest path_regexp ^/_matrix/.*$
          handle @matrix_rest {
            ${corsHeaders}
            reverse_proxy 127.0.0.1:8008 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Fallback → Synapse (handles federation, key server, etc.)
          handle {
            reverse_proxy 127.0.0.1:8008
          }
        '';
      };

      # ── auth.example.com — Matrix Authentication Service ─────────────────────
      "auth.${domain}" = {
        extraConfig = ''
          # OIDC discovery — CORS needed for browser clients
          @disco path /.well-known/openid-configuration
          handle @disco {
            header Access-Control-Allow-Origin "*"
            reverse_proxy 127.0.0.1:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # JWKS public keys — CORS needed for browser OIDC flows
          @jwks path /oauth2/keys.json
          route @jwks {
            header Access-Control-Allow-Origin "*"
            header Access-Control-Allow-Methods "GET, OPTIONS"
            reverse_proxy 127.0.0.1:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # OAuth2 endpoints
          @oauth path /oauth2/*
          route @oauth {
            header Access-Control-Allow-Origin "*"
            header Access-Control-Allow-Methods "GET, POST, OPTIONS"
            header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
            reverse_proxy 127.0.0.1:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Account portal — IMPORTANT: use handle (NOT handle_path).
          # handle_path strips the /account/ prefix; MAS is a SPA and needs the
          # prefix intact for client-side routing to work.
          handle /account/* {
            reverse_proxy 127.0.0.1:8080 {
              header_up Host {http.request.host}
              header_up X-Forwarded-Host {http.request.host}
            }
          }

          # MSC2965 auth metadata
          handle /_matrix/client/unstable/org.matrix.msc2965/auth_metadata {
            reverse_proxy 127.0.0.1:8080
          }

          # Everything else → MAS
          handle {
            reverse_proxy 127.0.0.1:8080 {
              header_up Host {http.request.host}
              header_up X-Forwarded-Host {http.request.host}
            }
          }
        '';
      };

      # ── element.example.com — Element Web ─────────────────────────────────────
      # element-web NixOS module serves via nginx on 127.0.0.1:8765
      "element.${domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:8765
        '';
      };

      # ── chat.example.com — FluffyChat ─────────────────────────────────────────
      "chat.${domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:8766
        '';
      };

      # ── admin.example.com — Ketesa (element-admin) ────────────────────────────
      "admin.${domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:8767
        '';
      };

      # ── rtc.example.com — LiveKit + lk-jwt-service ────────────────────────────
      "rtc.${domain}" = {
        extraConfig = ''
          handle /livekit/jwt* {
            reverse_proxy 127.0.0.1:8082
          }
          handle /livekit/sfu* {
            reverse_proxy 127.0.0.1:7880
          }
        '';
      };

      # ── call.example.com — Element Call frontend ──────────────────────────────
      "call.${domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:8768
        '';
      };

      # ── monitoring.example.com — Grafana ─────────────────────────────────────
      "monitoring.${domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:3000
        '';
      };
    }
    # authelia.<domain> — only when SSO is enabled (nixmatrix.sso.enable).
    // lib.optionalAttrs config.nixmatrix.sso.enable {
      "authelia.${domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:9091
        '';
      };
    });
  };
}
