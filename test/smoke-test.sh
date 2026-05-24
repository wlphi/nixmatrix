#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh — Integration tests for the running NixOS VM.
#
# Tests the actual live services inside the VM: rendered configs, HTTP routing,
# CORS headers, OIDC discovery, permissions, and bridge health.
# Adapted from matrix-2/test_deploy.sh assert_configs() + assert_endpoints().
#
# Run from the HOST machine after the VM has booted:
#   ssh -p 2222 -o StrictHostKeyChecking=no root@localhost bash < test/smoke-test.sh
#
# Or directly inside the VM:
#   bash /path/to/smoke-test.sh
#
# Notes:
#   - VM runs with auto_https off (HTTP only) and dummy sops secrets.
#   - Services that need valid credentials (bridges, Authelia DB) may show
#     as failed/activating — this is expected with test secrets.
#   - Core infra (PostgreSQL, Redis, Caddy, MAS, Synapse) should be running.
#
# Exit code: 0 if all pass, 1 if any fail.
# =============================================================================

set -euo pipefail

# ─── Colors / counters ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

PASSED=0; FAILED=0; WARNED=0

pass()   { echo -e "  ${GREEN}✓${NC} $1"; PASSED=$((PASSED+1)); }
fail()   { echo -e "  ${RED}✗${NC} $1"; FAILED=$((FAILED+1)); }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; WARNED=$((WARNED+1)); }
info()   { echo -e "  ${BLUE}ℹ${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }
section(){ echo -e "\n${BOLD}${MAGENTA}════ $1 ════${NC}"; }

# Assert a file exists
assert_file() {
  local f="$1" label="$2"
  [[ -f "$f" ]] && pass "$label exists" || fail "$label missing: $f"
}

# Assert file contains fixed string
assert_contains() {
  local f="$1" pat="$2" label="$3"
  grep -qF -- "$pat" "$f" 2>/dev/null && pass "$label" || fail "$label (pattern not found: ${pat})"
}

# Assert file does NOT contain fixed string
assert_not_contains() {
  local f="$1" pat="$2" label="$3"
  ! grep -qF -- "$pat" "$f" 2>/dev/null && pass "$label" || fail "$label (bad pattern present: ${pat})"
}

# Assert valid YAML syntax (warns instead of failing if python3 unavailable)
assert_valid_yaml() {
  local f="$1"
  if ! command -v python3 &>/dev/null; then
    warn "$f YAML parse skipped (python3 not in PATH)"
    return
  fi
  if python3 -c "import yaml, sys; yaml.safe_load(open('$f'))" 2>/dev/null; then
    pass "$f is valid YAML"
  else
    fail "$f failed YAML parse"
  fi
}

# Curl via Caddy on port 443 (VM uses tls internal — self-signed certs).
# Use --resolve to send the correct SNI so Caddy matches the right vhost and cert.
# -k skips cert trust check (self-signed CA not in system trust store in VM).
curl_h() {
  local host="$1" path="$2"
  curl -sfk --connect-timeout 5 \
    --resolve "${host}:443:127.0.0.1" \
    "https://${host}${path}" 2>/dev/null || true
}

curl_h_status() {
  local host="$1" path="$2"
  curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    --resolve "${host}:443:127.0.0.1" \
    "https://${host}${path}" 2>/dev/null || echo "000"
}

curl_cors() {
  local host="$1" path="$2" origin="$3"
  curl -sIk --connect-timeout 5 -X OPTIONS \
    -H "Origin: ${origin}" \
    -H "Access-Control-Request-Method: GET" \
    --resolve "${host}:443:127.0.0.1" \
    "https://${host}${path}" 2>/dev/null || true
}

# Wait for a service to be active (or return failed status without aborting)
service_active() {
  local svc="$1"
  systemctl is-active --quiet "$svc" 2>/dev/null
}

# ─── Service health ────────────────────────────────────────────────────────────
section "Core service health"

for svc in postgresql redis-authelia caddy nginx; do
  service_active "$svc" \
    && pass "$svc is active" \
    || fail "$svc is NOT active"
done

# MAS and Synapse may take longer / may be activating with test secrets
header "Matrix services (may be slow with test secrets)"
for svc in matrix-authentication-service matrix-synapse; do
  if service_active "$svc"; then
    pass "$svc is active"
  else
    status=$(systemctl show -p SubState --value "$svc" 2>/dev/null || echo "unknown")
    warn "$svc is not active (SubState: ${status}) — expected with test secrets"
  fi
done

# Bridge services: expected to fail/restart with test credentials
header "Bridge services (expected to fail with test secrets)"
for svc in mautrix-telegram mautrix-whatsapp mautrix-signal mautrix-discord; do
  status=$(systemctl show -p SubState --value "$svc" 2>/dev/null || echo "unknown")
  if service_active "$svc"; then
    pass "$svc active"
  else
    warn "$svc not active (SubState: ${status}) — bridges need real credentials"
  fi
done

# ─── Sops secrets decrypted ────────────────────────────────────────────────────
section "Sops secrets decrypted"

SECRETS="/run/secrets"
for secret in matrix/postgres_password matrix/mas_secret_key matrix/mas_signing_key \
              matrix/synapse_shared_secret matrix/synapse_client_secret \
              authelia/jwt_secret bridges/doublepuppet_as_token bridges/doublepuppet_hs_token \
              bridges/telegram_api_id bridges/telegram_api_hash matrix/grafana_secret_key; do
  [[ -f "${SECRETS}/${secret}" ]] \
    && pass "/run/secrets/${secret} decrypted" \
    || fail "/run/secrets/${secret} missing — sops decryption failed?"
done

# Sops template files
for tmpl in mas-config synapse-extra-config doublepuppet-registration \
            telegram-dp-token whatsapp-dp-token signal-dp-token discord-dp-token; do
  [[ -f "${SECRETS}/rendered/${tmpl}" ]] \
    && pass "/run/secrets/rendered/${tmpl} rendered" \
    || fail "/run/secrets/rendered/${tmpl} missing"
done

# ─── MAS config correctness ────────────────────────────────────────────────────
section "MAS rendered config (/run/secrets/rendered/mas-config)"

MAS_CFG="/run/secrets/rendered/mas-config"
assert_file "$MAS_CFG" "MAS rendered config"

if [[ -f "$MAS_CFG" ]]; then
  assert_valid_yaml "$MAS_CFG"

  # Bug #2: assets resource must be present or login pages are unstyled
  assert_contains "$MAS_CFG" "- name: assets" \
    "MAS config: assets resource present (Bug #2 — unstyled login)"

  # adminapi resource required for Ketesa
  assert_contains "$MAS_CFG" "- name: adminapi" \
    "MAS config: adminapi resource present"

  # Bug #3: fetch_userinfo must be true
  assert_contains "$MAS_CFG" "fetch_userinfo: true" \
    "MAS config: fetch_userinfo: true (Bug #3 — empty localpart)"

  # Bug #8: internal discovery URL uses localhost HTTP not HTTPS to Authelia
  assert_contains "$MAS_CFG" "discovery_url: \"http://localhost:9091" \
    "MAS config: discovery_url uses localhost HTTP (Bug #8 — TLS bypass)"

  # Issuer is the public auth domain (not localhost or internal)
  assert_contains "$MAS_CFG" "issuer: \"https://auth.mair.io/\"" \
    "MAS config: issuer = https://auth.mair.io/"
  assert_contains "$MAS_CFG" "public_base: \"https://auth.mair.io/\"" \
    "MAS config: public_base = https://auth.mair.io/"

  # Synapse endpoint uses localhost (NixOS same-host deployment)
  assert_contains "$MAS_CFG" "endpoint: \"http://localhost:8008\"" \
    "MAS config: Synapse endpoint = http://localhost:8008"

  # Bug #6: claims use preferred_username not name
  assert_contains "$MAS_CFG" "user.preferred_username" \
    "MAS config: claims template uses preferred_username (Bug #6)"

  # Registration disabled (policy.data.registration, not policy.registration)
  assert_contains "$MAS_CFG" "enabled: false" \
    "MAS config: registration disabled"
  assert_contains "$MAS_CFG" "data:" \
    "MAS config: policy.data nesting (not policy.registration which is silently ignored)"

  # Argon2id password hashing
  assert_contains "$MAS_CFG" "algorithm: argon2id" \
    "MAS config: argon2id hashing scheme"

  # OIDC clients
  assert_contains "$MAS_CFG" "im.fluffychat://login" \
    "MAS config: FluffyChat native redirect URI registered"
  assert_contains "$MAS_CFG" "01ADMN00000000000000000000" \
    "MAS config: Ketesa OIDC client (26-char ULID)"
fi

# ─── Doublepuppet registration ─────────────────────────────────────────────────
section "Doublepuppet registration (/var/lib/matrix-synapse/appservices/doublepuppet.yaml)"

DP_YAML="/var/lib/matrix-synapse/appservices/doublepuppet.yaml"
assert_file "$DP_YAML" "doublepuppet.yaml"

if [[ -f "$DP_YAML" ]]; then
  assert_valid_yaml "$DP_YAML"

  # CRITICAL: url must be null — a URL triggers transaction retry storms
  assert_contains "$DP_YAML" "url: null" \
    "doublepuppet.yaml: url is null (prevents retry storms)"

  assert_contains "$DP_YAML" "id: doublepuppet" \
    "doublepuppet.yaml: correct id"

  # as_token and hs_token must be present (non-placeholder values)
  assert_contains "$DP_YAML" "as_token:" \
    "doublepuppet.yaml: as_token field present"
  assert_contains "$DP_YAML" "hs_token:" \
    "doublepuppet.yaml: hs_token field present"

  # Token values must not be the placeholder (test secrets should have real dummy hex)
  assert_not_contains "$DP_YAML" "REPLACE_AT_RUNTIME" \
    "doublepuppet.yaml: as_token is not REPLACE_AT_RUNTIME placeholder"

  # User namespace regex must match mair.io
  assert_contains "$DP_YAML" "@.*:mair.io" \
    "doublepuppet.yaml: user namespace regex matches mair.io"

  assert_contains "$DP_YAML" "exclusive: false" \
    "doublepuppet.yaml: non-exclusive namespace (bridges and users coexist)"
fi

# ─── Synapse extra config ──────────────────────────────────────────────────────
section "Synapse extra config (/run/secrets/rendered/synapse-extra-config)"

SYN_EXTRA="/run/secrets/rendered/synapse-extra-config"
if [[ -f "$SYN_EXTRA" ]]; then
  assert_valid_yaml "$SYN_EXTRA"
  assert_contains "$SYN_EXTRA" "msc3861" \
    "Synapse extra config: MSC3861 block present"
  assert_contains "$SYN_EXTRA" "issuer: \"https://auth.mair.io/\"" \
    "Synapse extra config: MSC3861 issuer = https://auth.mair.io/"
  assert_contains "$SYN_EXTRA" "client_id: \"0000000000000000000SYNAPSE\"" \
    "Synapse extra config: MSC3861 client_id correct"
fi

# ─── Directory permissions ─────────────────────────────────────────────────────
section "Directory permissions (regression: Docker issue #21)"

# MAS data dir must be 755 — MAS (uid=mas) cannot enter a 700 directory
mas_mode=$(stat -c '%a' /var/lib/matrix-authentication-service 2>/dev/null || echo "missing")
[[ "$mas_mode" == "755" ]] \
  && pass "/var/lib/matrix-authentication-service mode 755 (MAS needs to enter it)" \
  || fail "/var/lib/matrix-authentication-service mode is ${mas_mode} (need 755)"

# MAS rendered config must be 644 — crash-loop symptom is "missing field secrets" (EACCES)
mas_cfg_mode=$(stat -c '%a' "$MAS_CFG" 2>/dev/null || echo "missing")
[[ "$mas_cfg_mode" == "644" ]] \
  && pass "MAS rendered config mode 644 (crash-loop prevention)" \
  || warn "MAS rendered config mode is ${mas_cfg_mode} (expected 644)"

# MAS signing key must be 400 (private RSA key)
mas_key_mode=$(stat -c '%a' /run/secrets/matrix/mas_signing_key 2>/dev/null || echo "missing")
[[ "$mas_key_mode" == "400" ]] \
  && pass "MAS signing key mode 400" \
  || warn "MAS signing key mode is ${mas_key_mode} (expected 400)"

# Bridge data directories owned by service users
for bridge in telegram whatsapp signal discord; do
  bridge_dir="/var/lib/mautrix-${bridge}"
  if [[ -d "$bridge_dir" ]]; then
    owner=$(stat -c '%U' "$bridge_dir" 2>/dev/null || echo "missing")
    [[ "$owner" == "mautrix-${bridge}" ]] \
      && pass "mautrix-${bridge} data dir owned by mautrix-${bridge}" \
      || warn "mautrix-${bridge} data dir owned by ${owner} (expected mautrix-${bridge})"
  else
    warn "mautrix-${bridge} data dir not yet created (bridge never started)"
  fi
done

# ─── PostgreSQL databases ──────────────────────────────────────────────────────
section "PostgreSQL databases"

if service_active postgresql; then
  for db in synapse mas mautrix-telegram mautrix-whatsapp mautrix-signal mautrix-discord authelia; do
    sudo -u postgres psql -lqt 2>/dev/null | cut -d\| -f1 | grep -qw "$db" \
      && pass "PostgreSQL database '${db}' exists" \
      || fail "PostgreSQL database '${db}' missing"
  done

  # Bridge users exist and are correct
  for user in mautrix-telegram mautrix-whatsapp mautrix-signal mautrix-discord; do
    sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='${user}'" 2>/dev/null | grep -q "1 row" \
      && pass "PostgreSQL user '${user}' exists" \
      || fail "PostgreSQL user '${user}' missing"
  done
else
  warn "PostgreSQL not active — skipping DB checks"
fi

# ─── HTTP endpoint tests ───────────────────────────────────────────────────────
section "HTTP endpoints (via Caddy port 443 with tls internal + Host headers)"

info "Warming up Caddy TLS certs (tls internal generates certs on first connection)..."
for domain in mair.io matrix.mair.io auth.mair.io element.mair.io \
              chat.mair.io admin.mair.io authelia.mair.io \
              rtc.mair.io call.mair.io monitoring.mair.io; do
  curl -sk --connect-timeout 5 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" -o /dev/null 2>/dev/null || true
done

# Synapse direct health (bypass Caddy)
syn_health=$(curl -sf --connect-timeout 5 "http://localhost:8008/health" 2>/dev/null || echo "FAIL")
[[ "$syn_health" == "OK" ]] \
  && pass "Synapse /health → OK" \
  || warn "Synapse /health: '${syn_health}' (may be starting up with test secrets)"

# MAS internal health endpoint
mas_health=$(curl -sf --connect-timeout 5 "http://localhost:8081/health" 2>/dev/null || echo "FAIL")
[[ "$mas_health" == "OK" ]] \
  && pass "MAS :8081/health → OK" \
  || warn "MAS :8081/health: '${mas_health}' (may be starting with test DB credentials)"

# Well-known on root domain (mair.io)
header "Well-known delegation (mair.io)"
wk_root=$(curl_h "mair.io" "/.well-known/matrix/client")
echo "$wk_root" | grep -q '"m.homeserver"' \
  && pass "mair.io /.well-known/matrix/client responds" \
  || fail "mair.io /.well-known/matrix/client: '${wk_root:-no response}'"
echo "$wk_root" | grep -q '"m.authentication"' \
  && pass "mair.io /.well-known includes m.authentication" \
  || fail "mair.io /.well-known missing m.authentication"
echo "$wk_root" | grep -q "auth.mair.io" \
  && pass "mair.io /.well-known m.authentication.issuer = auth.mair.io" \
  || fail "mair.io /.well-known issuer wrong: '${wk_root:-}'"

wk_srv=$(curl_h "mair.io" "/.well-known/matrix/server")
echo "$wk_srv" | grep -q '"m.server"' \
  && pass "mair.io /.well-known/matrix/server responds" \
  || fail "mair.io /.well-known/matrix/server: '${wk_srv:-no response}'"
echo "$wk_srv" | grep -q "matrix.mair.io" \
  && pass "mair.io /.well-known/matrix/server delegates to matrix.mair.io" \
  || fail "mair.io /.well-known/matrix/server wrong: '${wk_srv:-}'"

# Well-known on matrix domain too
header "Well-known on matrix.mair.io"
wk_matrix=$(curl_h "matrix.mair.io" "/.well-known/matrix/client")
echo "$wk_matrix" | grep -q '"m.homeserver"' \
  && pass "matrix.mair.io /.well-known/matrix/client responds" \
  || fail "matrix.mair.io /.well-known/matrix/client: '${wk_matrix:-no response}'"

# Matrix API routing
header "Matrix API routing"
versions_code=$(curl_h_status "matrix.mair.io" "/_matrix/client/versions")
[[ "$versions_code" == "200" ]] \
  && pass "/_matrix/client/versions → 200" \
  || warn "/_matrix/client/versions → ${versions_code} (Synapse may be starting)"

# Login must be proxied to MAS, not left to Synapse (which returns 404 for /login)
login=$(curl_h "matrix.mair.io" "/_matrix/client/v3/login")
echo "$login" | grep -qE '"flows"|"type"|"session"' \
  && pass "/_matrix/client/v3/login → MAS (returns login flows)" \
  || warn "/_matrix/client/v3/login: '${login:-no response}' (Caddy routing issue or MAS down)"

# Register must be proxied to MAS (not Synapse which always 403s when registration=false)
reg_code=$(curl_h_status "matrix.mair.io" "/_matrix/client/v3/register")
[[ "$reg_code" != "403" || "$reg_code" == "404" ]] \
  && pass "/_matrix/client/v3/register → MAS (not Synapse 403)" \
  || warn "/_matrix/client/v3/register → 403 (may be Synapse handling instead of MAS)"

# MAS OIDC discovery (Issue #16 regression: issuer must be public URL, not localhost)
header "MAS OIDC discovery (Issue #16 regression)"
oidc=$(curl_h "auth.mair.io" "/.well-known/openid-configuration")
echo "$oidc" | grep -q '"issuer"' \
  && pass "MAS /.well-known/openid-configuration responds" \
  || warn "MAS OIDC discovery: '${oidc:-no response}' (MAS may be starting)"
echo "$oidc" | grep -q '"issuer":"https://auth.mair.io/"' \
  && pass "MAS OIDC issuer = https://auth.mair.io/ (not internal host)" \
  || warn "MAS OIDC issuer wrong (Issue #16): '${oidc:-}'"

# CORS: /_matrix/client/versions must return CORS header
header "CORS headers"
cors_matrix=$(curl_cors "matrix.mair.io" "/_matrix/client/versions" "https://element.mair.io")
echo "$cors_matrix" | grep -qi "access-control-allow-origin:" \
  && pass "/_matrix/client/versions: CORS header present" \
  || warn "/_matrix/client/versions: missing CORS header — web clients will fail"

cors_login=$(curl_cors "matrix.mair.io" "/_matrix/client/v3/login" "https://element.mair.io")
echo "$cors_login" | grep -qi "access-control-allow-origin:" \
  && pass "/_matrix/client/v3/login: CORS header present" \
  || warn "/_matrix/client/v3/login: missing CORS header"

# Issue #22 regression: /_synapse/admin CORS must be scoped to admin.mair.io
cors_admin=$(curl_cors "matrix.mair.io" "/_synapse/admin/v1/server_version" "https://admin.mair.io")
echo "$cors_admin" | grep -qi "access-control-allow-origin:.*admin.mair.io" \
  && pass "/_synapse/admin: CORS scoped to admin.mair.io (Issue #22)" \
  || warn "/_synapse/admin: CORS header missing or wrong origin (Issue #22 regression)"

# ─── Client app frontends (nginx) ─────────────────────────────────────────────
section "Client frontends (nginx → Caddy proxy)"

# element.mair.io → nginx on :8765
element_code=$(curl_h_status "element.mair.io" "/")
[[ "$element_code" == "200" ]] \
  && pass "element.mair.io → 200 (Element Web served)" \
  || fail "element.mair.io → ${element_code} (expected 200)"

# admin.mair.io → nginx on :8767 (404 from Ketesa SPA = nginx is up, routing works)
admin_code=$(curl_h_status "admin.mair.io" "/")
[[ "$admin_code" =~ ^(200|404)$ ]] \
  && pass "admin.mair.io → ${admin_code} (Ketesa nginx responding)" \
  || fail "admin.mair.io → ${admin_code} (nginx not responding)"

# auth.mair.io/account/* → MAS proxy (502 = MAS down as expected; 000 or 404 = Caddy routing bug)
account_code=$(curl_h_status "auth.mair.io" "/account/login")
[[ "$account_code" == "502" ]] \
  && pass "auth.mair.io/account/* → 502 (proxied to MAS — handle not handle_path)" \
  || [[ "$account_code" == "200" ]] \
  && pass "auth.mair.io/account/* → 200 (MAS account portal)" \
  || fail "auth.mair.io/account/* → ${account_code} (expected 502 or 200, not 000/404)"

# monitoring.mair.io → Grafana on :3000
grafana_code=$(curl_h_status "monitoring.mair.io" "/api/health")
[[ "$grafana_code" == "200" ]] \
  && pass "monitoring.mair.io/api/health → 200 (Grafana via Caddy)" \
  || fail "monitoring.mair.io/api/health → ${grafana_code} (Grafana not responding)"

# Prometheus internal health (not behind Caddy — internal service)
prom_code=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 5 "http://localhost:9090/-/ready" 2>/dev/null || echo "000")
[[ "$prom_code" == "200" ]] \
  && pass "Prometheus :9090/-/ready → 200" \
  || fail "Prometheus :9090/-/ready → ${prom_code}"

