#!/usr/bin/env bash
# =============================================================================
# check-nix.sh — Static checks on the Nix configuration files.
#
# Catches known production bugs BEFORE building or booting a VM.
# Adapted from matrix-2/test_deploy.sh assert_configs() patterns.
#
# Usage (run from repo root):
#   ./test/check-nix.sh
#
# Exit code: 0 if all pass, 1 if any fail.
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

# ─── Colors / counters ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

PASSED=0; FAILED=0

pass()   { echo -e "  ${GREEN}✓${NC} $1"; PASSED=$((PASSED+1)); }
fail()   { echo -e "  ${RED}✗${NC} $1"; FAILED=$((FAILED+1)); }
header() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }
section(){ echo -e "\n${BOLD}${MAGENTA}════ $1 ════${NC}"; }

# Grep for pattern in file; pass/fail with label
check()    { local f="$1" pat="$2" label="$3"
             grep -qF -- "$pat" "$f" && pass "$label" || fail "$label"; }
check_re() { local f="$1" pat="$2" label="$3"
             grep -qE -- "$pat" "$f" && pass "$label" || fail "$label"; }
no_check() { local f="$1" pat="$2" label="$3"
             ! grep -qF -- "$pat" "$f" && pass "$label" || fail "$label"; }

# ─── MAS config checks ────────────────────────────────────────────────────────
section "MAS (modules/mas.nix)"

# Bug #2: MAS must have assets resource or login pages are unstyled (CSS/JS 404)
check "modules/mas.nix" \
  "- name: assets" \
  "MAS http.listeners includes assets resource (Bug #2 — unstyled login pages)"

# Bug #2: adminapi resource required for Ketesa (Element Admin) to reach MAS
check "modules/mas.nix" \
  "- name: adminapi" \
  "MAS http.listeners includes adminapi resource"

# Bug #3: fetch_userinfo must be true; Authelia serves claims via userinfo not ID token
check "modules/mas.nix" \
  "fetch_userinfo: true" \
  "MAS upstream provider has fetch_userinfo: true (Bug #3 — empty username/email)"

# Bug #8: Use http://localhost for discovery (not https://authelia.example.com)
# HTTPS to Authelia from MAS triggers SSL cert trust issues on self-signed certs
check "modules/mas.nix" \
  "discovery_url: \"http://localhost:9091" \
  "MAS upstream uses http://localhost discovery_url (Bug #8 — TLS trust bypass)"

# Bug #6: Claims must use preferred_username not name (Authelia doesn't provide user.name)
check "modules/mas.nix" \
  "user.preferred_username" \
  "MAS claims template uses preferred_username not name (Bug #6 — empty displayname)"

# NixOS-specific: policy.data.registration (not policy.registration — silently ignored)
check "modules/mas.nix" \
  "data:" \
  "MAS policy uses policy.data.registration nesting (NixOS silent-ignore gotcha)"

# Registration is driven by the nixmatrix.openRegistration option, which
# defaults to false (admin-only). Both the account flag and the policy must be
# wired to it — MAS silently ignores signups if the two disagree.
check "modules/mas.nix" \
  "password_registration_enabled: \${lib.boolToString config.nixmatrix.openRegistration}" \
  "MAS account registration wired to nixmatrix.openRegistration"
check "modules/mas.nix" \
  "enabled: \${lib.boolToString config.nixmatrix.openRegistration}" \
  "MAS policy.data.registration wired to nixmatrix.openRegistration"
check "modules/options.nix" \
  "openRegistration" \
  "nixmatrix.openRegistration option exists (defaults to false — admin-only)"

# Optional features are opt-in (default off): SSO, external reverse proxy, TURN.
check "modules/options.nix" "externalProxy" "nixmatrix.externalProxy option exists"
check "modules/options.nix" "turn" "nixmatrix.turn option exists (TURN fallback for calls)"
# TURN config is gated, so livekit.nix must reference the option, not hardcode it.
check "modules/livekit.nix" \
  "config.nixmatrix.turn" \
  "LiveKit TURN wired to nixmatrix.turn (off by default)"

