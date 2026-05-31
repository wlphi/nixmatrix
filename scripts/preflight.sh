#!/usr/bin/env bash
# =============================================================================
# preflight.sh — check everything is ready BEFORE you run nixos-anywhere.
#
# Read-only and safe: it touches nothing, just tells you what's not ready yet.
# Run it after ./scripts/bootstrap.sh and after pointing DNS at your server:
#
#   ./scripts/preflight.sh user@SERVER_IP
#   ./scripts/preflight.sh root@SERVER_IP
#
# It checks the things that bite people during a real deploy:
#   • your domain is set (not still example.com)
#   • DNS: the apex AND every service subdomain resolve to your server
#   • the server: reachable, x86_64, enough RAM/disk, sudo/root, UEFI
#   • ports 80/443 reachable (needed for Let's Encrypt + the services)
#   • your SSH key actually logs in
#
# Exit code: 0 if ready to deploy, 1 if any blocker, with hints for each.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
ok()   { echo "  ${GREEN}✓${NC} $*"; }
bad()  { echo "  ${RED}✗${NC} $*"; FAILS=$((FAILS+1)); }
warn() { echo "  ${YELLOW}!${NC} $*"; WARNS=$((WARNS+1)); }
hint() { echo "      ${BLUE}→${NC} $*"; }
step() { echo; echo "${BOLD}── $* ──${NC}"; }

FAILS=0; WARNS=0

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <user@server-ip>"
  echo "  e.g. $0 root@203.0.113.10"
  exit 2
fi
HOSTADDR="${TARGET#*@}"

# Helpers ---------------------------------------------------------------------
have() { command -v "$1" &>/dev/null; }

# Resolve an A record using whatever tool is available, via a public resolver
# so we see what the world sees (not a stale local cache).
resolve_a() {
  local name="$1"
  if have dig; then dig +short +time=4 +tries=1 A "$name" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.' | head -1
  elif have host; then host -W4 -t A "$name" 1.1.1.1 2>/dev/null | awk '/has address/{print $NF; exit}'
  elif have getent; then getent hosts "$name" 2>/dev/null | awk '{print $1; exit}'
  fi
}

port_open() { timeout "${3:-6}" bash -c "cat </dev/null >/dev/tcp/$1/$2" 2>/dev/null; }

SSH="ssh -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15"

# ── 1. Domain configured ─────────────────────────────────────────────────────
step "Domain"
DOMAIN="$(grep -oE 'nixmatrix\.domain = "[^"]+"' hosts/matrix-server.nix 2>/dev/null | sed -E 's/.*"([^"]+)"/\1/')"
if [[ -z "$DOMAIN" ]]; then
  bad "Could not read nixmatrix.domain from hosts/matrix-server.nix"
elif [[ "$DOMAIN" == "example.com" ]]; then
  bad "nixmatrix.domain is still 'example.com' — run ./scripts/bootstrap.sh first"
else
  ok "Domain: $DOMAIN"
fi

# ── 2. DNS ───────────────────────────────────────────────────────────────────
step "DNS (apex + service subdomains → your server)"
if [[ -z "$DOMAIN" || "$DOMAIN" == "example.com" ]]; then
  warn "skipping DNS checks until the domain is set"
else
  if ! have dig && ! have host && ! have getent; then
    warn "no dig/host/getent available — cannot check DNS from here"
  else
    apex_ip="$(resolve_a "$DOMAIN")"
    if [[ -z "$apex_ip" ]]; then
      bad "$DOMAIN has no A record"
      hint "add an A record: $DOMAIN → $HOSTADDR"
    else
      ok "$DOMAIN → $apex_ip"
      [[ "$apex_ip" == "$HOSTADDR" ]] || warn "apex points at $apex_ip but you're deploying to $HOSTADDR"
    fi
    # Every subdomain the stack serves. A wildcard *.$DOMAIN covers them all.
    miss=0
    for sub in matrix auth element chat admin rtc call monitoring; do
      ip="$(resolve_a "$sub.$DOMAIN")"
      if [[ -z "$ip" ]]; then bad "$sub.$DOMAIN → (missing)"; miss=$((miss+1))
      elif [[ -n "$apex_ip" && "$ip" != "$apex_ip" ]]; then warn "$sub.$DOMAIN → $ip (differs from apex)"
      else ok "$sub.$DOMAIN → $ip"; fi
    done
    if (( miss > 0 )); then
      hint "easiest fix: one wildcard A record  *.$DOMAIN → $HOSTADDR"
      hint "Let's Encrypt issues a cert per subdomain on first boot — all must resolve."
    fi
  fi
