#!/usr/bin/env bash
# ============================================================
#  borg-client-setup.sh — BorgBackup Client Setup
#  Run on: every machine you want backed up
#  Run as: sudo bash borg-client-setup.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"; }
ask()     { echo -e "${YELLOW}[?]${NC} $*"; }

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash $0"; exit 1; }

LOG="/var/log/borg-client-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

clear
echo -e "${BOLD}${BLUE}  BorgBackup Client Setup${NC}"
echo -e "${CYAN}  Configures this machine to back up to your central Borg server${NC}\n"

# ── Configuration ─────────────────────────────────────────────
section "CONFIGURATION"

CLIENT_HOSTNAME=$(hostname -s)
info "This machine's hostname: ${BOLD}$CLIENT_HOSTNAME${NC}"
ask "Override hostname used for repo name? (leave blank to use '$CLIENT_HOSTNAME'):"
read -r OVERRIDE_HOST
REPO_HOSTNAME="${OVERRIDE_HOST:-$CLIENT_HOSTNAME}"

ask "Backup server IP or hostname (e.g. 192.168.1.50):"
read -r BORG_SERVER
[[ -z "$BORG_SERVER" ]] && { error "Server address is required."; exit 1; }

ask "Borg user on server (default: borg):"
read -r BORG_REMOTE_USER; BORG_REMOTE_USER="${BORG_REMOTE_USER:-borg}"

ask "SSH port of the backup server (default: 22):"
read -r BORG_SERVER_PORT; BORG_SERVER_PORT="${BORG_SERVER_PORT:-22}"

ask "Borg repo encryption passphrase (keep this safe — you need it to restore!):"
read -rs BORG_PASSPHRASE; echo
[[ -z "$BORG_PASSPHRASE" ]] && { error "Passphrase cannot be empty."; exit 1; }
ask "Confirm passphrase:"
read -rs BORG_PASSPHRASE2; echo
[[ "$BORG_PASSPHRASE" != "$BORG_PASSPHRASE2" ]] && { error "Passphrases do not match."; exit 1; }

ask "Local paths to back up (space-separated, default: /etc /home /root /var/www /opt):"
read -r BACKUP_PATHS
BACKUP_PATHS="${BACKUP_PATHS:-/etc /home /root /var/www /opt}"

ask "Backup schedule — cron time (default: '0 2 * * *' = 2 AM daily):"
read -r BACKUP_CRON; BACKUP_CRON="${BACKUP_CRON:-0 2 * * *}"

ask "Alert email on backup failure (leave blank to skip):"
read -r ALERT_EMAIL

ask "Run a pre-backup database dump? (mysql/postgresql/none) [default: none]:"
read -r DB_TYPE; DB_TYPE="${DB_TYPE:-none}"

if [[ "$DB_TYPE" == "mysql" || "$DB_TYPE" == "mariadb" ]]; then
  ask "MySQL/MariaDB root password (for mysqldump):"
  read -rs DB_PASS; echo
elif [[ "$DB_TYPE" == "postgresql" ]]; then
  ask "PostgreSQL user for pg_dumpall (default: postgres):"
  read -r PG_USER; PG_USER="${PG_USER:-postgres}"
fi

# Review
section "REVIEW"
echo -e "  Hostname for repo:  ${BOLD}$REPO_HOSTNAME${NC}"
echo -e "  Server:             ${BOLD}$BORG_REMOTE_USER@${BORG_SERVER}:${BORG_SERVER_PORT}${NC}"
echo -e "  Remote repo:        ${BOLD}/backup/repos/$REPO_HOSTNAME${NC}"
echo -e "  Backup paths:       ${BOLD}$BACKUP_PATHS${NC}"
echo -e "  Schedule:           ${BOLD}$BACKUP_CRON${NC}"
echo -e "  DB dump:            ${BOLD}$DB_TYPE${NC}"
echo -e "  Alert email:        ${BOLD}${ALERT_EMAIL:-none}${NC}"
echo ""
ask "Proceed? (yes/no):"
read -r CONFIRM; [[ "$CONFIRM" != "yes" ]] && exit 0


# ── 1. Install borgbackup ─────────────────────────────────────
section "1 — INSTALL BORGBACKUP"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq borgbackup openssh-client curl
success "BorgBackup $(borg --version) installed."


# ── 2. SSH key for borg ───────────────────────────────────────
section "2 — SSH KEY GENERATION"

