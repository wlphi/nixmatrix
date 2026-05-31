#!/usr/bin/env bash
# =============================================================================
# restore-db.sh — restore one PostgreSQL database from a nixmatrix backup.
#
# Run this ON THE SERVER, as root (or via: ssh root@server '...'):
#   ./scripts/restore-db.sh <database> <backup-file.sql.zst>
#
# Example:
#   ./scripts/restore-db.sh synapse /var/backup/postgresql/synapse.sql.zst
#
# Backups are produced daily by services.postgresqlBackup at
# /var/backup/postgresql/<db>.sql.zst (plain SQL, zstd-compressed).
#
# What it does, for the named database only:
#   1. stops the services that use it (so it can be dropped cleanly)
#   2. drops and recreates the database, owned by its service role
#   3. restores the dump
#   4. starts the services again
#
# This is DESTRUCTIVE: the current contents of <database> are replaced. It asks
# for confirmation first. Restore one database at a time; for a full recovery,
# run it once per database (see the loop at the bottom of this header).
#
#   for db in synapse mas authelia \
#             mautrix-telegram mautrix-whatsapp mautrix-signal mautrix-discord; do
#     ./scripts/restore-db.sh "$db" "/var/backup/postgresql/$db.sql.zst"
#   done
# =============================================================================

set -euo pipefail

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi
err() { echo "${RED}✗${NC} $*" >&2; }
ok()  { echo "${GREEN}✓${NC} $*"; }

DB="${1:-}"
BACKUP="${2:-}"

if [[ -z "$DB" || -z "$BACKUP" ]]; then
  err "Usage: $0 <database> <backup-file.sql.zst>"
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  err "Run as root (the restore stops services and uses the postgres superuser)."
  exit 1
fi
if [[ ! -f "$BACKUP" ]]; then
  err "Backup file not found: $BACKUP"
  exit 1
fi

# Map each database to the systemd services that hold connections to it.
case "$DB" in
  synapse)          SERVICES="matrix-synapse" ;;
  mas)              SERVICES="matrix-authentication-service" ;;
  authelia)         SERVICES="authelia-main" ;;
  mautrix-telegram) SERVICES="mautrix-telegram" ;;
  mautrix-whatsapp) SERVICES="mautrix-whatsapp" ;;
  mautrix-signal)   SERVICES="mautrix-signal" ;;
  mautrix-discord)  SERVICES="mautrix-discord" ;;
  *)
    err "Unknown database '$DB'. Expected one of: synapse, mas, authelia, mautrix-telegram, mautrix-whatsapp, mautrix-signal, mautrix-discord."
    exit 1 ;;
esac

# The DB is owned by a role of the same name (ensureDBOwnership in postgres.nix).
ROLE="$DB"

echo "${YELLOW}This will REPLACE the contents of database '${DB}' with:${NC}"
echo "  $BACKUP"
echo "Services to stop/start: $SERVICES"
read -rp "Type the database name to confirm: " confirm
if [[ "$confirm" != "$DB" ]]; then
  err "Confirmation did not match. Aborted."
  exit 1
fi

# Only stop services that actually exist on this host (a disabled bridge has none).
running=()
for svc in $SERVICES; do
  if systemctl list-unit-files "${svc}.service" &>/dev/null \
     && systemctl cat "${svc}.service" &>/dev/null; then
    running+=("$svc")
  fi
done

if (( ${#running[@]} )); then
  echo "Stopping: ${running[*]}"
  systemctl stop "${running[@]}"
fi

restore() {
  # Run as the postgres superuser. psql -v ON_ERROR_STOP makes a failed restore
  # exit non-zero instead of leaving a half-populated database.
  # Terminate any leftover connections, then drop + recreate owned by the role.
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '${DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${DB}";
CREATE DATABASE "${DB}" OWNER "${ROLE}";
SQL
  zstd -dc "$BACKUP" | sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB"
}

echo "Restoring '${DB}' from $BACKUP ..."
if restore; then
  ok "Restored database '${DB}'."
else
  err "Restore FAILED. Services left stopped so you can investigate before they run on a half-restored DB."
  exit 1
fi

if (( ${#running[@]} )); then
  echo "Starting: ${running[*]}"
  systemctl start "${running[@]}"
fi
ok "Done. Check service health: systemctl status ${SERVICES}"
