#!/usr/bin/env bash
# ============================================================
#  borg-backup.sh — Main Backup Script (runs on each client)
#  Triggered by: systemd timer or cron
#  Install at:   /usr/local/bin/borg-backup.sh
#  chmod +x /usr/local/bin/borg-backup.sh
# ============================================================
set -euo pipefail

# ── Load config ───────────────────────────────────────────────
CONFIG="/etc/borg-client.conf"
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG — run borg-client-setup.sh first"; exit 1; }
source "$CONFIG"

PASS_FILE="/root/.borg-passphrase"
[[ -f "$PASS_FILE" ]] || { echo "Missing $PASS_FILE"; exit 1; }

export BORG_PASSPHRASE=$(cat "$PASS_FILE")
export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new"
export BORG_REPO="$BORG_REMOTE_REPO"
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no

LOG_FILE="/var/log/borg/backup-$(date +%Y%m%d).log"
mkdir -p /var/log/borg
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
START_EPOCH=$(date +%s)

# ── Colors (for interactive runs) ─────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo "[$TIMESTAMP] $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }

# ── Lock file (prevent overlapping backups) ───────────────────
LOCK_FILE="/tmp/borg-backup.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  warn "Another borg backup is already running (lock: $LOCK_FILE). Exiting."
  exit 1
fi

# ── Trap for cleanup and failure alert ───────────────────────
BACKUP_STATUS=0
cleanup() {
  local EXIT_CODE=$?
  flock -u 9
  if (( EXIT_CODE != 0 )) && [[ -n "${ALERT_EMAIL:-}" ]]; then
    DURATION=$(( $(date +%s) - START_EPOCH ))
    {
      echo "BorgBackup FAILED on $(hostname) at $(date)"
      echo "Duration: ${DURATION}s"
      echo "Exit code: $EXIT_CODE"
      echo "Log: $LOG_FILE"
      echo ""
      echo "Last 20 lines of log:"
      tail -20 "$LOG_FILE"
    } | mail -s "[BACKUP FAILED] $(hostname) — $(date +%Y-%m-%d)" "${ALERT_EMAIL}"
  fi
}
trap cleanup EXIT


log "════════════════════════════════════════════════"
log "  BorgBackup starting — $REPO_HOSTNAME"
log "  Repo: $BORG_REMOTE_REPO"
log "════════════════════════════════════════════════"


# ── Step 1: Pre-backup hooks ──────────────────────────────────
log "[1/5] Running pre-backup tasks..."

# Database dumps
DB_DUMP_DIR="/var/backups/db-dumps"
mkdir -p "$DB_DUMP_DIR"

if [[ "${DB_TYPE:-none}" == "mysql" || "${DB_TYPE:-none}" == "mariadb" ]]; then
  log "  Dumping MySQL/MariaDB databases..."
  if mysqldump -u root -p"${DB_PASS:-}" --all-databases \
       --single-transaction --quick --routines --events \
       --flush-logs 2>/dev/null > "$DB_DUMP_DIR/mysql-all-$(date +%Y%m%d).sql"; then
    gzip -f "$DB_DUMP_DIR/mysql-all-$(date +%Y%m%d).sql"
    # Keep only last 3 dumps locally
    ls -t "$DB_DUMP_DIR"/mysql-all-*.sql.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    success "  MySQL dump complete."
  else
    warn "  MySQL dump failed — continuing without it."
  fi

elif [[ "${DB_TYPE:-none}" == "postgresql" ]]; then
  log "  Dumping PostgreSQL databases..."
  if sudo -u "${PG_USER:-postgres}" pg_dumpall \
       > "$DB_DUMP_DIR/postgres-all-$(date +%Y%m%d).sql" 2>/dev/null; then
    gzip -f "$DB_DUMP_DIR/postgres-all-$(date +%Y%m%d).sql"
    ls -t "$DB_DUMP_DIR"/postgres-all-*.sql.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    success "  PostgreSQL dump complete."
  else
    warn "  PostgreSQL dump failed — continuing without it."
  fi
fi

# System package list (handy for rebuilding)
dpkg --get-selections > /var/backups/installed-packages.txt 2>/dev/null || true
pip3 freeze > /var/backups/pip-packages.txt 2>/dev/null || true

# Docker: list running containers and their images
if command -v docker &>/dev/null; then
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" > /var/backups/docker-containers.txt 2>/dev/null || true
fi

# Crontab dump
crontab -l > /var/backups/crontab-root.txt 2>/dev/null || true
systemctl list-timers --no-pager > /var/backups/systemd-timers.txt 2>/dev/null || true


# ── Step 2: Create archive ────────────────────────────────────
log "[2/5] Creating borg archive..."

ARCHIVE_NAME="${REPO_HOSTNAME}-$(date +%Y-%m-%dT%H:%M:%S)"

# Build exclude list
EXCLUDES=(
  # Common cache/temp dirs
  "--exclude" "sh:/root/.cache"
  "--exclude" "sh:/home/*/.cache"
  "--exclude" "sh:/tmp"
  "--exclude" "sh:/var/tmp"
  "--exclude" "sh:/proc"
  "--exclude" "sh:/sys"
  "--exclude" "sh:/dev"
  "--exclude" "sh:/run"
  "--exclude" "sh:/mnt"
  "--exclude" "sh:/media"
  "--exclude" "sh:/lost+found"
  # VM/container related
  "--exclude" "sh:/var/lib/lxcfs"
  "--exclude" "sh:/var/lib/docker/overlay2"
  "--exclude" "sh:/snap"
  # Log rotated archives (raw logs in /var/log still included)
  "--exclude" "sh:/var/log/*.gz"
  "--exclude" "sh:/var/log/**/*.gz"
  # Node modules
  "--exclude" "sh:*/node_modules"
  # Python virtualenvs
  "--exclude" "sh:*/.venv"
  "--exclude" "sh:*/venv"
  # Swap
  "--exclude" "sh:/swapfile"
  "--exclude" "sh:/*.swap"
)