BORG_KEY_PATH="/root/.ssh/borg_client"
if [[ -f "$BORG_KEY_PATH" ]]; then
  warn "SSH key already exists at $BORG_KEY_PATH — skipping generation."
else
  ssh-keygen -t ed25519 -f "$BORG_KEY_PATH" -N "" -C "borg-backup-${REPO_HOSTNAME}"
  success "SSH key generated: $BORG_KEY_PATH"
fi

chmod 600 "$BORG_KEY_PATH"
chmod 644 "${BORG_KEY_PATH}.pub"

echo ""
echo -e "${YELLOW}${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}${BOLD}  ACTION REQUIRED — Copy this key to the backup server:${NC}"
echo -e "${YELLOW}${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Run this on the backup server (Dell T320):${NC}"
echo -e "  ${BOLD}sudo register-client.sh $REPO_HOSTNAME '$(cat ${BORG_KEY_PATH}.pub)'${NC}"
echo ""
echo -e "  ${CYAN}Or run the interactive version:${NC}"
echo -e "  ${BOLD}sudo register-client.sh${NC}"
echo -e "  ${CYAN}Then paste this public key:${NC}"
echo ""
cat "${BORG_KEY_PATH}.pub"
echo ""
echo -e "${YELLOW}${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
ask "Press ENTER after you have registered the key on the server..."
read -r


# ── 3. SSH config for borg ────────────────────────────────────
section "3 — SSH CLIENT CONFIG"
mkdir -p /root/.ssh
BORG_SSH_CONFIG="/root/.ssh/config"
if ! grep -q "Host borg-server" "$BORG_SSH_CONFIG" 2>/dev/null; then
  cat >> "$BORG_SSH_CONFIG" << EOF

# BorgBackup server — added by borg-client-setup.sh
Host borg-server
    HostName $BORG_SERVER
    User $BORG_REMOTE_USER
    Port $BORG_SERVER_PORT
    IdentityFile $BORG_KEY_PATH
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
  chmod 600 "$BORG_SSH_CONFIG"
  success "SSH config written for 'borg-server' alias."
fi

# Test SSH connectivity — borg user has ForceCommand so we test with borg info
# which is a valid borg protocol exchange (will fail if repo doesn't exist yet,
# but a clean "repository does not exist" error means SSH itself worked fine)
info "Testing SSH connection to backup server..."
export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes -o IdentitiesOnly=yes"
export BORG_PASSPHRASE
SSH_TEST_OUTPUT=$(borg info "ssh://$BORG_REMOTE_USER@$BORG_SERVER/backup/repos/$REPO_HOSTNAME" 2>&1 || true)

if echo "$SSH_TEST_OUTPUT" | grep -qiE "repository|does not exist|passphrase|stats|archive"; then
  success "SSH connection to backup server successful (borg protocol responding)."
elif echo "$SSH_TEST_OUTPUT" | grep -qiE "connection refused|no route|timeout|network"; then
  warn "Could not connect to backup server. Possible reasons:"
  echo "    - Key not yet registered on server (run register-client.sh)"
  echo "    - Wrong IP/port"
  echo "    - Firewall blocking port $BORG_SERVER_PORT"
  echo ""
  ask "Continue anyway? (yes to continue, no to abort):"
  read -r CONT; [[ "$CONT" != "yes" ]] && exit 1
else
  warn "SSH connected but got unexpected response — check manually if needed."
  info "Manual test: ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT $BORG_REMOTE_USER@$BORG_SERVER"
fi


# ── 4. Save client config ─────────────────────────────────────
section "4 — CLIENT CONFIG"
REMOTE_REPO="ssh://borg-server/backup/$REPO_HOSTNAME"

cat > /etc/borg-client.conf << EOF
# BorgBackup client config — generated $(date)
BORG_SERVER=$BORG_SERVER
BORG_REMOTE_USER=$BORG_REMOTE_USER
BORG_SERVER_PORT=$BORG_SERVER_PORT
BORG_REMOTE_REPO=$REMOTE_REPO
BORG_KEY_PATH=$BORG_KEY_PATH
REPO_HOSTNAME=$REPO_HOSTNAME
BACKUP_PATHS="$BACKUP_PATHS"
ALERT_EMAIL="${ALERT_EMAIL:-}"
DB_TYPE=$DB_TYPE
DB_PASS="${DB_PASS:-}"
PG_USER="${PG_USER:-postgres}"
EOF
chmod 600 /etc/borg-client.conf

