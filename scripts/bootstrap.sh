#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — guided one-time setup for a PRODUCTION nixMatrix deployment.
#
# Walks you through everything needed before the first `nixos-anywhere` run:
#   1. Your domain, ACME email, SSH key, and target disk
#   2. An admin age key (so you can edit secrets from this machine)
#   3. A host age key (so the server can decrypt secrets at boot)
#   4. Generating all service secrets and encrypting them with sops
#
# Safe to re-run: it skips anything that already exists and asks before
# overwriting. Run from the repo root:  ./scripts/bootstrap.sh
#
# Prerequisites: nix (with flakes), age, sops, openssl.
#   If age/sops are missing:
#     nix shell nixpkgs#age nixpkgs#sops nixpkgs#openssl
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
info()  { echo "${BLUE}▶${NC} $*"; }
ok()    { echo "${GREEN}✓${NC} $*"; }
warn()  { echo "${YELLOW}!${NC} $*"; }
err()   { echo "${RED}✗${NC} $*" >&2; }
step()  { echo; echo "${BOLD}── $* ──${NC}"; }

# ask "Prompt" "default" -> echoes the answer
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -rp "  $prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    read -rp "  $prompt: " reply
    echo "$reply"
  fi
}

# confirm "Question" -> returns 0 for yes
confirm() {
  local reply
  read -rp "  $1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

# ── Dependency check ─────────────────────────────────────────────────────────
step "Checking dependencies"
missing=()
for cmd in age age-keygen sops openssl; do
  command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
  err "Missing: ${missing[*]}"
  echo "  Enter a shell with them via:"
  echo "      nix shell nixpkgs#age nixpkgs#sops nixpkgs#openssl"
  echo "  then re-run ./scripts/bootstrap.sh"
  exit 1
fi
ok "age, sops, openssl present"

# ── 1. Collect deployment parameters ─────────────────────────────────────────
step "Deployment parameters"
echo "  Use your APEX domain (example.com), not a subdomain — Matrix IDs become"
echo "  @you:example.com and the service hosts (matrix., auth., element. …) are"
echo "  derived from it."
DOMAIN="$(ask "Your Matrix domain (e.g. example.com)")"
[[ -n "$DOMAIN" ]] || { err "Domain is required."; exit 1; }
# Strip an accidental scheme/trailing slash and sanity-check the shape.
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  err "That doesn't look like a domain: '$DOMAIN'"; exit 1
fi
case "$DOMAIN" in
  matrix.*|auth.*|element.*|chat.*|admin.*|www.*)
    warn "'$DOMAIN' looks like a SUBDOMAIN. Use the apex (e.g. ${DOMAIN#*.})."
    confirm "Use '$DOMAIN' anyway?" || { err "Aborted — re-run with your apex domain."; exit 1; } ;;
esac
ACME_EMAIL="$(ask "ACME / Let's Encrypt contact email" "admin@${DOMAIN}")"

DEFAULT_KEY=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  if [[ -f "$k" ]]; then
    DEFAULT_KEY="$(cat "$k")"
    break
  fi
done
echo "  Your SSH public key authorizes root login (password auth is disabled)."
SSH_KEY="$(ask "SSH public key" "$DEFAULT_KEY")"
[[ -n "$SSH_KEY" ]] || { err "An SSH public key is required or you'll be locked out."; exit 1; }
if [[ ! "$SSH_KEY" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-) ]]; then
  err "That doesn't look like an SSH public key (expected it to start with"
  err "'ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-', …). Got: ${SSH_KEY:0:20}…"
  err "Tip: it's the contents of ~/.ssh/id_ed25519.pub, not the private key."
  exit 1
fi

echo "  Target disk on the server (check with 'lsblk'): /dev/sda, /dev/vda, /dev/nvme0n1 ..."
DISK="$(ask "Disk device" "/dev/sda")"

# ── 2. Write parameters into the Nix config ──────────────────────────────────
step "Writing config files"
HOST="hosts/matrix-server.nix"

sed -i "s|nixmatrix.domain = \"[^\"]*\";|nixmatrix.domain = \"${DOMAIN}\";|" "$HOST"
ok "Set nixmatrix.domain = \"${DOMAIN}\""

# Uncomment & set acmeEmail (the template ships it commented out)
sed -i "s|# nixmatrix.acmeEmail = \"[^\"]*\";|nixmatrix.acmeEmail = \"${ACME_EMAIL}\";|" "$HOST"
ok "Set nixmatrix.acmeEmail = \"${ACME_EMAIL}\""