# Expand BACKUP_PATHS into array — only include paths that exist
IFS=' ' read -ra RAW_PATHS <<< "$BACKUP_PATHS"
PATHS_ARRAY=()
for P in "${RAW_PATHS[@]}" "/var/backups"; do
  if [[ -e "$P" ]]; then
    PATHS_ARRAY+=("$P")
  else
    warn "  Skipping non-existent path: $P"
  fi
done
if [[ ${#PATHS_ARRAY[@]} -eq 0 ]]; then
  error "No valid backup paths found. Check BACKUP_PATHS in /etc/borg-client.conf"
  exit 1
fi
log "  Backing up: ${PATHS_ARRAY[*]}" 

if borg create \
    --stats \
    --show-rc \
    --compression zstd,3 \
    --exclude-caches \
    --keep-exclude-tags \
    --checkpoint-interval 300 \
    "${EXCLUDES[@]}" \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    "${PATHS_ARRAY[@]}" \
    2>&1 | tee -a "$LOG_FILE"; then
  success "Archive created: $ARCHIVE_NAME"
else
  BORG_EXIT=${PIPESTATUS[0]}
  if (( BORG_EXIT == 1 )); then
    warn "Borg exited with warnings (code 1) — backup likely succeeded with minor issues."
  else
    error "Borg create failed with exit code $BORG_EXIT."
    exit $BORG_EXIT
  fi
fi


# ── Step 3: Prune old archives ────────────────────────────────
log "[3/5] Pruning old archives..."

# borg 1.x uses --glob-archives, borg 2.x uses --match-archives
# The sh: pattern prefix is only used with borg 2.x --match-archives
BORG_MAJOR=$(borg --version | awk '{print $2}' | cut -d. -f1)
if (( BORG_MAJOR >= 2 )); then
  PRUNE_PATTERN_FLAG="--match-archives"
  PRUNE_PATTERN="sh:${REPO_HOSTNAME}-*"
else
  PRUNE_PATTERN_FLAG="--glob-archives"
  PRUNE_PATTERN="${REPO_HOSTNAME}-*"
fi

PRUNE_OUT=$(borg prune \
    --list \
    --show-rc \
    "$PRUNE_PATTERN_FLAG" "$PRUNE_PATTERN" \
    --keep-daily   7    \
    --keep-weekly  4    \
    --keep-monthly 6    \
    --keep-yearly  2    \
    "$BORG_REPO" 2>&1) && PRUNE_RC=0 || PRUNE_RC=$?
echo "$PRUNE_OUT" | tee -a "$LOG_FILE"
if (( PRUNE_RC == 0 )); then
  success "Prune complete."
else
  warn "Prune exited with rc=$PRUNE_RC (non-fatal). Check log."
fi


# ── Step 4: Compact the repo ─────────────────────────────────
# NOTE: compact may fail if server uses --append-only (ransomware protection mode).
# In that case, run 'borg compact' from the SERVER side manually or via server cron.
log "[4/5] Compacting repository (skipped if server is --append-only)..."
COMPACT_OUT=$(borg compact "$BORG_REPO" 2>&1) && COMPACT_RC=0 || COMPACT_RC=$?
echo "$COMPACT_OUT" | tee -a "$LOG_FILE"
if (( COMPACT_RC == 0 )); then
  success "Compact complete."
else
  warn "Compact skipped (rc=$COMPACT_RC) — server likely uses --append-only. Run compact from server."
fi


# ── Step 5: Verify latest archive ────────────────────────────
log "[5/5] Verifying latest archive integrity..."
LATEST=$(borg list "$BORG_REPO" --last 1 --format "{archive}" 2>/dev/null | tail -1)
if [[ -n "$LATEST" ]]; then
  if borg check --verify-data --last 1 "$BORG_REPO" 2>&1 | tee -a "$LOG_FILE"; then
    success "Archive integrity check passed: $LATEST"
  else
    warn "Archive check had warnings — review log."
  fi
fi


# ── Final report ──────────────────────────────────────────────
END_EPOCH=$(date +%s)
DURATION=$(( END_EPOCH - START_EPOCH ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))

log "════════════════════════════════════════════════"
log "  Backup COMPLETE — ${MINUTES}m ${SECONDS}s"
log "  Host:    $REPO_HOSTNAME"
log "  Archive: $ARCHIVE_NAME"
log "  Log:     $LOG_FILE"
log "════════════════════════════════════════════════"

# Success notification (optional — only if ALERT_EMAIL set)
if [[ -n "${ALERT_EMAIL:-}" ]]; then
  # Only send success mail on Sundays (weekly summary)
  if [[ $(date +%u) == 7 ]]; then
    {
      echo "Weekly BorgBackup report for $(hostname)"
      echo "Date: $(date)"
      echo "Duration: ${MINUTES}m ${SECONDS}s"
      echo ""
      echo "Archives:"
      borg list "$BORG_REPO" --format "{archive:<60} {time} {size}" 2>/dev/null | tail -20
      echo ""
      echo "Repo info:"
      borg info "$BORG_REPO" 2>/dev/null | tail -15
    } | mail -s "[BACKUP OK] $(hostname) weekly summary" "${ALERT_EMAIL}"
  fi
fi

unset BORG_PASSPHRASE
exit 0