# MAS password hashing scheme
check "modules/mas.nix" \
  "algorithm: argon2id" \
  "MAS uses argon2id password hashing"

# All OIDC clients registered: Element Web, FluffyChat, Ketesa, Synapse
check "modules/mas.nix" \
  "01HQW90Z35CMXFJWQPHC3BGZGQ" \
  "MAS OIDC client: Element Web registered"
check "modules/mas.nix" \
  "im.fluffychat://login" \
  "MAS OIDC client: FluffyChat native redirect URI (users without self-hosted FluffyChat)"
check "modules/mas.nix" \
  "01ADMN00000000000000000000" \
  "MAS OIDC client: Ketesa (26-char ULID — not 01ADMIN which is 25 chars)"
check "modules/mas.nix" \
  "0000000000000000000SYNAPSE" \
  "MAS OIDC client: Synapse backend"

# ─── Caddy checks ─────────────────────────────────────────────────────────────
section "Caddy (modules/caddy.nix)"

# Issue #16: Missing X-Forwarded-Host breaks OAuth2 redirects (auth URL shows internal host)
check "modules/caddy.nix" \
  "X-Forwarded-Host" \
  "Caddy forwards X-Forwarded-Host to MAS (Issue #16 — OAuth2 redirect URI)"

# Issue #22: Admin CORS must be scoped to admin domain only (not *)
check "modules/caddy.nix" \
  '"https://admin.${domain}"' \
  "Caddy /_synapse/admin CORS scoped to admin domain (Issue #22 — Ketesa blocked)"

# MAS compat routes must come before generic /_matrix/* catch-all
# Check @compat matcher exists and includes login/register paths
check "modules/caddy.nix" \
  "@compat path /_matrix/client/v3/login" \
  "Caddy @compat matcher routes login to MAS before Synapse catch-all"
check "modules/caddy.nix" \
  "/_matrix/client/v3/register" \
  "Caddy routes register to MAS"

# Well-known delegation from root domain (server_name = example.com, not matrix.example.com)
check "modules/caddy.nix" \
  '/.well-known/matrix/client' \
  "Caddy serves /.well-known/matrix/client on root domain"
check "modules/caddy.nix" \
  '"m.authentication"' \
  "Caddy well-known includes m.authentication for OIDC discovery"
check "modules/caddy.nix" \
  '"m.server":"matrix.${domain}:443"' \
  "Caddy well-known/matrix/server delegates to matrix subdomain"

# handle (not handle_path) for /account/ — handle_path strips prefix, breaks SPA routing
check "modules/caddy.nix" \
  "handle /account/*" \
  "Caddy uses 'handle' not 'handle_path' for /account/* (SPA routing)"
no_check "modules/caddy.nix" \
  "handle_path /account" \
  "Caddy does NOT use handle_path for /account/ (would strip prefix)"

# @admin_preflight not @preflight inside admin handler (duplicate named matchers crash Caddy)
check "modules/caddy.nix" \
  "@admin_preflight" \
  "Caddy uses @admin_preflight not @preflight inside admin handler (duplicate matcher crash)"

# Caddy admin API on localhost only
check "modules/caddy.nix" \
  "admin localhost:2019" \
  "Caddy admin API bound to localhost:2019 only"

# ─── Doublepuppet checks ──────────────────────────────────────────────────────
section "Double puppet (modules/bridges/doublepuppet.nix)"

# CRITICAL: url must be null — a real URL causes transaction retry storms
check "modules/bridges/doublepuppet.nix" \
  "url: null" \
  "doublepuppet.yaml has url: null (prevents transaction retry storms)"

check "modules/bridges/doublepuppet.nix" \
  "id: doublepuppet" \
  "doublepuppet.yaml has correct id"

check "modules/bridges/doublepuppet.nix" \
  "@.*:\${domain}" \
  "doublepuppet user regex uses domain variable (evaluates to example.com)"

check "modules/bridges/doublepuppet.nix" \
  "exclusive: false" \
  "doublepuppet namespace is non-exclusive (coexists with bridge users)"

# ─── Synapse checks ───────────────────────────────────────────────────────────
section "Synapse (modules/synapse.nix)"