# Replace the commented placeholder SSH key line with the real key.
# A Python here-doc handles substitution safely (keys contain / and +).
SSH_KEY="$SSH_KEY" python3 - "$HOST" <<'PY'
import os, re, sys
path = sys.argv[1]
key = os.environ["SSH_KEY"].strip().replace('"', '\\"')
src = open(path).read()
line = f'    "{key}"\n'
# Replace the first commented placeholder inside the authorizedKeys list.
new, n = re.subn(r'    # "ssh-[^\n]*\n', line, src, count=1)
if n == 0 and key not in src:
    # Already customized previously: insert into the list opener.
    new = src.replace(
        "users.users.root.openssh.authorizedKeys.keys = [\n",
        "users.users.root.openssh.authorizedKeys.keys = [\n" + line, 1)
open(path, "w").write(new)
PY
ok "Added your SSH public key to root authorizedKeys"

sed -i "s|device = \"/dev/[^\"]*\";|device = \"${DISK}\";|" modules/disk.nix
ok "Set disk device = \"${DISK}\""

# ── 3. Admin age key (this workstation) ──────────────────────────────────────
step "Admin age key (this machine)"
ADMIN_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [[ -f "$ADMIN_KEY_FILE" ]]; then
  ok "Reusing existing admin key: $ADMIN_KEY_FILE"
else
  mkdir -p "$(dirname "$ADMIN_KEY_FILE")"
  age-keygen -o "$ADMIN_KEY_FILE"
  chmod 600 "$ADMIN_KEY_FILE"
  ok "Generated admin key: $ADMIN_KEY_FILE"
fi
ADMIN_PUB=""
ADMIN_PUB="$(age-keygen -y "$ADMIN_KEY_FILE")"
info "Admin public key: $ADMIN_PUB"

# ── 4. Host age key (the server) ─────────────────────────────────────────────
step "Host age key (the server)"
EXTRA_FILES_DIR=".bootstrap/extra-files"
HOST_KEY_STAGE="$EXTRA_FILES_DIR/etc/age/key.txt"
if [[ -f "$HOST_KEY_STAGE" ]]; then
  ok "Reusing staged host key: $HOST_KEY_STAGE"
else
  mkdir -p "$(dirname "$HOST_KEY_STAGE")"
  age-keygen -o "$HOST_KEY_STAGE"
  chmod 600 "$HOST_KEY_STAGE"
  ok "Generated host key, staged at: $HOST_KEY_STAGE"
fi
HOST_PUB=""
HOST_PUB="$(age-keygen -y "$HOST_KEY_STAGE")"
info "Host public key: $HOST_PUB"
echo "  This key is copied to the server at /etc/age/key.txt during deploy via"
echo "  nixos-anywhere --extra-files. The host config already reads it."

# ── 5. Write .sops.yaml recipients ───────────────────────────────────────────
step "Configuring sops recipients (.sops.yaml)"
cat > .sops.yaml <<EOF
# sops recipients — both keys can decrypt all secrets.
# Generated by scripts/bootstrap.sh. Re-run that script to regenerate.
keys:
  # Target host — /etc/age/key.txt (seeded by nixos-anywhere --extra-files)
  - &host ${HOST_PUB}
  # Admin machine — your dev/ops workstation key
  - &admin ${ADMIN_PUB}

creation_rules:
  - path_regex: secrets/secrets\\.yaml\$
    key_groups:
      - age:
          - *host
          - *admin
EOF
ok "Wrote .sops.yaml with host + admin recipients"

# ── 6. Generate and encrypt secrets ──────────────────────────────────────────
step "Generating service secrets"
SKIP_GEN=0
if [[ -f secrets/secrets.yaml ]] && sops -d secrets/secrets.yaml &>/dev/null; then
  warn "secrets/secrets.yaml already exists and decrypts."
  if ! confirm "Regenerate ALL secrets (overwrites existing)?"; then
    info "Keeping existing secrets. Re-encrypting to current recipients..."
    sops updatekeys -y secrets/secrets.yaml && ok "Re-encrypted to current recipients"
    SKIP_GEN=1
  fi
fi

