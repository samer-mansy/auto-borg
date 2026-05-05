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