check "modules/synapse.nix" \
  'server_name = domain' \
  "Synapse server_name is domain (example.com)"

check "modules/synapse.nix" \
  "enable_registration = false" \
  "Synapse registration disabled (MAS handles auth via MSC3861)"

check "modules/synapse.nix" \
  "msc3861" \
  "Synapse MSC3861 present in extra config (MAS delegation)"

check "modules/synapse.nix" \
  "doublepuppet.yaml" \
  "Synapse registers doublepuppet appservice"

check "modules/synapse.nix" \
  "enable_metrics = true" \
  "Synapse Prometheus metrics enabled"

# Bridges are opt-in (nixmatrix.bridges.<net>.enable, default off) and register
# themselves with Synapse via the mautrix module's registerToSynapse. Synapse
# must therefore NOT hardcode bridge registration paths (doing so pointed at
# files nothing creates → FileNotFoundError, blocking the homeserver).
for bridge in telegram whatsapp signal discord; do
  no_check "modules/synapse.nix" \
    "${bridge}-registration.yaml" \
    "Synapse does NOT hardcode ${bridge} registration (bridge self-registers)"
done
# Each bridge module is gated behind its opt-in flag.
for bridge in telegram whatsapp signal discord hookshot; do
  check "modules/bridges/${bridge}.nix" \
    "lib.mkIf config.nixmatrix.bridges.${bridge}.enable" \
    "Bridge ${bridge} is opt-in (gated on nixmatrix.bridges.${bridge}.enable)"
done
# hookshot has no registerToSynapse helper, so (only when enabled) it adds its
# registration to Synapse's appservice list itself.
check "modules/bridges/hookshot.nix" \
  "services.matrix-synapse.settings.app_service_config_files" \
  "hookshot wires its registration into Synapse's appservice list"

# ─── Bridge checks ────────────────────────────────────────────────────────────
section "Bridges (modules/bridges/)"

for bridge in telegram whatsapp signal discord; do
  header "Bridge: ${bridge}"

  # E2E encryption must be disabled — bridges have no E2E support
  check "modules/bridges/${bridge}.nix" \
    "allow = false" \
    "${bridge}: encryption.allow = false"
  check "modules/bridges/${bridge}.nix" \
    "msc4190 = false" \
    "${bridge}: encryption.msc4190 = false"

  # Loopback-only appservice (NixOS native deployment — not Docker)
  check "modules/bridges/${bridge}.nix" \
    'hostname = "127.0.0.1"' \
    "${bridge}: appservice binds to 127.0.0.1 only (not 0.0.0.0)"

  # Socket peer auth (no passwords — OS user = PG user)
  check "modules/bridges/${bridge}.nix" \
    "postgresql:///mautrix-${bridge}?host=/run/postgresql" \
    "${bridge}: DB uses socket peer auth with mautrix-${bridge} database"

  # Per-service doublepuppet token template (not raw sops secret — would conflict)
  check "modules/bridges/${bridge}.nix" \
    "sops.templates.\"${bridge}-dp-token\"" \
    "${bridge}: uses per-service sops template for doublepuppet token"

  # Runtime secret injection (ExecStartPre Python patching)
  check "modules/bridges/${bridge}.nix" \
    "pkgs.writeShellScript" \
    "${bridge}: ExecStartPre uses writeShellScript for secret injection"
done

# Telegram also needs api_id/api_hash injection
check "modules/bridges/telegram.nix" \
  "api_id" \
  "telegram: injects api_id at runtime"
check "modules/bridges/telegram.nix" \
  "api_hash" \
  "telegram: injects api_hash at runtime"

# ─── PostgreSQL checks ────────────────────────────────────────────────────────
section "PostgreSQL (modules/postgres.nix)"

# Bridge database names must match NixOS service user names for peer auth + ensureDBOwnership
for bridge in telegram whatsapp signal discord; do
  check "modules/postgres.nix" \
    "\"mautrix-${bridge}\"" \
    "postgres: database mautrix-${bridge} (matches service user for ensureDBOwnership)"
done

# Ensure passwords only set for synapse and mas (bridges use peer auth — no passwords)
check "modules/postgres.nix" \
  "set_password synapse" \
  "postgres: sets synapse password"