# Store passphrase in a root-only file
cat > /root/.borg-passphrase << EOF
$BORG_PASSPHRASE
EOF
chmod 600 /root/.borg-passphrase
success "Config saved to /etc/borg-client.conf"
success "Passphrase saved to /root/.borg-passphrase (chmod 600, root only)"


# ── 5. Initialize borg repo on server ────────────────────────
section "5 — INITIALIZE BORG REPOSITORY"
export BORG_PASSPHRASE
export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

info "Initializing encrypted repo at $REMOTE_REPO ..."
INIT_OUTPUT=$(borg init --encryption=repokey-blake2 "$REMOTE_REPO" 2>&1) && INIT_RC=0 || INIT_RC=$?

if (( INIT_RC == 0 )); then
  success "Borg repository initialized with repokey-blake2 encryption."
  echo "$INIT_OUTPUT"
elif echo "$INIT_OUTPUT" | grep -qi "already exists\|already a borg"; then
  warn "Repository already initialised — skipping (this is OK)."
else
  error "borg init failed (rc=$INIT_RC):"
  echo "$INIT_OUTPUT"
  error "Cannot continue. Fix the error above then re-run this script."
  exit $INIT_RC
fi

# Export repo key (critical for disaster recovery)
KEY_EXPORT_PATH="/root/borg-repokey-${REPO_HOSTNAME}.key"
if borg key export "$REMOTE_REPO" "$KEY_EXPORT_PATH" 2>/dev/null; then
  chmod 600 "$KEY_EXPORT_PATH"
  success "Repo key exported to $KEY_EXPORT_PATH — BACK THIS UP SECURELY!"
else
  warn "Could not export repo key. Run manually once init succeeds:"
  echo "  BORG_PASSPHRASE=\$(cat /root/.borg-passphrase) \\"
  echo "  borg key export $REMOTE_REPO /root/borg-repokey-${REPO_HOSTNAME}.key"
fi

unset BORG_PASSPHRASE


# ── 6. Install backup script (embedded) ──────────────────────
section "6 — INSTALL BACKUP SCRIPT"
info "Writing borg-backup.sh to /usr/local/bin/borg-backup.sh ..."
cat > /usr/local/bin/borg-backup.sh << 'BORGBACKUPEOF'
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

BORGBACKUPEOF
chmod +x /usr/local/bin/borg-backup.sh
success "borg-backup.sh installed at /usr/local/bin/borg-backup.sh"



# ── 6b. Install restore script ────────────────────────────────
info "Writing borg-restore.sh to /usr/local/bin/borg-restore.sh ..."
cat > /usr/local/bin/borg-restore.sh << 'BORGRESTOREEOF'
#!/usr/bin/env bash
# ============================================================
#  borg-restore.sh — Interactive Restore Helper
#  Run on: the CLIENT machine (or anywhere with borg + SSH key)
#  Run as: sudo bash borg-restore.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"; }
ask()     { echo -e "${YELLOW}[?]${NC} $*"; }

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash $0"; exit 1; }

clear
echo -e "${BOLD}${BLUE}  BorgBackup — Interactive Restore${NC}\n"

# ── Load client config or prompt ─────────────────────────────
CONFIG="/etc/borg-client.conf"
PASS_FILE="/root/.borg-passphrase"

if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
  info "Loaded config from $CONFIG"
  BORG_REPO="$BORG_REMOTE_REPO"
  export BORG_PASSPHRASE=$(cat "$PASS_FILE")
  export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
else
  warn "No /etc/borg-client.conf found — manual mode."
  ask "Borg repo URL (e.g. ssh://borg-server/backup/repos/hostname):"
  read -r BORG_REPO
  ask "SSH key path (e.g. /root/.ssh/borg_client):"
  read -r BORG_KEY_PATH
  ask "SSH port (default 22):"
  read -r BORG_SERVER_PORT; BORG_SERVER_PORT="${BORG_SERVER_PORT:-22}"
  ask "Borg passphrase:"
  read -rs BORG_PASSPHRASE; echo
  export BORG_PASSPHRASE
  export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi


