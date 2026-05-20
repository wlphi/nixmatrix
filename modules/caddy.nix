{ config, pkgs, lib, ... }:

let
  domain = "mair.io";
  # CORS headers applied to most Matrix API routes
  corsHeaders = ''
    header Access-Control-Allow-Origin "*"
    header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
    header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
  '';
in

{
  services.caddy = {
    enable = true;
    # Let's Encrypt contact email
    email = "admin@${domain}";

    virtualHosts = {

      # ── mair.io — well-known delegation only ────────────────────────────
      # server_name = "mair.io" but Synapse is on matrix.mair.io.
      # Matrix clients/servers fetch /.well-known/matrix/* from the server_name domain
      # to discover the homeserver address.
      #
      # Option A (if mair.io is served elsewhere):
      #   Add the two well-known routes to your existing mair.io web server instead
      #   and remove this vhost.
      # Option B (this VPS handles mair.io DNS too):
      #   Point mair.io DNS to this server — Caddy handles the well-known delegation.
      "${domain}" = {
        extraConfig = ''
          handle /.well-known/matrix/client {
            header Content-Type application/json
            header Access-Control-Allow-Origin "*"
            respond `{"m.homeserver":{"base_url":"https://matrix.${domain}"},"m.authentication":{"issuer":"https://auth.${domain}/"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://rtc.${domain}/livekit/jwt"}]}`
          }

          handle /.well-known/matrix/server {
            header Content-Type application/json
            respond `{"m.server":"matrix.${domain}:443"}`
          }

          handle {
            respond "mair.io" 200
          }
        '';
      };

      # ── matrix.mair.io — Synapse + MAS compat endpoints ─────────────────
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
          @compat path /_matrix/client/v3/login*
                       /_matrix/client/v3/logout*
                       /_matrix/client/v3/refresh*
                       /_matrix/client/v3/register*
                       /_matrix/client/r0/login*
                       /_matrix/client/r0/logout*
                       /_matrix/client/r0/refresh*
                       /_matrix/client/r0/register*
          handle @compat {
            ${corsHeaders}
            reverse_proxy localhost:8080 {
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
            reverse_proxy localhost:8008 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Well-known served here too (for clients that hit matrix.mair.io directly)
          handle /.well-known/matrix/client {
            header Content-Type application/json
            header Access-Control-Allow-Origin "*"
            respond `{"m.homeserver":{"base_url":"https://matrix.${domain}"},"m.authentication":{"issuer":"https://auth.${domain}/"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://rtc.${domain}/livekit/jwt"}]}`
          }
          handle /.well-known/matrix/server {
            header Content-Type application/json
            respond `{"m.server":"matrix.${domain}:443"}`
          }

          # All other Matrix API routes → Synapse
          @matrix_rest path_regexp ^/_matrix/.*$
          handle @matrix_rest {
            ${corsHeaders}
            reverse_proxy localhost:8008 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Fallback → Synapse (handles federation, key server, etc.)
          handle {
            reverse_proxy localhost:8008
          }
        '';
      };

      # ── auth.mair.io — Matrix Authentication Service ─────────────────────
      "auth.${domain}" = {
        extraConfig = ''
          # OIDC discovery — CORS needed for browser clients
          @disco path /.well-known/openid-configuration
          handle @disco {
            header Access-Control-Allow-Origin "*"
            reverse_proxy localhost:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # JWKS public keys — CORS needed for browser OIDC flows
          @jwks path /oauth2/keys.json
          route @jwks {
            header Access-Control-Allow-Origin "*"
            header Access-Control-Allow-Methods "GET, OPTIONS"
            reverse_proxy localhost:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # OAuth2 endpoints
          @oauth path /oauth2/*
          route @oauth {
            header Access-Control-Allow-Origin "*"
            header Access-Control-Allow-Methods "GET, POST, OPTIONS"
            header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
            reverse_proxy localhost:8080 {
              header_down -Access-Control-Allow-Origin
            }
          }

          # Account portal — IMPORTANT: use handle (NOT handle_path).
          # handle_path strips the /account/ prefix; MAS is a SPA and needs the
          # prefix intact for client-side routing to work.
          handle /account/* {
            reverse_proxy localhost:8080 {
              header_up Host {http.request.host}
              header_up X-Forwarded-Host {http.request.host}
            }
          }

          # MSC2965 auth metadata
          handle /_matrix/client/unstable/org.matrix.msc2965/auth_metadata {
            reverse_proxy localhost:8080
          }

          # Everything else → MAS
          handle {
            reverse_proxy localhost:8080 {
              header_up Host {http.request.host}
              header_up X-Forwarded-Host {http.request.host}
            }
          }
        '';
      };

      # ── element.mair.io — Element Web ─────────────────────────────────────
      # element-web NixOS module serves via nginx on 127.0.0.1:8765
      "element.${domain}" = {
        extraConfig = ''
          reverse_proxy localhost:8765
        '';
      };

      # ── chat.mair.io — FluffyChat ─────────────────────────────────────────
      "chat.${domain}" = {
        extraConfig = ''
          reverse_proxy localhost:8766
        '';
      };

      # ── admin.mair.io — Ketesa (element-admin) ────────────────────────────
      "admin.${domain}" = {
        extraConfig = ''
          reverse_proxy localhost:8767
        '';
      };

      # ── authelia.mair.io — Authelia SSO ──────────────────────────────────
      "authelia.${domain}" = {
        extraConfig = ''
          reverse_proxy localhost:9091
        '';
      };

      # ── rtc.mair.io — LiveKit + lk-jwt-service ────────────────────────────
      "rtc.${domain}" = {
        extraConfig = ''
          handle /livekit/jwt* {
            reverse_proxy localhost:8082
          }
          handle /livekit/sfu* {
            reverse_proxy localhost:7880
          }
        '';
      };

      # ── call.mair.io — Element Call frontend ──────────────────────────────
      "call.${domain}" = {
        extraConfig = ''
          reverse_proxy localhost:8768
        '';
      };

      # ── monitoring.mair.io — Grafana ─────────────────────────────────────
      "monitoring.${domain}" = {
        extraConfig = ''
          reverse_proxy localhost:3000
        '';
      };
    };
  };
}
