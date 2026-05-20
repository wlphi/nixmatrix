# NixOS IaC Plan — Matrix Stack

Self-hosted Matrix stack rebuilt as a NixOS flake. This document captures every architectural decision, configuration value, and hard-won fix from the Docker Compose reference implementation so the NixOS port does not repeat the same debugging cycles.

Reference implementation: `wlphi/ess-docker-compose`

---

## 1. Service Inventory & NixOS Module Map

| Service | NixOS module | Notes |
|---|---|---|
| Synapse | `services.matrix-synapse` | mature, nixpkgs |
| MAS | community flake `D4ndellion/nixos-matrix-modules` | official module pending [#376738](https://github.com/NixOS/nixpkgs/issues/376738) |
| PostgreSQL | `services.postgresql` | multiple databases |
| Redis | `services.redis` | Authelia session store only |
| Caddy | `services.caddy` | TLS termination |
| Authelia | `services.authelia` | optional, SSO upstream for MAS |
| mautrix-telegram | `services.mautrix-telegram` (nixpkgs) | Go bridge — see bridge quirks |
| mautrix-whatsapp | `services.mautrix-whatsapp` (nixpkgs) | megabridge format |
| mautrix-signal | `services.mautrix-signal` (nixpkgs) | megabridge format |
| mautrix-discord | `services.mautrix-discord` (nixpkgs) | megabridge format |
| mautrix-slack | `services.mautrix-slack` (nixpkgs) | megabridge format |
| LiveKit | `services.livekit` | basic module, nixpkgs |
| lk-jwt-service | `virtualisation.oci-containers` | not packaged in nixpkgs |
| Element Web | static files via Caddy | no service module needed |
| FluffyChat | `virtualisation.oci-containers` or static files | web build not in nixpkgs |
| Hookshot | `services.matrix-hookshot` (check nixpkgs) | IRC/GitHub/GitLab bridge |

---

## 2. Flake Structure

```
flake.nix
modules/
  default.nix          # imports all modules
  synapse.nix
  mas.nix
  caddy.nix
  postgres.nix
  authelia.nix
  bridges/
    double-puppet.nix  # doublepuppet appservice
    telegram.nix
    whatsapp.nix
    signal.nix
    discord.nix
    slack.nix
  element-call.nix     # livekit + lk-jwt-service
  well-known.nix       # Caddy well-known responses
secrets/
  secrets.yaml         # sops-encrypted
  secrets.nix          # agenix recipients (alternative)
hosts/
  matrix-server.nix    # top-level host config
```

**flake inputs:**

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  sops-nix.url = "github:Mic92/sops-nix";
  nixos-matrix-modules.url = "github:D4ndellion/nixos-matrix-modules";
  # pin nixos-matrix-modules to a specific rev for stability
};
```

---

## 3. Secrets Management (sops-nix)

All secrets decrypt to `/run/secrets/<name>` (tmpfs, never in the Nix store).

**secrets.yaml structure:**

```yaml
matrix:
  postgres_password: ...
  mas_secret_key: ...          # 64-char hex (openssl rand -hex 32)
  mas_signing_key: |           # RSA 4096 PKCS8 PEM (openssl genrsa 4096 | openssl pkcs8 -topk8 -nocrypt)
    -----BEGIN PRIVATE KEY-----
    ...
  synapse_shared_secret: ...   # shared between Synapse and MAS
  synapse_client_secret: ...   # MAS confidential client secret for Synapse
  livekit_secret: ...          # LiveKit API secret

authelia:
  jwt_secret: ...
  session_secret: ...
  storage_encryption_key: ...
  oidc_client_secret: ...      # MAS upstream provider client secret

bridges:
  doublepuppet_as_token: ...
  doublepuppet_hs_token: ...
  telegram_api_id: ...
  telegram_api_hash: ...