# ── Choose restore mode ───────────────────────────────────────
section "RESTORE MODE"
echo "  1) Browse and restore specific files/directories"
echo "  2) Restore entire archive to a directory"
echo "  3) Mount archive as read-only filesystem (browse interactively)"
echo "  4) List all archives only"
echo "  5) Restore to disaster recovery target (bare metal)"
echo ""
ask "Choose restore mode (1-5):"
read -r MODE


# ── List archives ─────────────────────────────────────────────
section "AVAILABLE ARCHIVES"
info "Fetching archive list from $BORG_REPO ..."
echo ""

info "Connecting to repository..."
# Use --short for clean one-line-per-archive output
ARCHIVE_NAMES=$(borg list --short "$BORG_REPO" 2>&1) && LIST_RC=0 || LIST_RC=$?

if (( LIST_RC != 0 )); then
  error "Could not list archives (rc=$LIST_RC):"
  echo "$ARCHIVE_NAMES"
  echo ""
  echo "  Common causes:"
  echo "  - SSH key not registered: run register-client.sh on the server"
  echo "  - Wrong passphrase in /root/.borg-passphrase"
  echo "  - Server not reachable"
  echo ""
  echo "  Test manually: borg list --short $BORG_REPO"
  exit 1
fi

# Parse into array, newest first
mapfile -t ARCHIVES < <(echo "$ARCHIVE_NAMES" | grep -v '^$' | tac)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
  warn "Repository exists but has no archives yet."
  warn "Run a backup first: systemctl start borg-backup.service"
  exit 0
fi

printf "  %-4s %s\n" "No." "Archive"
printf "  %-4s %s\n" "----" "-------"
for i in "${!ARCHIVES[@]}"; do
  printf "  %-4s %s\n" "$((i+1))" "${ARCHIVES[$i]}"
done

if [[ "$MODE" == "4" ]]; then
  echo ""; exit 0
fi

echo ""
ask "Select archive number (or press ENTER for latest):"
read -r ARCHIVE_NUM

if [[ -z "$ARCHIVE_NUM" ]]; then
  ARCHIVE_NUM=1
fi

