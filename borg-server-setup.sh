#!/usr/bin/env bash
# ============================================================
#  borg-server-setup.sh — BorgBackup Central Server Setup
#  Run on: Dell T320 (or any dedicated backup server)
#  Run as: sudo bash borg-server-setup.sh
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

LOG="/var/log/borg-server-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

clear
echo -e "${BOLD}${BLUE}"
cat << 'EOF'
  ██████╗  ██████╗ ██████╗  ██████╗     ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗
  ██╔══██╗██╔═══██╗██╔══██╗██╔════╝     ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
  ██████╔╝██║   ██║██████╔╝██║  ███╗    ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝
  ██╔══██╗██║   ██║██╔══██╗██║   ██║    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗
  ██████╔╝╚██████╔╝██║  ██║╚██████╔╝    ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║
  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝     ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝
EOF
echo -e "${NC}"
echo -e "${CYAN}  BorgBackup Central Backup Server — Dell T320 Setup${NC}\n"

# ── Configuration ─────────────────────────────────────────────
section "CONFIGURATION"

ask "Backup storage path (default: /backup):"
read -r BACKUP_ROOT; BACKUP_ROOT="${BACKUP_ROOT:-/backup}"

ask "Dedicated backup user name (default: borg):"
read -r BORG_USER; BORG_USER="${BORG_USER:-borg}"

ask "SSH port clients will connect on (default: 22):"
read -r BORG_SSH_PORT; BORG_SSH_PORT="${BORG_SSH_PORT:-22}"

ask "Disk/partition to mount as backup storage (e.g. /dev/sdb). Leave blank to use existing filesystem:"
read -r BACKUP_DISK

ask "Filesystem type if formatting disk (ext4/xfs) [default: xfs]:"
read -r FS_TYPE; FS_TYPE="${FS_TYPE:-xfs}"

ask "Alert email for failed backup notifications (leave blank to skip):"
read -r ALERT_EMAIL

ask "Max disk usage % before warning alert (default: 85):"
read -r DISK_WARN_PCT; DISK_WARN_PCT="${DISK_WARN_PCT:-85}"

echo ""
info "Configuration summary:"
echo -e "  Backup root:   ${BOLD}$BACKUP_ROOT${NC}"
echo -e "  Borg user:     ${BOLD}$BORG_USER${NC}"
echo -e "  SSH port:      ${BOLD}$BORG_SSH_PORT${NC}"
echo -e "  Disk:          ${BOLD}${BACKUP_DISK:-existing filesystem}${NC}"
echo -e "  Alert email:   ${BOLD}${ALERT_EMAIL:-none}${NC}"
echo ""
ask "Proceed? (yes/no):"
read -r CONFIRM; [[ "$CONFIRM" != "yes" ]] && exit 0


# ── 1. System update & borgbackup install ─────────────────────
section "1 — INSTALL BORGBACKUP"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  borgbackup openssh-server curl wget mailutils \
  smartmontools hdparm lsof ncdu
success "BorgBackup $(borg --version) installed."


# ── 2. Disk & filesystem setup ────────────────────────────────
section "2 — STORAGE SETUP"
if [[ -n "$BACKUP_DISK" ]]; then
  warn "About to format ${BACKUP_DISK} as ${FS_TYPE}. ALL DATA WILL BE LOST."
  ask "Type 'yes-format' to confirm:"
  read -r FORMAT_CONFIRM
  if [[ "$FORMAT_CONFIRM" == "yes-format" ]]; then
    info "Formatting ${BACKUP_DISK}..."
    mkfs."$FS_TYPE" -f "$BACKUP_DISK"
    mkdir -p "$BACKUP_ROOT"
    DISK_UUID=$(blkid -s UUID -o value "$BACKUP_DISK")
    echo "UUID=${DISK_UUID} ${BACKUP_ROOT} ${FS_TYPE} defaults,noatime,nodiratime 0 2" >> /etc/fstab
    mount "$BACKUP_ROOT"
    success "Disk formatted and mounted at $BACKUP_ROOT (UUID: $DISK_UUID)."
  else
    warn "Skipping disk format."
    mkdir -p "$BACKUP_ROOT"
  fi
else
  mkdir -p "$BACKUP_ROOT"
  success "Using existing filesystem at $BACKUP_ROOT."
fi


# ── 3. Borg dedicated user ────────────────────────────────────
section "3 — BORG USER"
if id "$BORG_USER" &>/dev/null; then
  warn "User '$BORG_USER' already exists."
else
  useradd -m -s /bin/bash -d "/home/$BORG_USER" "$BORG_USER"
  passwd -l "$BORG_USER"
  success "User '$BORG_USER' created (no password — SSH key only)."