```

**Key generation commands (run once, store results in sops):**

```bash
openssl rand -hex 32                                           # mas_secret_key, synapse_shared_secret, synapse_client_secret
openssl genrsa 4096 2>/dev/null | openssl pkcs8 -topk8 -nocrypt  # mas_signing_key
openssl rand -hex 32                                           # doublepuppet tokens, authelia secrets
```

---

## 4. PostgreSQL

Multiple databases on one cluster. Each service gets its own database.

```nix
services.postgresql = {
  enable = true;
  ensureDatabases = [ "synapse" "mas" "telegram" "whatsapp" "signal" "discord" "slack" ];
  ensureUsers = [{
    name = "synapse";
    ensureDBOwnership = true;  # owns synapse db
  }];
  # All bridge databases also owned by synapse user for simplicity,
  # or create per-bridge users (more secure).
  initdbArgs = [ "--encoding=UTF-8" "--lc-collate=C" "--lc-ctype=C" ];
};
```

**Connection strings used throughout:**
- Synapse: `postgresql://synapse:<password>@localhost/synapse`
- MAS: `postgresql://synapse:<password>@localhost/mas`
- Telegram bridge: `postgresql://synapse:<password>@localhost/telegram`
- WhatsApp bridge: `postgresql://synapse:<password>@localhost/whatsapp`
- Signal bridge: `postgresql://synapse:<password>@localhost/signal`
- Discord bridge: `postgresql://synapse:<password>@localhost/discord`
- Slack bridge: `postgresql://synapse:<password>@localhost/slack`

---

## 5. Matrix Authentication Service (MAS)

