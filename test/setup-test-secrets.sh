#!/usr/bin/env bash
# One-time setup for local VM testing.
# Generates a test age key and encrypts a test secrets file with dummy values.
# Run from the repo root: ./test/setup-test-secrets.sh
#
# Prerequisites: age, sops
#   Debian: apt install age sops
#   Or with Nix: nix shell nixpkgs#age nixpkgs#sops

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

# ── Check dependencies ─────────────────────────────────────────────────────
for cmd in age sops; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found."
    echo "Install: sudo apt install age sops"
    echo "  OR: nix shell nixpkgs#age nixpkgs#sops"
    exit 1
  fi
done

# ── Generate test age key ──────────────────────────────────────────────────
KEY_FILE="test/test-age-key.txt"
if [[ -f "$KEY_FILE" ]]; then
  echo "✓ Test age key already exists: $KEY_FILE"
else
  echo "Generating test age key..."
  age-keygen -o "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "✓ Generated: $KEY_FILE"
fi

# Extract the public key
PUBKEY=$(grep "public key:" "$KEY_FILE" | awk '{print $NF}')
echo "  Public key: $PUBKEY"

# ── Write test sops config ─────────────────────────────────────────────────
cat > test/test-sops.yaml <<EOF
keys:
  - &testkey ${PUBKEY}
creation_rules:
  # path_regex is matched relative to THIS config file's directory (test/),
  # so the basename is correct here — not test/test-secrets.yaml.
  - path_regex: test-secrets\.yaml\$
    key_groups:
      - age:
          - *testkey
EOF
echo "✓ Wrote test/test-sops.yaml"

# ── Write and encrypt test secrets ────────────────────────────────────────
SECRETS_FILE="test/test-secrets.yaml"

if [[ -f "$SECRETS_FILE" ]]; then
  echo "✓ Test secrets already exist: $SECRETS_FILE"
  echo "  Delete test/test-secrets.yaml and rerun to regenerate."
  exit 0
fi

# Write plaintext template with dummy hex values (valid format for all services)
DUMMY_HEX=$(openssl rand -hex 32)
DUMMY_HEX2=$(openssl rand -hex 32)
DUMMY_HEX5=$(openssl rand -hex 32)
DUMMY_HEX6=$(openssl rand -hex 32)
DUMMY_HEX7=$(openssl rand -hex 32)
DUMMY_HEX8=$(openssl rand -hex 32)
DUMMY_HEX9=$(openssl rand -hex 32)
DUMMY_HEX10=$(openssl rand -hex 32)
DUMMY_HEX11=$(openssl rand -hex 32)
DUMMY_HEX12=$(openssl rand -hex 32)
DUMMY_HEX13=$(openssl rand -hex 32)
DUMMY_HEX14=$(openssl rand -hex 32)
DUMMY_HEX15=$(openssl rand -hex 32)

# Generate a dummy RSA key for MAS signing
DUMMY_RSA_KEY=$(openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -nocrypt 2>/dev/null)
# Separate dummy RSA key for Authelia's OIDC issuer (jwks is derived from it)
DUMMY_OIDC_RSA_KEY=$(openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -nocrypt 2>/dev/null)

cat > "${SECRETS_FILE}" <<EOF
matrix:
    postgres_password: ${DUMMY_HEX}
    # MAS encryption secret must be exactly 32 bytes = 64 hex chars (one rand -hex 32).
    # Concatenating two would make it 64 bytes and MAS rejects it at startup.
    mas_secret_key: ${DUMMY_HEX2}
    mas_signing_key: |
$(echo "$DUMMY_RSA_KEY" | sed 's/^/        /')
    synapse_client_secret: ${DUMMY_HEX5}
    synapse_admin_token: ${DUMMY_HEX6}
    livekit_secret: ${DUMMY_HEX7}
    grafana_secret_key: $(openssl rand -hex 32)

authelia:
    jwt_secret: ${DUMMY_HEX8}
    session_secret: ${DUMMY_HEX9}
    storage_encryption_key: ${DUMMY_HEX10}
    oidc_hmac_secret: $(openssl rand -hex 32)
    oidc_issuer_private_key: |
$(echo "$DUMMY_OIDC_RSA_KEY" | sed 's/^/        /')
    oidc_client_secret: ${DUMMY_HEX11}

bridges:
    doublepuppet_as_token: ${DUMMY_HEX12}
    doublepuppet_hs_token: ${DUMMY_HEX13}
    telegram_api_id: "12345678"
    telegram_api_hash: ${DUMMY_HEX14}
    telegram_db_password: ${DUMMY_HEX15}
    whatsapp_db_password: $(openssl rand -hex 32)
    signal_db_password: $(openssl rand -hex 32)
    discord_db_password: $(openssl rand -hex 32)
    hookshot_as_token: $(openssl rand -hex 32)
    hookshot_hs_token: $(openssl rand -hex 32)
EOF

echo "Encrypting test secrets with sops..."
# Encrypt in place on the final filename so the sops creation_rule (anchored
# on test-secrets.yaml$) matches. Encrypting a *.plaintext file would not match.
SOPS_AGE_KEY_FILE="$KEY_FILE" sops \
  --config test/test-sops.yaml \
  --encrypt --in-place "${SECRETS_FILE}"

echo "✓ Encrypted test secrets: $SECRETS_FILE"
echo ""
echo "Done! Now build the VM:"
echo "  nixos-rebuild build-vm --flake .#matrix-server-vm"
echo "  ./result/bin/run-nixmatrix-vm"
echo ""
echo "SSH into running VM: ssh -p 2222 root@localhost (password: root)"