fi

# SSH directory
SSH_DIR="/home/$BORG_USER/.ssh"
mkdir -p "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$BORG_USER:$BORG_USER" "$SSH_DIR"

# Borg owns the backup root
chown -R "$BORG_USER:$BORG_USER" "$BACKUP_ROOT"
chmod 750 "$BACKUP_ROOT"
success "Borg user configured."


# ── 4. SSH hardening for borg user ───────────────────────────
section "4 — SSH HARDENING FOR BORG"

# Create a wrapper script to enforce borg-only access
cat > /usr/local/bin/borg-serve-wrapper << WRAPPER
#!/bin/bash
# Force borg serve only — clients cannot run arbitrary commands
exec borg serve --restrict-to-path "$BACKUP_ROOT" --append-only "\$@"
WRAPPER
chmod +x /usr/local/bin/borg-serve-wrapper

info "SSH authorized_keys for borg will use forced commands."
info "Each client key is added via register-client.sh (generated below)."

# Add a Match block to sshd_config for borg user
# NOTE: We do NOT use ForceCommand here — each client key has its own
# 'command=' option in authorized_keys which restricts to that client's
# specific repo path. ForceCommand would override this per-client restriction.
if ! grep -q "Match User $BORG_USER" /etc/ssh/sshd_config; then
cat >> /etc/ssh/sshd_config << EOF

# ── BorgBackup restricted user ──
Match User $BORG_USER
    PasswordAuthentication no
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    AuthorizedKeysFile /home/%u/.ssh/authorized_keys
EOF
  systemctl restart ssh
  success "SSH borg-user restrictions applied (per-client command= in authorized_keys)."
fi


# ── 5. Directory structure ────────────────────────────────────
section "5 — DIRECTORY STRUCTURE"
mkdir -p "$BACKUP_ROOT"
mkdir -p /var/log/borg
chown "$BORG_USER:$BORG_USER" /var/log/borg
success "Directory structure created."

# Write the BACKUP_ROOT to a config file so other scripts can read it
cat > /etc/borg-server.conf << EOF
# BorgBackup server configuration — generated $(date)
BORG_USER=$BORG_USER
BACKUP_ROOT=$BACKUP_ROOT
BORG_SSH_PORT=$BORG_SSH_PORT
ALERT_EMAIL=${ALERT_EMAIL:-}
DISK_WARN_PCT=$DISK_WARN_PCT
EOF
chmod 644 /etc/borg-server.conf
success "Server config saved to /etc/borg-server.conf."


# ── 6. Client registration script ────────────────────────────
section "6 — CLIENT REGISTRATION SCRIPT"
cat > /usr/local/bin/register-client.sh << 'REGSCRIPT'
#!/usr/bin/env bash
# ============================================================
#  register-client.sh — Register a new client on the backup server
#  Usage: sudo bash register-client.sh <client-hostname> <ssh-public-key>
#  Or interactively: sudo bash register-client.sh
# ============================================================
set -euo pipefail

source /etc/borg-server.conf 2>/dev/null || { echo "Missing /etc/borg-server.conf"; exit 1; }

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
ask()     { echo -e "${YELLOW}[?]${NC} $*"; }

CLIENT_HOST="${1:-}"
CLIENT_KEY="${2:-}"

if [[ -z "$CLIENT_HOST" ]]; then
  ask "Client hostname (must match the machine's hostname, e.g. web-server-01):"
  read -r CLIENT_HOST
fi
[[ -z "$CLIENT_HOST" ]] && { echo "Client hostname required."; exit 1; }

if [[ -z "$CLIENT_KEY" ]]; then
  ask "Paste the client's SSH public key (from /root/.ssh/borg_client.pub on the client):"
  read -r CLIENT_KEY
fi
[[ -z "$CLIENT_KEY" ]] && { echo "SSH public key required."; exit 1; }

# Create per-client repo directory
REPO_PATH="$BACKUP_ROOT/$CLIENT_HOST"
mkdir -p "$REPO_PATH"
chown "$BORG_USER:$BORG_USER" "$REPO_PATH"
chmod 700 "$REPO_PATH"
info "Repo directory created: $REPO_PATH"

# Add key with forced command scoped to this client's repo only
KEY_ENTRY="command=\"borg serve --restrict-to-path $REPO_PATH --append-only\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $CLIENT_KEY"

AUTH_KEYS="/home/$BORG_USER/.ssh/authorized_keys"

if grep -qF "$CLIENT_KEY" "$AUTH_KEYS" 2>/dev/null; then
  echo "Key already registered for $CLIENT_HOST."