# ─── PostgreSQL peer auth ──────────────────────────────────────────────────────
section "PostgreSQL peer auth (bridge users connect to their own DB)"

# Each bridge service user must be able to connect via Unix socket peer auth.
# This verifies the DB name = unix user name = PG user name invariant.
for bridge in telegram whatsapp signal discord; do
  if sudo -u "mautrix-${bridge}" psql -d "mautrix-${bridge}" -c "SELECT 1" &>/dev/null; then
    pass "mautrix-${bridge}: peer auth works (user ↔ DB name match)"
  else
    fail "mautrix-${bridge}: peer auth FAILED — DB name or user mismatch"
  fi
done

# ─── Bridge health endpoints ───────────────────────────────────────────────────
section "Bridge health endpoints (expected 200 if bridge started, any non-5xx acceptable)"

declare -A bridge_ports=(
  [telegram]=29317
  [whatsapp]=29318
  [signal]=29328
  [discord]=29334
)

for bridge in telegram whatsapp signal discord; do
  port=${bridge_ports[$bridge]}
  code=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 3 \
    "http://localhost:${port}/health" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    pass "mautrix-${bridge} health (port ${port}) → 200"
  elif [[ "$code" == "000" ]]; then
    warn "mautrix-${bridge} (port ${port}) not responding (bridge not running — expected with test creds)"
  else
    warn "mautrix-${bridge} health (port ${port}) → HTTP ${code}"
  fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
TOTAL=$((PASSED+FAILED+WARNED))
echo -e "${GREEN}${BOLD}${PASSED} passed${NC}  ${RED}${BOLD}${FAILED} failed${NC}  ${YELLOW}${BOLD}${WARNED} warnings${NC}  (${TOTAL} total)"
if [[ "$FAILED" -gt 0 ]]; then
  echo -e "${RED}${BOLD}FAILED — check the output above for details.${NC}"
elif [[ "$WARNED" -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}WARNINGS — review yellow items above (may be test-secrets limitations).${NC}"
else
  echo -e "${GREEN}${BOLD}All checks passed.${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
[[ "$FAILED" -eq 0 ]]