fi

# ── 3. Reachability + ports ──────────────────────────────────────────────────
step "Network reachability"
if port_open "$HOSTADDR" 22; then
  ok "SSH port 22 reachable on $HOSTADDR"
else
  bad "cannot reach $HOSTADDR:22"
  hint "check the server is up and the firewall allows tcp:22 from your IP"
fi
for p in 80 443; do
  # A bare server has nothing listening yet → connection refused (instant) is OK;
  # a silent timeout means a firewall is dropping it.
  if port_open "$HOSTADDR" "$p" 5; then
    ok "port $p reachable (something already listening)"
  else
    # distinguish refused (fw open) vs timeout (fw closed) by timing
    t0=$EPOCHSECONDS; port_open "$HOSTADDR" "$p" 6; t1=$EPOCHSECONDS
    if (( t1 - t0 >= 5 )); then
      bad "port $p appears firewalled (connection timed out)"
      hint "open tcp:$p to the internet — needed for Let's Encrypt + the services"
    else
      ok "port $p firewall-open (refused; nothing listening yet — fine pre-deploy)"
    fi
  fi
done

# ── 4. The server itself (needs SSH login) ───────────────────────────────────
step "Server (via SSH as $TARGET)"
if ! $SSH "$TARGET" true 2>/dev/null; then
  bad "SSH login failed for $TARGET"
  hint "make sure your public key is in that user's authorized_keys (or GCP/cloud metadata)"
  hint "test manually: ssh $TARGET"
else
  ok "SSH login works"
  facts="$($SSH "$TARGET" 'echo "ARCH=$(uname -m)"; echo "MEMKB=$(awk "/MemTotal/{print \$2}" /proc/meminfo)"; echo "DISKGB=$(lsblk -bdno SIZE 2>/dev/null | sort -rn | head -1 | awk "{printf \"%d\", \$1/1000000000}")"; echo "EFI=$([ -d /sys/firmware/efi ] && echo yes || echo no)"; echo "SUDO=$(sudo -n true 2>/dev/null && echo yes || echo no)"; echo "ID=$(. /etc/os-release 2>/dev/null; echo $ID)"' 2>/dev/null)"
  eval "$facts" 2>/dev/null

  case "${ARCH:-}" in
    x86_64) ok "Architecture: x86_64" ;;
    aarch64|arm64) bad "Architecture: ${ARCH} — this flake targets x86_64-linux only" ;;
    *) warn "Architecture: ${ARCH:-unknown}" ;;
  esac

  memgb=$(( ${MEMKB:-0} / 1000000 ))
  if   (( ${MEMKB:-0} >= 7000000 )); then ok "RAM: ~${memgb} GB"
  elif (( ${MEMKB:-0} >= 3500000 )); then warn "RAM: ~${memgb} GB (4 GB works; 8 GB recommended with bridges/calls)"
  else bad "RAM: ~${memgb} GB — too low; use 4 GB minimum"; fi

  if   (( ${DISKGB:-0} >= 20 )); then ok "Disk: ~${DISKGB} GB"
  elif (( ${DISKGB:-0} >= 1 )); then bad "Disk: ~${DISKGB} GB — too small; resize to ≥20 GB (the closure + data won't fit)"
  else warn "Disk: could not determine size"; fi

  [[ "${SUDO:-}" == "yes" ]] && ok "Root/sudo available" || bad "no passwordless sudo (nixos-anywhere needs root)"
  [[ "${EFI:-}" == "yes" ]] && ok "UEFI boot" || warn "BIOS boot (config assumes UEFI; review modules/disk.nix)"
  [[ -n "${ID:-}" ]] && ok "Current OS: ${ID} (will be ERASED and replaced with NixOS)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "${BOLD}═══════════════════════════════════════${NC}"
if (( FAILS == 0 )); then
  echo "${GREEN}${BOLD}Ready to deploy.${NC} ${WARNS} warning(s)."
  echo "Next: nix run github:numtide/nixos-anywhere -- --flake .#matrix-server \\"
  echo "        --target-host $TARGET --extra-files .bootstrap/extra-files -i ~/.ssh/id_rsa --force-kexec"
else
  echo "${RED}${BOLD}${FAILS} blocker(s)${NC} and ${WARNS} warning(s) — fix the ✗ items above first."
fi
echo "${BOLD}═══════════════════════════════════════${NC}"
(( FAILS == 0 ))