else
  echo "$KEY_ENTRY" >> "$AUTH_KEYS"
  # Fix permissions — SSH strict mode rejects keys if these are wrong
  chown "$BORG_USER:$BORG_USER" "/home/$BORG_USER"
  chmod 755 "/home/$BORG_USER"
  chown "$BORG_USER:$BORG_USER" "/home/$BORG_USER/.ssh"
  chmod 700 "/home/$BORG_USER/.ssh"
  chown "$BORG_USER:$BORG_USER" "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
  success "SSH key registered for client: $CLIENT_HOST"
fi

echo ""
success "Client '$CLIENT_HOST' is registered."
echo -e "  Repo path:  ${BOLD:-}$REPO_PATH${NC:-}"
echo -e "  Next step:  Run borg-client-setup.sh on $CLIENT_HOST"
REGSCRIPT
chmod +x /usr/local/bin/register-client.sh
success "register-client.sh installed at /usr/local/bin/register-client.sh."


# ── 7. Unregister client script ───────────────────────────────
cat > /usr/local/bin/unregister-client.sh << 'UNREG'
#!/usr/bin/env bash
# Usage: sudo bash unregister-client.sh <client-hostname>
set -euo pipefail
source /etc/borg-server.conf
CLIENT_HOST="${1:-}"; [[ -z "$CLIENT_HOST" ]] && { echo "Usage: $0 <hostname>"; exit 1; }
AUTH_KEYS="/home/$BORG_USER/.ssh/authorized_keys"
REPO_PATH="$BACKUP_ROOT/$CLIENT_HOST"

echo "Removing SSH key for $CLIENT_HOST from authorized_keys..."
grep -v "restrict-to-path $REPO_PATH" "$AUTH_KEYS" > /tmp/ak.tmp && mv /tmp/ak.tmp "$AUTH_KEYS"
chown "$BORG_USER:$BORG_USER" "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
echo "Done. Repo data at $REPO_PATH is preserved (remove manually if desired)."
UNREG
chmod +x /usr/local/bin/unregister-client.sh


# ── 8. Monitor script ─────────────────────────────────────────
section "7 — MONITORING SCRIPT"
cat > /usr/local/bin/borg-monitor.sh << MONITOR
#!/usr/bin/env bash
# ============================================================
#  borg-monitor.sh — Check all client repos health
#  Runs daily via cron. Sends alert on stale/failed repos.
# ============================================================
set -euo pipefail
source /etc/borg-server.conf

LOG="/var/log/borg/monitor-\$(date +%Y%m%d).log"
STALE_HOURS=26          # Alert if no backup in this many hours
ISSUES=0
REPORT=""
TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')

check_repo() {
  local HOST=\$1
  local REPO=\$2

  if [[ ! -d "\$REPO" ]]; then
    REPORT+="\n  ❌ \$HOST — repo directory missing: \$REPO"
    ((ISSUES++)); return
  fi

  # Get latest archive timestamp
  LATEST=\$(sudo -u "\$BORG_USER" borg list "\$REPO" --last 1 --format "{time}" 2>/dev/null | tail -1 || echo "")
  if [[ -z "\$LATEST" ]]; then
    REPORT+="\n  ❌ \$HOST — no archives found in \$REPO"
    ((ISSUES++)); return
  fi

  LATEST_EPOCH=\$(date -d "\$LATEST" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "\$LATEST" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=\$(date +%s)
  AGE_HOURS=\$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))

  if (( AGE_HOURS > STALE_HOURS )); then
    REPORT+="\n  ⚠️  \$HOST — last backup \${AGE_HOURS}h ago (threshold: \${STALE_HOURS}h)"
    ((ISSUES++))
  else
    REPORT+="\n  ✅ \$HOST — OK (last backup \${AGE_HOURS}h ago: \$LATEST)"
  fi

  # Repo size
  REPO_SIZE=\$(du -sh "\$REPO" 2>/dev/null | cut -f1 || echo "?")
  REPORT+=", size: \$REPO_SIZE"
}

# Disk usage check
DISK_PCT=\$(df "\$BACKUP_ROOT" | tail -1 | awk '{print \$5}' | tr -d '%')
DISK_USED=\$(df -h "\$BACKUP_ROOT" | tail -1 | awk '{print \$3}')
DISK_TOTAL=\$(df -h "\$BACKUP_ROOT" | tail -1 | awk '{print \$2}')
if (( DISK_PCT >= DISK_WARN_PCT )); then
  REPORT+="\n  ❗ DISK WARNING: \${DISK_PCT}% used (\${DISK_USED}/\${DISK_TOTAL}) on \$BACKUP_ROOT"
  ((ISSUES++))