if [[ "$SKIP_GEN" != "1" ]]; then
  hex() { openssl rand -hex 32; }
  RSA_KEY=""
  RSA_KEY="$(openssl genrsa 4096 2>/dev/null | openssl pkcs8 -topk8 -nocrypt 2>/dev/null)"

  # Authelia's OIDC issuer needs its own RSA key (the module derives jwks from it).
  OIDC_RSA_KEY=""
  OIDC_RSA_KEY="$(openssl genrsa 4096 2>/dev/null | openssl pkcs8 -topk8 -nocrypt 2>/dev/null)"

  # Bridges are opt-in (nixmatrix.bridges.<net>.enable, default off). Only the
  # Telegram bridge needs credentials baked into secrets.yaml, so only prompt
  # for them if the user actually plans to enable it.
  TG_ID="0"
  TG_HASH="REPLACE_ME"
  echo "  Messaging bridges (Telegram/WhatsApp/Signal/Discord) are OFF by default."
  echo "  Enable the ones you want later in hosts/matrix-server.nix:"
  echo "      nixmatrix.bridges.whatsapp.enable = true;   # etc."
  if confirm "Will you use the TELEGRAM bridge? (it needs API credentials now)"; then
    echo "  Get these from https://my.telegram.org → API development tools."
    echo "  (You can still leave them blank and add them later via 'sops secrets/secrets.yaml'.)"
    TG_ID="$(ask "telegram_api_id (numeric)" "0")"
    TG_HASH="$(ask "telegram_api_hash" "REPLACE_ME")"
  fi

  # Write the plaintext to the FINAL filename and encrypt in place. sops matches
  # creation_rules against the file path, and .sops.yaml anchors on
  # secrets/secrets.yaml$ — a *.plaintext suffix would not match.
  {
    echo "matrix:"
    echo "    postgres_password: $(hex)"
    echo "    mas_secret_key: $(hex)"
    echo "    mas_signing_key: |"
    echo "$RSA_KEY" | sed 's/^/        /'
    echo "    synapse_client_secret: $(hex)"
    echo "    synapse_admin_token: $(hex)"
    echo "    livekit_secret: $(hex)"
    echo "    grafana_secret_key: $(hex)"
    echo ""
    echo "authelia:"
    echo "    jwt_secret: $(hex)"
    echo "    session_secret: $(hex)"
    echo "    storage_encryption_key: $(hex)"
    echo "    oidc_hmac_secret: $(hex)"
    echo "    oidc_issuer_private_key: |"
    echo "$OIDC_RSA_KEY" | sed 's/^/        /'
    echo "    oidc_client_secret: $(hex)"
    echo ""
    echo "bridges:"
    echo "    doublepuppet_as_token: $(hex)"
    echo "    doublepuppet_hs_token: $(hex)"
    echo "    telegram_api_id: \"${TG_ID}\""
    echo "    telegram_api_hash: ${TG_HASH}"
  } > secrets/secrets.yaml

  SOPS_AGE_KEY_FILE="$ADMIN_KEY_FILE" sops --encrypt --in-place secrets/secrets.yaml
  ok "Generated and encrypted secrets/secrets.yaml"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
step "Bootstrap complete"
cat <<EOF

  Next steps:

  ${BOLD}1. Point DNS at your server${NC} (A records). Easiest is a wildcard:
       *.${DOMAIN}  → <SERVER_IP>     plus apex  ${DOMAIN} → <SERVER_IP>
     (covers matrix./auth./element./chat./admin./rtc./call./monitoring.)

  ${BOLD}2. Pre-flight check${NC} (DNS, ports, server specs — guides you to what's
     not ready yet):
       ./scripts/preflight.sh USER@<SERVER_IP>
     and the static config check:
       ./test/check-nix.sh

  ${BOLD}3. Deploy${NC} (reinstalls the target as NixOS — backup first!):
       nix run github:nix-community/nixos-anywhere -- \\
         --flake .#matrix-server \\
         --target-host USER@<SERVER_IP> \\
         --extra-files ${EXTRA_FILES_DIR} \\
         -i ~/.ssh/id_rsa

  ${BOLD}4. Later config changes:${NC}
       nixos-rebuild switch --flake .#matrix-server --target-host root@<SERVER_IP>

  ${BOLD}Optional features${NC} (off by default — enable in hosts/matrix-server.nix):
    • Messaging bridges:  nixmatrix.bridges.whatsapp.enable = true;  (etc.)
    • Public self-signup: nixmatrix.openRegistration = true;  (else admin-only)
    • SSO via Authelia:   nixmatrix.sso.enable = true;
        Ships an example login admin / changeme — CHANGE IT before exposing.
  ${BOLD}After deploying${NC}, create your first user and verify federation —
  see docs/DEPLOY.md §6 (post-install) and §9 (known limitations: calls/TURN).

  To edit secrets later:  sops secrets/secrets.yaml
  Full guide:             docs/DEPLOY.md

  ${YELLOW}Keep these private (gitignored): ${ADMIN_KEY_FILE} and ${EXTRA_FILES_DIR}/${NC}
EOF