check "modules/postgres.nix" \
  "set_password mas" \
  "postgres: sets mas password"
no_check "modules/postgres.nix" \
  "set_password mautrix" \
  "postgres: does NOT set bridge passwords (peer auth — no password needed)"

# ─── Secrets structure check ──────────────────────────────────────────────────
section "Secrets (secrets/secrets.yaml)"

# Bridge DB passwords removed (now using peer auth)
no_check "secrets/secrets.yaml" \
  "telegram_db_password" \
  "secrets.yaml: no telegram_db_password (peer auth, no password)"
no_check "secrets/secrets.yaml" \
  "whatsapp_db_password" \
  "secrets.yaml: no whatsapp_db_password (peer auth, no password)"

# Required secrets present
check "secrets/secrets.yaml" \
  "doublepuppet_as_token" \
  "secrets.yaml: doublepuppet_as_token present"
check "secrets/secrets.yaml" \
  "telegram_api_id" \
  "secrets.yaml: telegram_api_id present"
check "secrets/secrets.yaml" \
  "grafana_secret_key" \
  "secrets.yaml: grafana_secret_key present (required since NixOS 26.05)"

# ─── Sops ownership structure ─────────────────────────────────────────────────
section "Sops secret ownership (no conflicting multi-module declarations)"

# Each shared secret must be declared in exactly one module
# Grep all modules for the secret path — count how many declare it in sops.secrets

check_unique_owner() {
  local secret="$1" label="$2"
  # Look for actual sops.secrets declarations: lines of the form
  #   "secret/path" = { ... } or "secret/path".some_attr
  # Use a pattern that matches assignment/declaration, not comments or placeholder references
  local decl_files owners
  decl_files=$(grep -rl "\"${secret}\"" modules/ 2>/dev/null | \
    xargs grep -l "sops\.secrets\b" 2>/dev/null | \
    xargs grep -lE "\"${secret//\//\\/}\" *(=|\\.)" 2>/dev/null || true)
  local count
  count=$(echo "$decl_files" | grep -c "." 2>/dev/null || echo 0)
  if [[ "$count" -le 1 ]]; then
    pass "$label (declared in ${count} module)"
  else
    owners=$(echo "$decl_files" | xargs grep -A2 "\"${secret}\"" 2>/dev/null | \
      grep "owner" | grep -v "^#" | sort -u | wc -l)
    if [[ "$owners" -le 1 ]]; then
      pass "$label (in ${count} modules, same or no owner — OK)"
    else
      fail "$label (in ${count} modules with different owners — CONFLICT)"
    fi
  fi
}

check_unique_owner "matrix/postgres_password" "matrix/postgres_password owner not conflicting"
check_unique_owner "authelia/oidc_client_secret" "authelia/oidc_client_secret owner not conflicting"
check_unique_owner "matrix/synapse_client_secret" "matrix/synapse_client_secret owner not conflicting"
check_unique_owner "bridges/doublepuppet_as_token" "bridges/doublepuppet_as_token owner not conflicting"

# ─── Nix evaluation check ─────────────────────────────────────────────────────
section "Nix evaluation"

NIX="${NIX:-/nix/var/nix/profiles/default/bin/nix}"
if command -v "$NIX" &>/dev/null; then
  if "$NIX" eval .#nixosConfigurations.matrix-server-vm.config.system.stateVersion \
       --no-warn-dirty 2>/dev/null | grep -q "25\|26"; then
    pass "Nix evaluation succeeds (matrix-server-vm)"
  else
    fail "Nix evaluation failed — run: nix build .#nixosConfigurations.matrix-server-vm.config.system.build.vm"
  fi
else
  echo -e "  ${YELLOW}⚠${NC}  Nix not found at ${NIX} — skipping eval check"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
TOTAL=$((PASSED+FAILED))
if [[ "$FAILED" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} checks passed.${NC}"
else
  echo -e "${RED}${BOLD}${FAILED} of ${TOTAL} checks FAILED.${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════${NC}"
[[ "$FAILED" -eq 0 ]]