fi

# Check each client repo
for REPO_DIR in "\$BACKUP_ROOT"/*/; do
  [[ -d "\$REPO_DIR" ]] || continue
  HOST=\$(basename "\$REPO_DIR")
  check_repo "\$HOST" "\$REPO_DIR"
done

# Output
HEADER="BorgBackup Monitor Report — \$TIMESTAMP"
HEADER+="\nBackup root: \$BACKUP_ROOT (\${DISK_PCT}% full — \${DISK_USED}/\${DISK_TOTAL})"
HEADER+="\nIssues found: \$ISSUES"
FULL_REPORT="\$HEADER\n\$REPORT"

echo -e "\$FULL_REPORT" | tee "\$LOG"

if (( ISSUES > 0 )) && [[ -n "\${ALERT_EMAIL:-}" ]]; then
  echo -e "\$FULL_REPORT" | mail -s "[BACKUP ALERT] \$ISSUES issue(s) on \$(hostname)" "\$ALERT_EMAIL"
fi

exit \$ISSUES
MONITOR
chmod +x /usr/local/bin/borg-monitor.sh

# Daily cron
cat > /etc/cron.d/borg-monitor << 'CRON'
# Run borg backup monitor daily at 07:00
0 7 * * * root /usr/local/bin/borg-monitor.sh >> /var/log/borg/monitor.log 2>&1
CRON
success "Monitor script installed. Daily cron at 07:00."

# Server-side compact cron (clients using --append-only cannot compact themselves)
cat > /usr/local/bin/borg-compact-all.sh << 'COMPACTSCRIPT'
#!/usr/bin/env bash
# borg-compact-all.sh — Compact all repos server-side to reclaim pruned space
source /etc/borg-server.conf 2>/dev/null || { echo "Missing /etc/borg-server.conf"; exit 1; }
echo "=== Borg compact-all: $(date) ==="
for REPO in "$BACKUP_ROOT"/*/; do
  [[ -d "$REPO" ]] || continue
  HOST=$(basename "$REPO")
  echo "  Compacting $HOST..."
  borg compact "$REPO" && echo "  [$HOST] OK" || echo "  [$HOST] WARN"
done
echo "=== Done: $(date) ==="
COMPACTSCRIPT
chmod +x /usr/local/bin/borg-compact-all.sh

cat > /etc/cron.d/borg-compact << EOF
# Compact all repos weekly Sunday 03:00 (server side — bypasses --append-only)
0 3 * * 0 $BORG_USER /usr/local/bin/borg-compact-all.sh >> /var/log/borg/compact.log 2>&1
EOF
success "Server-side compact cron installed (weekly, Sunday 03:00)."


# ── 9. Logrotate for borg logs ────────────────────────────────
cat > /etc/logrotate.d/borg << 'LOGROTATE'
/var/log/borg/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGROTATE
success "Log rotation configured for /var/log/borg."


# ── 10. S.M.A.R.T. disk health check cron ────────────────────
if [[ -n "$BACKUP_DISK" ]]; then
cat > /etc/cron.d/disk-smart << EOF
# Weekly SMART disk health check on backup disk
0 6 * * 0 root smartctl -a $BACKUP_DISK >> /var/log/borg/smart.log 2>&1
EOF
  success "SMART disk health check scheduled weekly."
fi


# ── Summary ───────────────────────────────────────────────────
section "✅  SERVER SETUP COMPLETE"
echo -e "  ${BOLD}Borg user:${NC}       $BORG_USER"
echo -e "  ${BOLD}Backup root:${NC}     $BACKUP_ROOT"
echo -e "  ${BOLD}SSH port:${NC}        $BORG_SSH_PORT"
echo -e "  ${BOLD}Config file:${NC}     /etc/borg-server.conf"
echo -e "  ${BOLD}Log:${NC}             $LOG"
echo ""
echo -e "${CYAN}  Next steps:${NC}"
echo -e "  1. On each client machine: run  ${BOLD}borg-client-setup.sh${NC}"
echo -e "  2. Copy the client's public key back here and run:"
echo -e "     ${BOLD}sudo register-client.sh <hostname> <pubkey>${NC}"
echo -e "  3. Complete borg init on the client (guided by borg-client-setup.sh)"
echo ""
echo -e "${YELLOW}  Server IP / hostname clients should connect to:${NC}"
hostname -I | tr ' ' '\n' | grep -v '^$' | head -5 | while read -r IP; do
  echo -e "    ${BOLD}$IP${NC}"
done
echo -e "  SSH port: ${BOLD}$BORG_SSH_PORT${NC}"