**CRITICAL: No official NixOS module yet.** Use `D4ndellion/nixos-matrix-modules` from the flake input until [#376738](https://github.com/NixOS/nixpkgs/issues/376738) lands.

### 5.1 Config structure

```yaml
http:
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat       # legacy Matrix SSO / login token flow
        - name: graphql
          playground: true
        - name: assets       # required — CSS/JS for MAS web UI
        - name: adminapi     # required — admin API on the web listener
      binds:
        - address: '[::]:8080'
    - name: internal
      resources:
        - name: health
      binds:
        - address: '127.0.0.1:8081'   # health only, not exposed externally

  public_base: 'https://<AUTH_DOMAIN>/'    # trailing slash required
  issuer: 'https://<AUTH_DOMAIN>/'         # must match public_base

database:
  uri: 'postgresql://synapse:<password>@localhost/mas'
  auto_migrate: true     # safe to leave on; runs migrations at startup

secrets:
  encryption: '<MAS_SECRET_KEY>'   # 64-char hex
  keys:
    - kid: 'key-1'
      algorithm: rs256
      key: |
        <RSA 4096 PKCS8 PEM — from sops>

matrix:
  homeserver: '<MATRIX_DOMAIN>'     # server_name, not base_url
  endpoint: 'http://localhost:8008' # internal Synapse HTTP endpoint
  secret: '<SYNAPSE_SHARED_SECRET>'

passwords:
  enabled: true
  minimum_complexity: 3
  schemes:
    - version: 1
      algorithm: argon2id

account:
  password_registration_enabled: false   # or true for open registration
  password_registration_email_required: false
  password_change_allowed: true
  password_recovery_enabled: false
  account_deactivation_allowed: true

email:
  from: '"Matrix" <noreply@<DOMAIN>>'
  transport: smtp
  hostname: 'localhost'
  port: 25
  mode: plain

policy:
  data:
    registration:
      enabled: false   # IMPORTANT: key is policy.data.registration, NOT policy.registration
                       # Using policy.registration is silently ignored and breaks registration control

branding:
  service_name: 'Matrix'
  policy_uri: 'https://<AUTH_DOMAIN>/privacy'
  tos_uri: 'https://<AUTH_DOMAIN>/terms'
```

### 5.2 OIDC Clients

**All client IDs are ULIDs — must be exactly 26 characters in Crockford base32.**
Crockford alphabet: `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — excludes I, L, O, U.
Invalid IDs silently break client authorization without a helpful error.

```yaml
clients:
  # Element Web + Element Desktop (public client)
  - client_id: '01HQW90Z35CMXFJWQPHC3BGZGQ'
    client_auth_method: none
    redirect_uris:
      - 'https://<ELEMENT_DOMAIN>'
      - 'https://<ELEMENT_DOMAIN>/mobile_guide/'
      - 'io.element.app:/callback'         # Element mobile
      - 'http://localhost'                  # Element Desktop native OIDC (RFC 8252 loopback — matches any port)
      - 'http://127.0.0.1'                  # same, explicit

  # FluffyChat (public client — web + native)
  - client_id: '01FFCHAT00000000000000FC00'
    client_auth_method: none
    redirect_uris:
      - 'https://<FLUFFYCHAT_DOMAIN>'
      - 'https://<FLUFFYCHAT_DOMAIN>/'
      - 'im.fluffychat://login'             # FluffyChat native app

  # Ketesa / element-admin (public client)
  # CRITICAL: client_id is 01ADMN... (26 chars) NOT 01ADMIN... (25 chars, invalid ULID)
  - client_id: '01ADMN00000000000000000000'
    client_auth_method: none
    redirect_uris:
      - 'https://<ADMIN_DOMAIN>/'
      - 'https://<ADMIN_DOMAIN>'

  # Synapse (confidential client — backend integration)
  - client_id: '0000000000000000000SYNAPSE'
    client_auth_method: client_secret_basic
    client_secret: '<SYNAPSE_CLIENT_SECRET>'
```

### 5.3 Upstream Authelia OIDC (optional)

Only needed when Authelia is the upstream SSO provider.

```yaml
upstream_oauth2:
  providers:
    - id: '01HQW90Z35CMXFJWQPHC3BGZGQ'    # arbitrary ID, not a client ID
      issuer: 'https://<AUTHELIA_DOMAIN>'
      discovery_url: 'http://localhost:9091/.well-known/openid-configuration'
      # IMPORTANT: Use http://localhost (internal) NOT https://<AUTHELIA_DOMAIN>
      # for the discovery URL when MAS and Authelia are on the same machine.
      # HTTPS between local services fails on self-signed certs.
      # On NixOS with proper systemd unit ordering, localhost works fine.
      client_id: 'mas-client'
      client_secret: '<AUTHELIA_OIDC_CLIENT_SECRET>'
      scope: 'openid profile email offline_access'
      token_endpoint_auth_method: 'client_secret_basic'
      fetch_userinfo: true    # CRITICAL: must be true for Authelia — without this,
                              # claims are not fetched and localpart/email are empty
      claims_imports:
        localpart:
          action: force
          template: '{{ user.preferred_username }}'
        displayname:
          action: suggest
          template: '{{ user.name }}'
        email:
          action: force
          template: '{{ user.email }}'
          set_email_verification: always
```

### 5.4 Permissions

On NixOS with native services, UID management is handled by the module. If running MAS as a container or manually:
- MAS runs as **UID 65532**
- Data directory (`/var/lib/mas` or equivalent) must be owned by 65532
- Config file must be world-readable (644) — MAS cannot read a 600 config
- Config directory must be world-executable (755) — MAS cannot enter a 700 directory
- **This exact issue caused a crash-loop in v1.5 of the Docker reference implementation** — masked as "missing field `secrets`" which is misleading; the real error is permission denied on the config file

---

## 6. Synapse

### 6.1 Key settings

```nix
services.matrix-synapse = {
  enable = true;
  settings = {
    server_name = "<SERVER_NAME>";        # e.g. "example.com" or "matrix.example.com"
    public_baseurl = "https://<MATRIX_DOMAIN>";

    # MAS handles all auth — disable Synapse's own auth
    experimental_features = {
      msc3861 = {
        enabled = true;
        issuer = "https://<AUTH_DOMAIN>/";
        client_id = "0000000000000000000SYNAPSE";
        client_auth_method = "client_secret_basic";
        client_secret = "<SYNAPSE_CLIENT_SECRET>";  # from sops
        admin_token = "<SYNAPSE_ADMIN_TOKEN>";       # separate admin token
      };
    };

    # Database
    database = {
      name = "psycopg2";
      args = {
        user = "synapse";
        password = "<POSTGRES_PASSWORD>";
        database = "synapse";
        host = "localhost";
        cp_min = 5;
        cp_max = 10;
      };
    };

    # Listeners
    listeners = [{
      port = 8008;
      bind_addresses = [ "127.0.0.1" ];  # local only — Caddy terminates TLS
      type = "http";
      tls = false;
      x_forwarded = true;
      resources = [
        { names = [ "client" "federation" ]; compress = false; }
      ];
    }];

    # Disable Synapse's own registration — MAS handles it
    enable_registration = false;

    # App services (bridges + double puppet)
    app_service_config_files = [
      "/var/lib/matrix-synapse/appservices/doublepuppet.yaml"
      "/var/lib/matrix-synapse/appservices/telegram-registration.yaml"
      "/var/lib/matrix-synapse/appservices/whatsapp-registration.yaml"
      "/var/lib/matrix-synapse/appservices/signal-registration.yaml"
      "/var/lib/matrix-synapse/appservices/discord-registration.yaml"
      "/var/lib/matrix-synapse/appservices/slack-registration.yaml"
    ];

    # Element Call MSC support
    # Required for Element Call (video/voice rooms)
    rc_message = { per_second = 0.5; burst_count = 15; };  # increase if using Element Call
  };

  # Extra config for Element Call MSC features
  # (if services.matrix-synapse doesn't expose these yet, use extraConfig)
  extraConfig = ''
    max_event_delay_duration: 24h

    experimental_features:
      msc3266_enabled: true
      msc4222_enabled: true
      msc4140_enabled: true
  '';
};
```

### 6.2 Appservice registration — double puppet

The double puppet appservice enables bridges to act as Matrix users (puppet accounts). It must have `url: null` — without this, Synapse tries to send transaction callbacks to the bridge for puppet events, causing retry storms.

```yaml
# /var/lib/matrix-synapse/appservices/doublepuppet.yaml
id: doublepuppet
url: null           # CRITICAL: null prevents Synapse transaction retry storms
as_token: "<DOUBLEPUPPET_AS_TOKEN>"
hs_token: "<DOUBLEPUPPET_HS_TOKEN>"
sender_localpart: doublepuppet
rate_limited: false
namespaces:
  users:
    - regex: "@.*:<MATRIX_DOMAIN>"
      exclusive: false
```

Generate these on NixOS via a one-shot systemd unit or pre-generate into sops.

---

## 7. Caddy

### 7.1 Domain layout

| Domain | Service |
|---|---|
| `matrix.<domain>` | Synapse + well-known |
| `auth.<domain>` | MAS |
| `element.<domain>` | Element Web |
| `chat.<domain>` | FluffyChat |
| `admin.<domain>` | Ketesa / element-admin |
| `authelia.<domain>` | Authelia (optional) |
| `rtc.<domain>` | LiveKit + lk-jwt-service |
| `call.<domain>` | Element Call frontend |
| `monitoring.<domain>` | Grafana |

### 7.2 matrix.\<domain\> vhost

```caddy
matrix.<domain> {
    # ── Preflight / CORS ────────────────────────────────────────────────
    @preflight {
        method OPTIONS
        path_regexp matrix ^/_matrix/.*$
    }
    handle @preflight {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        respond "" 204
    }

    # ── MAS compat endpoints ─────────────────────────────────────────────
    # login/logout/refresh/register MUST go to MAS, not Synapse
    @compat path /_matrix/client/v3/login*
             /_matrix/client/v3/logout*
             /_matrix/client/v3/refresh*
             /_matrix/client/v3/register*
             /_matrix/client/r0/login*
             /_matrix/client/r0/logout*
             /_matrix/client/r0/refresh*
             /_matrix/client/r0/register*
    handle @compat {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        reverse_proxy localhost:8080 {   # MAS port
            header_down -Access-Control-Allow-Origin
        }
    }

    # ── Admin API — CORS scoped to admin domain only ─────────────────────
    # IMPORTANT: Use a DIFFERENT matcher name (@admin_preflight) inside this block.
    # Reusing @preflight here causes "matcher is defined more than once" Caddy crash.
    handle /_synapse/admin* {
        header Access-Control-Allow-Origin "https://<ADMIN_DOMAIN>"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        @admin_preflight method OPTIONS
        respond @admin_preflight "" 204
        reverse_proxy localhost:8008 {
            header_down -Access-Control-Allow-Origin
        }
    }

    # ── Well-known ──────────────────────────────────────────────────────
    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin "*"
        # With Element Call:
        respond `{"m.homeserver":{"base_url":"https://matrix.<domain>"},"m.authentication":{"issuer":"https://auth.<domain>/"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://rtc.<domain>/livekit/jwt"}]}`
        # Without Element Call:
        # respond `{"m.homeserver":{"base_url":"https://matrix.<domain>"},"m.authentication":{"issuer":"https://auth.<domain>/"}}`
    }
    handle /.well-known/matrix/server {
        header Content-Type application/json
        respond `{"m.server":"matrix.<domain>:443"}`
    }

    # ── Everything else → Synapse ─────────────────────────────────────
    @matrix_rest path_regexp ^/_matrix/.*$
    handle @matrix_rest {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        reverse_proxy localhost:8008 {
            header_down -Access-Control-Allow-Origin
        }
    }

    handle {
        reverse_proxy localhost:8008
    }
}
```

### 7.3 auth.\<domain\> vhost (MAS)

```caddy
auth.<domain> {
    # OIDC discovery (needs explicit CORS — some clients check this)
    @disco path /.well-known/openid-configuration
    handle @disco {
        header Access-Control-Allow-Origin "*"
        reverse_proxy localhost:8080 { header_down -Access-Control-Allow-Origin }
    }

    # JWKS (public keys — needs CORS for browser OIDC flows)
    @jwksjson path /oauth2/keys.json
    route @jwksjson {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, OPTIONS"
        reverse_proxy localhost:8080 { header_down -Access-Control-Allow-Origin }
    }

    # OAuth2 endpoints
    @oauth path /oauth2/*
    route @oauth {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, OPTIONS, POST"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        reverse_proxy localhost:8080 { header_down -Access-Control-Allow-Origin }
    }

    # Account portal — use handle (NOT handle_path) to preserve /account/ prefix
    # MAS is a SPA; stripping the prefix breaks client-side routing
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

    handle {
        reverse_proxy localhost:8080 {
            header_up Host {http.request.host}
            header_up X-Forwarded-Host {http.request.host}
        }
    }
}
```

### 7.4 Element Call vhost (rtc.\<domain\>)

```caddy
rtc.<domain> {
    handle /livekit/jwt* {
        reverse_proxy localhost:8082   # lk-jwt-service
    }
    handle /livekit/sfu* {
        reverse_proxy localhost:7880   # livekit HTTP/SFU
    }
}
```

---

## 8. Bridges

### 8.1 Architecture

- All bridges connect to Synapse as appservices via their `registration.yaml`
- All bridges use double puppet for puppeting Matrix users
- **Encryption is disabled on all bridges** — MAS uses MSC4190 (device masquerading) which is incompatible with bridge encryption as of current versions
- Bridge databases are separate postgres databases (one per bridge)

### 8.2 Double puppet configuration

In each bridge config (under `bridge.double_puppet` or equivalent):

```yaml
secrets:
  <MATRIX_DOMAIN>: as_token:<DOUBLEPUPPET_AS_TOKEN>
```

Use the `as_token:` prefix format — this tells the bridge to use the appservice AS token for authentication rather than a shared secret.

### 8.3 mautrix-telegram specifics

**This bridge was rewritten in Go.** The Go bridge has a different config structure from the Python bridge:

```yaml
# Config structure (Go bridge)
network:                           # top-level network-specific config
  api_id: <TELEGRAM_API_ID>       # from my.telegram.org — 4-space indent inside network:
  api_hash: <TELEGRAM_API_HASH>

  permissions:                     # 4-space indent inside network:
    '*': relaybot                  # single-quoted because * is special in YAML
    '<MATRIX_DOMAIN>': admin       # domain key needs no quotes
    # '@admin:<MATRIX_DOMAIN>': admin  # MXID keys need single quotes (starts with @)

database:                          # top-level, NOT inside network:
  type: postgres
  uri: postgres://synapse:<password>@localhost/telegram?sslmode=disable
  # CRITICAL: key is 'uri:' inside 'database:' block
  # Python bridge used scalar 'database: postgres://...'
  # Go bridge uses structured block with 'database.uri'

homeserver:
  address: http://localhost:8008   # internal address (4-space indent)
  domain: <MATRIX_DOMAIN>

appservice:
  address: http://mautrix-telegram:29317   # or localhost:29317 on NixOS
  hostname: 0.0.0.0                        # must be 0.0.0.0 — on Docker; on NixOS use 127.0.0.1
  port: 29317

bridge:
  double_puppet:
    secrets:
      <MATRIX_DOMAIN>: as_token:<DOUBLEPUPPET_AS_TOKEN>

encryption:
  allow: false
  default: false
  msc4190: false
```

**Permission levels in Go telegram bridge (current):** `relaybot`, `user`, `full`, `admin`
Note: the announcement about `relaybot→relay` and `full→user` renames may be for a future version; verify against actual generated config from the image you deploy.

### 8.4 mautrix-whatsapp, signal, discord, slack (megabridge format)

These use the megabridge config format — slightly different structure from telegram:

```yaml
homeserver:
  address: http://localhost:8008      # 4-space indent
  domain: <MATRIX_DOMAIN>

appservice:
  address: http://localhost:29318     # port varies per bridge
  hostname: 127.0.0.1                # 127.0.0.1 on NixOS native; 0.0.0.0 on Docker
  port: 29318

bridge:
  permissions:
    '"<MATRIX_DOMAIN>": admin'        # double-quoted keys in megabridge format
    '"@admin:<MATRIX_DOMAIN>": admin'
  double_puppet:
    secrets:
      <MATRIX_DOMAIN>: as_token:<DOUBLEPUPPET_AS_TOKEN>

database:
  type: postgres
  uri: postgres://synapse:<password>@localhost/whatsapp?sslmode=disable

encryption:
  allow: false
  default: false
  msc4190: false
```

**Megabridge ports:**
- whatsapp: 29318
- signal: 29328
- discord: 29334
- slack: 29335

### 8.5 Registration file generation

Each bridge generates a `registration.yaml` on first start. On NixOS this is handled by the bridge's systemd unit. Pre-generate the appservice/HS tokens and inject via sops-nix if you want deterministic IDs. Otherwise let the bridge generate them and then commit the generated files to your secrets store.

---

## 9. Authelia (optional)

```nix
services.authelia.instances.main = {
  enable = true;
  settings = {
    default_redirection_url = "https://<ELEMENT_DOMAIN>";
    default_2fa_method = "totp";

    session.redis.host = "localhost";  # requires services.redis

    storage.postgres = {
      address = "tcp://localhost:5432";
      database = "authelia";    # add to postgres.ensureDatabases
      username = "authelia";
    };

    access_control = {
      default_policy = "deny";
      rules = [
        {
          domain = "<AUTH_DOMAIN>";
          policy = "one_factor";   # MAS accesses Authelia
        }
      ];
    };

    identity_providers.oidc = {
      clients = [{
        client_id = "mas-client";
        client_name = "Matrix Authentication Service";
        client_secret = "<AUTHELIA_OIDC_CLIENT_SECRET>";  # from sops
        public = false;
        authorization_policy = "one_factor";
        redirect_uris = [
          "https://<AUTH_DOMAIN>/upstream/callback/01HQW90Z35CMXFJWQPHC3BGZGQ"
        ];
        scopes = [ "openid" "profile" "email" "offline_access" ];
        response_types = [ "code" ];
        grant_types = [ "authorization_code" "refresh_token" ];
        token_endpoint_auth_method = "client_secret_basic";
      }];
    };
  };
};

services.redis.servers.authelia = {
  enable = true;
  bind = "127.0.0.1";
  port = 6379;
};
```

---

## 10. Element Call (optional)

### LiveKit

```nix
services.livekit = {
  enable = true;
  settings = {
    port = 7880;
    rtc = {
      tcp_port = 7881;
      port_range_start = 50100;
      port_range_end = 50200;
      use_external_ip = true;
    };
    keys = {
      "livekit-key" = "<LIVEKIT_SECRET>";
    };
  };
};
```

**Ports that must be open in the firewall:**
- 7880/tcp — LiveKit HTTP/admin
- 7881/tcp — WebRTC TCP fallback
- 50100-50200/udp — RTP media (the whole range)

### lk-jwt-service (OCI container)

```nix
virtualisation.oci-containers.containers.lk-jwt-service = {
  image = "ghcr.io/element-hq/lk-jwt-service:latest";
  ports = [ "8082:8080" ];
  environment = {
    LIVEKIT_URL = "wss://rtc.<domain>/livekit/sfu";
    LIVEKIT_KEY = "livekit-key";
    LIVEKIT_SECRET = "<LIVEKIT_SECRET>";
    LIVEKIT_FULL_ACCESS_HOMESERVERS = "<MATRIX_DOMAIN>";
  };
};
```

### Element Web config additions for Element Call

```json
{
  "features": {
    "feature_element_call_video_rooms": true
  },
  "element_call": {
    "url": "https://call.<domain>",
    "brand": "Element Call"
  }
}
```

### Synapse additions for Element Call

```yaml
max_event_delay_duration: 24h

experimental_features:
  msc3266_enabled: true    # room summary API (used by Element Call)
  msc4222_enabled: true    # state after PDU
  msc4140_enabled: true    # hold/resume calls
```

---

## 11. well-known Responses

Caddy serves these as static JSON. Key points:

- `m.authentication.issuer` trailing slash is significant — must match MAS `issuer` exactly
- `m.authentication` is what tells modern clients (Element Desktop ≥1.11, FluffyChat) to use OIDC natively instead of the legacy password/SSO flow
- Without `m.authentication`, clients fall back to compat SSO (login token flow) — works but legacy

```json
// /.well-known/matrix/client
{
  "m.homeserver": {
    "base_url": "https://matrix.<domain>"
  },
  "m.authentication": {
    "issuer": "https://auth.<domain>/"
  }
}

// /.well-known/matrix/server  (federation delegation)
{
  "m.server": "matrix.<domain>:443"
}
```

With Element Call add to client well-known:
```json
"org.matrix.msc4143.rtc_foci": [{
  "type": "livekit",
  "livekit_service_url": "https://rtc.<domain>/livekit/jwt"
}]
```

---

## 12. Known Issues & Hard-Won Fixes

This section documents every non-obvious problem from the reference implementation. Treat it as a regression checklist.

### MAS

| Issue | Root cause | Fix |
|---|---|---|
| MAS crash-loop: "missing field `secrets`" | Config directory was 700 or config.yaml was 600 — MAS (UID 65532) couldn't enter/read | Config dir must be 755, config.yaml must be 644 |
| MAS ignores registration policy | `policy.registration.enabled` is wrong key | Correct key: `policy.data.registration.enabled` |
| Empty localpart/email after Authelia SSO | `fetch_userinfo: false` (default) — Authelia doesn't embed claims in the token | Set `fetch_userinfo: true` in the upstream_oauth2 provider |
| HTTPS discovery to Authelia fails locally | Self-signed cert between containers | Use `http://localhost:9091` for discovery URL, not `https://<authelia_domain>` |
| Element Admin gives 401 on all API calls | CORS missing on `/_synapse/admin*` | Scope CORS to `https://<ADMIN_DOMAIN>` and proxy to Synapse (not 403 block) |
| Element Desktop uses compat SSO instead of OIDC | `http://localhost` missing from redirect_uris | Add `http://localhost` and `http://127.0.0.1` to client `01HQW90Z35CMXFJWQPHC3BGZGQ` redirect_uris |
| "invalid client_id" for element-admin | `01ADMIN000000000000000000` is 25 chars, invalid ULID | Correct ID: `01ADMN00000000000000000000` (26 chars) |

### Caddy

| Issue | Root cause | Fix |
|---|---|---|
| Caddy startup crash: "matcher is defined more than once: @preflight" | `@preflight` named matcher defined twice in same site block | Use `@admin_preflight` inside the `/_synapse/admin*` handler |
| MAS account portal shows blank page / broken routes | `handle_path /account/*` strips the prefix; MAS SPA needs it | Use `handle /account/*` (not `handle_path`) |
| `/_matrix/client/v3/login` returns 404 | Synapse proxied for all `/_matrix/*` including login | Explicitly route login/logout/refresh/register to MAS before the catch-all `/_matrix/*` rule |

### Bridges

| Issue | Root cause | Fix |
|---|---|---|
| Telegram bridge: postgres connection string not applied | Sed pattern targeted `database: postgres://` (Python bridge scalar key) | Go bridge uses `database.uri`; target `    uri: postgres://` |
| Bridge can't connect to Synapse | `appservice.hostname: 127.0.0.1` — bridge only listens on loopback | On Docker: use `0.0.0.0`. On NixOS native (same host): `127.0.0.1` is fine |
| Double puppet loop / Synapse retries | Double puppet appservice had a real `url:` set | Set `url: null` — this disables transaction callbacks for the puppet appservice |
| Bridge encryption causes auth failures | MSC4190 (device masquerading) in MAS is incompatible with bridge E2EE | Set `encryption.allow: false`, `encryption.default: false`, `encryption.msc4190: false` on all bridges |
| Registration files owned by root:root 600 | Bridges run as root in Docker, create files with restrictive permissions | `chmod 644` the registration files before Synapse reads them |

### Synapse

| Issue | Root cause | Fix |
|---|---|---|
| Synapse can't read MAS-issued tokens | `msc3861` not enabled in experimental_features | Enable MSC3861 with correct issuer and client credentials |
| Element Call: events delayed/dropped | Missing MSC experimental features | Enable `msc3266`, `msc4222`, `msc4140` and set `max_event_delay_duration: 24h` |

---

## 13. Implementation Phases

### Phase 1 — Core (Synapse + MAS + Caddy + PostgreSQL)

Get login working before adding anything else.

1. PostgreSQL with `synapse` and `mas` databases
2. Synapse with MSC3861 pointing at MAS
3. MAS with password auth (no upstream SSO yet), clients for Element Web and Synapse
4. Caddy with matrix and auth vhosts + well-known
5. Verify: Element Web login creates a user via MAS, token accepted by Synapse

### Phase 2 — Clients (Element Web + FluffyChat + Ketesa)

1. Element Web static files via Caddy
2. FluffyChat — add `01FFCHAT00000000000000FC00` client to MAS, serve via Caddy
3. Ketesa (element-admin) — add `01ADMN00000000000000000000` client to MAS, verify CORS

### Phase 3 — Authelia SSO (optional)

1. Redis + Authelia
2. Add `upstream_oauth2` provider to MAS pointing at Authelia via HTTP
3. Test: login redirects through Authelia, claims imported correctly

### Phase 4 — Bridges

1. Double puppet appservice (`url: null`)
2. Restart Synapse with appservice registered
3. One bridge at a time — start with WhatsApp (most users, well-tested module)
4. Verify registration.yaml generated, database created, bridge connects

### Phase 5 — Element Call (optional)

1. LiveKit + lk-jwt-service OCI container
2. Update well-known with `rtc_foci`
3. Update Element Web config with call URL and feature flag
4. Enable Synapse MSC features + `max_event_delay_duration`
5. Open firewall ports: 7881/tcp, 50100-50200/udp

### Phase 6 — Monitoring (optional)

1. Prometheus + node-exporter
2. Synapse metrics endpoint (built-in, enable in homeserver.yaml)
3. Grafana with Synapse dashboard

---

## 14. Secrets Reference

Quick reference of all secrets needed and how to generate them:

| Secret | Generation | Used by |
|---|---|---|
| `postgres_password` | `openssl rand -base64 32` | Synapse, MAS, bridges |
| `mas_secret_key` | `openssl rand -hex 32` | MAS encryption |
| `mas_signing_key` | `openssl genrsa 4096 \| openssl pkcs8 -topk8 -nocrypt` | MAS JWT signing |
| `synapse_shared_secret` | `openssl rand -base64 32` | MAS ↔ Synapse |
| `synapse_client_secret` | `openssl rand -base64 32` | MAS OIDC client for Synapse |
| `livekit_secret` | `openssl rand -base64 32` | LiveKit ↔ lk-jwt-service |
| `authelia_jwt_secret` | `openssl rand -base64 32` | Authelia |
| `authelia_session_secret` | `openssl rand -base64 32` | Authelia |
| `authelia_storage_encryption_key` | `openssl rand -base64 32` | Authelia |
| `authelia_oidc_client_secret` | `openssl rand -base64 32` | Authelia ↔ MAS |
| `doublepuppet_as_token` | `openssl rand -hex 32` | Double puppet appservice |
| `doublepuppet_hs_token` | `openssl rand -hex 32` | Double puppet appservice |
| `telegram_api_id` | from [my.telegram.org](https://my.telegram.org) | Telegram bridge |
| `telegram_api_hash` | from [my.telegram.org](https://my.telegram.org) | Telegram bridge |

---

## 15. References

- Reference Docker implementation: `wlphi/ess-docker-compose`
- NixOS matrix-synapse module: `nixos/modules/services/matrix/synapse.nix`
- MAS NixOS module (community): [D4ndellion/nixos-matrix-modules](https://github.com/D4ndellion/nixos-matrix-modules)
- MAS official module tracking: [NixOS/nixpkgs#376738](https://github.com/NixOS/nixpkgs/issues/376738)
- sops-nix: [Mic92/sops-nix](https://github.com/Mic92/sops-nix)
- MAS config reference: [element-hq/matrix-authentication-service](https://github.com/element-hq/matrix-authentication-service)
- RFC 8252 (OAuth for Native Apps / loopback redirect): [RFC 8252 §7.3](https://www.rfc-editor.org/rfc/rfc8252#section-7.3)
- mautrix bridge docs: [docs.mau.fi/bridges](https://docs.mau.fi/bridges/)