if (( ARCHIVE_NUM < 1 || ARCHIVE_NUM > ${#ARCHIVES[@]} )); then
  error "Invalid selection."
  exit 1
fi

SELECTED_ARCHIVE="${ARCHIVES[$((ARCHIVE_NUM-1))]}"
info "Selected archive: ${BOLD}$SELECTED_ARCHIVE${NC}"


# ── Mode 1: Restore specific files ────────────────────────────
if [[ "$MODE" == "1" ]]; then
  section "RESTORE SPECIFIC FILES"
  info "Files/dirs in archive (showing top-level):"
  borg list "${BORG_REPO}::${SELECTED_ARCHIVE}" --short --depth 2 2>/dev/null | head -40

  echo ""
  ask "Path to restore (e.g. 'etc/nginx' or 'home/user/documents'). No leading slash:"
  read -r RESTORE_PATH
  [[ -z "$RESTORE_PATH" ]] && { error "Path required."; exit 1; }

  ask "Restore to directory (default: /tmp/borg-restore):"
  read -r RESTORE_TARGET; RESTORE_TARGET="${RESTORE_TARGET:-/tmp/borg-restore}"
  mkdir -p "$RESTORE_TARGET"

  info "Restoring '$RESTORE_PATH' from '$SELECTED_ARCHIVE' to '$RESTORE_TARGET'..."
  cd "$RESTORE_TARGET"
  borg extract \
      --list \
      --progress \
      "${BORG_REPO}::${SELECTED_ARCHIVE}" \
      "$RESTORE_PATH"

  success "Restore complete."
  info "Files restored to: $RESTORE_TARGET/$RESTORE_PATH"
  echo ""
  warn "Review the restored files before moving them to their original location."
  info "When ready, you can move them back:"
  echo "  cp -a $RESTORE_TARGET/$RESTORE_PATH /$(dirname "$RESTORE_PATH")/"


# ── Mode 2: Restore entire archive ────────────────────────────
elif [[ "$MODE" == "2" ]]; then
  section "RESTORE ENTIRE ARCHIVE"

  ask "Restore target directory (default: /tmp/borg-restore):"
  read -r RESTORE_TARGET; RESTORE_TARGET="${RESTORE_TARGET:-/tmp/borg-restore}"
  mkdir -p "$RESTORE_TARGET"

  warn "This will restore the ENTIRE archive to $RESTORE_TARGET"
  warn "It may take a long time and use significant disk space."
  ask "Confirm? (yes/no):"
  read -r CONF; [[ "$CONF" != "yes" ]] && exit 0

  info "Restoring entire archive to $RESTORE_TARGET..."
  cd "$RESTORE_TARGET"
  borg extract \
      --list \
      --progress \
      --numeric-owner \
      "${BORG_REPO}::${SELECTED_ARCHIVE}"

  success "Full restore complete to $RESTORE_TARGET"


# ── Mode 3: Mount as filesystem ───────────────────────────────
elif [[ "$MODE" == "3" ]]; then
  section "MOUNT ARCHIVE"

  # Check FUSE is available
  if ! command -v borgfs &>/dev/null && ! fusermount -V &>/dev/null 2>/dev/null; then
    error "FUSE is required for mounting. Install: apt-get install fuse"
    exit 1
  fi

  MOUNT_POINT="/tmp/borg-mount-$$"
  mkdir -p "$MOUNT_POINT"

  info "Mounting ${SELECTED_ARCHIVE} at ${MOUNT_POINT} ..."
  borg mount "${BORG_REPO}::${SELECTED_ARCHIVE}" "$MOUNT_POINT"

  success "Archive mounted at $MOUNT_POINT"
  info "Browse it: ls -la $MOUNT_POINT"
  echo ""
  info "When finished, unmount with:"
  echo "  borg umount $MOUNT_POINT"
  echo ""
  ask "Press ENTER when done browsing to auto-unmount..."
  read -r
  borg umount "$MOUNT_POINT" && success "Unmounted." || warn "Unmount may have failed — run: borg umount $MOUNT_POINT"


# ── Mode 5: Disaster recovery ────────────────────────────────
elif [[ "$MODE" == "5" ]]; then
  section "DISASTER RECOVERY RESTORE"
  echo -e "${RED}${BOLD}  ⚠  THIS IS A FULL SYSTEM RESTORE — USE WITH EXTREME CAUTION${NC}"
  echo ""
  info "This mode restores the archive to / (or a chroot target)."
  info "Typical use: booting from a live USB after disk failure."
  echo ""

  ask "Target root filesystem path (e.g. / or /mnt/newdisk):"
  read -r DR_TARGET
  [[ -z "$DR_TARGET" ]] && { error "Target required."; exit 1; }

  if [[ "$DR_TARGET" == "/" ]]; then
    warn "You are restoring DIRECTLY to / on a live system."
    warn "This will overwrite system files immediately."
    ask "Type 'RESTORE-TO-ROOT' to confirm:"
    read -r DR_CONFIRM
    [[ "$DR_CONFIRM" != "RESTORE-TO-ROOT" ]] && exit 0
  fi

  mkdir -p "$DR_TARGET"

  info "Restoring $SELECTED_ARCHIVE to $DR_TARGET ..."
  cd "$DR_TARGET"
  borg extract \
      --list \
      --progress \
      --numeric-owner \
      --strip-components 0 \
      "${BORG_REPO}::${SELECTED_ARCHIVE}"

  success "Disaster recovery restore complete."
  echo ""
  info "Post-restore checklist:"
  echo "  1. chroot $DR_TARGET and reinstall grub:"
  echo "     mount --bind /dev $DR_TARGET/dev"
  echo "     mount --bind /proc $DR_TARGET/proc"
  echo "     mount --bind /sys $DR_TARGET/sys"
  echo "     chroot $DR_TARGET"
  echo "     grub-install /dev/sda && update-grub"
  echo "  2. Review /etc/fstab — update UUIDs if disk changed"
  echo "  3. Reboot"
fi

unset BORG_PASSPHRASE
success "Restore operation finished."

BORGRESTOREEOF
chmod +x /usr/local/bin/borg-restore.sh
success "borg-restore.sh installed at /usr/local/bin/borg-restore.sh"

# ── 7. Systemd service + timer ────────────────────────────────
section "7 — SYSTEMD SERVICE & TIMER"

cat > /etc/systemd/system/borg-backup.service << 'SERVICE'
[Unit]
Description=BorgBackup — Incremental Encrypted Backup
After=network-online.target
Wants=network-online.target
OnFailure=borg-backup-failure@%n.service

[Service]
Type=oneshot
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/usr/local/bin/borg-backup.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=borg-backup

# Safety: never let borg consume all memory
MemoryMax=2G
SERVICE

cat > /etc/systemd/system/borg-backup.timer << EOF
[Unit]
Description=BorgBackup daily timer

[Timer]
OnCalendar=$(echo "$BACKUP_CRON" | awk '{
  min=$1; hr=$2; dom=$3; mon=$4; dow=$5
  if (min=="0" && dom=="*" && mon=="*" && dow=="*") printf "*-*-* %02d:%02d:00", hr+0, min+0
  else print "daily"
}')
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Failure notification service
cat > /etc/systemd/system/borg-backup-failure@.service << EOF
[Unit]
Description=Borg Backup Failure Alert

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo "Borg backup FAILED on \$(hostname) at \$(date)" | mail -s "[BACKUP FAILED] \$(hostname)" "${ALERT_EMAIL:-root}"'
EOF

systemctl daemon-reload
systemctl enable borg-backup.timer
systemctl start borg-backup.timer
success "Systemd timer installed and enabled."
systemctl list-timers borg-backup.timer --no-pager


# ── 8. Run a test backup ──────────────────────────────────────
section "8 — TEST BACKUP"
ask "Run a test backup of /etc now to verify everything works? (yes/no):"
read -r RUN_TEST

if [[ "$RUN_TEST" == "yes" ]]; then
  export BORG_PASSPHRASE=$(cat /root/.borg-passphrase)
  export BORG_RSH="ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

  # Verify repo is accessible before trying a backup
  info "Verifying repository is accessible..."
  if ! borg info "$REMOTE_REPO" &>/dev/null; then
    error "Cannot access repository at $REMOTE_REPO"
    error "Check that the repo was initialised and SSH key is registered on the server."
    echo "  Manual init: BORG_PASSPHRASE=\$(cat /root/.borg-passphrase) \"
    echo "               BORG_RSH=\"ssh -i $BORG_KEY_PATH -p $BORG_SERVER_PORT\" \"
    echo "               borg init --encryption=repokey-blake2 $REMOTE_REPO"
    unset BORG_PASSPHRASE
  else
    ARCHIVE_NAME="${REPO_HOSTNAME}-test-$(date +%Y-%m-%dT%H%M%S)"
    info "Creating test archive: $ARCHIVE_NAME ..."

    if borg create \
        --stats \
        --show-rc \
        --compression lz4 \
        --exclude-caches \
        "${REMOTE_REPO}::${ARCHIVE_NAME}" \
        /etc; then
      success "Test backup succeeded!"
      info "Archives in repo:"
      borg list "$REMOTE_REPO"
    else
      error "Test backup failed. Check the output above."
    fi
    unset BORG_PASSPHRASE
  fi
fi


# ── Summary ───────────────────────────────────────────────────
section "✅  CLIENT SETUP COMPLETE"
echo -e "  ${BOLD}Hostname:${NC}       $REPO_HOSTNAME"
echo -e "  ${BOLD}Backup repo:${NC}    $REMOTE_REPO"
echo -e "  ${BOLD}Schedule:${NC}       $BACKUP_CRON"
echo -e "  ${BOLD}SSH key:${NC}        $BORG_KEY_PATH"
echo -e "  ${BOLD}Repo key:${NC}       $KEY_EXPORT_PATH"
echo -e "  ${BOLD}Config:${NC}         /etc/borg-client.conf"
echo ""
echo -e "${RED}${BOLD}  ⚠  CRITICAL — BACK UP THESE FILES NOW:${NC}"
echo -e "  1. ${BOLD}$KEY_EXPORT_PATH${NC}  — repo key (needed for restore if passphrase lost)"
echo -e "  2. ${BOLD}/root/.borg-passphrase${NC}  — passphrase"
echo -e "     Store both OFFLINE and SEPARATELY from this server!"
echo ""
echo -e "${CYAN}  Useful commands:${NC}"
echo -e "  Manual backup now:   ${BOLD}sudo systemctl start borg-backup.service${NC}"
echo -e "  Watch backup log:    ${BOLD}sudo journalctl -fu borg-backup${NC}"
echo -e "  List archives:       ${BOLD}BORG_PASSPHRASE=\$(cat /root/.borg-passphrase) borg list $REMOTE_REPO${NC}"
echo -e "  Run restore script:  ${BOLD}sudo borg-restore.sh${NC}"
