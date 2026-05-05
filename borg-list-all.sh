#!/usr/bin/env bash
# ============================================================
#  borg-list-all.sh — List all client backups from server
#  Run on: Backup server
#  Usage: BORG_PASSPHRASE='shared-pass' bash borg-list-all.sh
#         OR: bash borg-list-all.sh (will try each client's passphrase file)
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Load server config
if [[ -f /etc/borg-server.conf ]]; then
  source /etc/borg-server.conf
else
  echo "ERROR: /etc/borg-server.conf not found"
  exit 1
fi

# Passphrase handling
# Option 1: Set BORG_PASSPHRASE env var before running (if all repos use same passphrase)
# Option 2: Store passphrases in /etc/borg-passphrases.conf like:
#   CLIENT1_PASSPHRASE="pass1"
#   CLIENT2_PASSPHRASE="pass2"
if [[ -f /etc/borg-passphrases.conf ]]; then
  source /etc/borg-passphrases.conf
fi

# Parse command line options
SHOW_ARCHIVES=false
SHOW_STATS=false
CLIENT_FILTER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--archives) SHOW_ARCHIVES=true; shift ;;
    -s|--stats) SHOW_STATS=true; shift ;;
    -c|--client) CLIENT_FILTER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -a, --archives     Show all archives for each client"
      echo "  -s, --stats        Show detailed statistics"
      echo "  -c, --client NAME  Filter to specific client"
      echo "  -h, --help         Show this help"
      echo ""
      echo "Passphrase options:"
      echo "  1. Single passphrase for all repos:"
      echo "     BORG_PASSPHRASE='your-pass' $0"
      echo ""
      echo "  2. Per-client passphrases in /etc/borg-passphrases.conf:"
      echo "     reee_PASSPHRASE='pass1'"
      echo "     Sam_C_PASSPHRASE='pass2'"
      echo ""
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

clear
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║          BorgBackup Server — Client Overview                  ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}  Server:      $(hostname)${NC}"
echo -e "${CYAN}  Backup root: ${BACKUP_ROOT}${NC}"
echo -e "${CYAN}  Date:        $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""

# Find all client directories
CLIENTS=()
for REPO_DIR in "$BACKUP_ROOT"/*/; do
  [[ -d "$REPO_DIR" ]] || continue
  CLIENT=$(basename "$REPO_DIR")
  
  # Filter if specified
  if [[ -n "$CLIENT_FILTER" && "$CLIENT" != "$CLIENT_FILTER" ]]; then
    continue
  fi
  
  CLIENTS+=("$CLIENT")
done

if [[ ${#CLIENTS[@]} -eq 0 ]]; then
  echo -e "${YELLOW}No client repositories found in $BACKUP_ROOT${NC}"
  exit 0
fi

# Sort clients alphabetically
IFS=$'\n' CLIENTS=($(sort <<<"${CLIENTS[*]}"))
unset IFS

TOTAL_CLIENTS=0
TOTAL_ARCHIVES=0

# Process each client
for CLIENT in "${CLIENTS[@]}"; do
  REPO_PATH="$BACKUP_ROOT/$CLIENT"
  
  echo -e "${BOLD}${GREEN}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${GREEN}│ Client: ${CLIENT}${NC}"
  echo -e "${BOLD}${GREEN}└─────────────────────────────────────────────────────────────┘${NC}"
  echo -e "  ${CYAN}Repo:${NC} $REPO_PATH"
  
  # Try to get passphrase for this client
  CLIENT_VAR_NAME="${CLIENT//-/_}_PASSPHRASE"  # Convert client-name to client_name_PASSPHRASE
  if [[ -n "${!CLIENT_VAR_NAME:-}" ]]; then
    export BORG_PASSPHRASE="${!CLIENT_VAR_NAME}"
  elif [[ -z "${BORG_PASSPHRASE:-}" ]]; then
    echo -e "  ${YELLOW}⚠ No passphrase set for $CLIENT (set ${CLIENT_VAR_NAME} or BORG_PASSPHRASE)${NC}"
    echo ""
    ((TOTAL_CLIENTS++))
    continue
  fi
  
  # Check if repo is accessible
  if ! borg list --short "$REPO_PATH" &>/dev/null; then
    echo -e "  ${RED}✗ Cannot access repo (wrong passphrase or corrupted)${NC}"
    echo ""
    ((TOTAL_CLIENTS++))
    unset BORG_PASSPHRASE 2>/dev/null || true
    continue
  fi
  
  # Count archives
  ARCHIVE_COUNT=$(borg list --short "$REPO_PATH" 2>/dev/null | wc -l)
  TOTAL_ARCHIVES=$((TOTAL_ARCHIVES + ARCHIVE_COUNT))
  
  if [[ $ARCHIVE_COUNT -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ No archives (repo is empty)${NC}"
    echo ""
    ((TOTAL_CLIENTS++))
    continue
  fi
  
  # Get latest archive info
  LATEST_ARCHIVE=$(borg list --short "$REPO_PATH" 2>/dev/null | tail -1)
  
  echo -e "  ${CYAN}Archives:${NC}    $ARCHIVE_COUNT"
  echo -e "  ${CYAN}Latest:${NC}      $LATEST_ARCHIVE"
  
  # Get repo stats (quick summary)
  REPO_INFO=$(borg info "$REPO_PATH" 2>/dev/null || echo "")
  if [[ -n "$REPO_INFO" ]]; then
    REPO_SIZE=$(echo "$REPO_INFO" | grep "All archives:" | awk '{print $3, $4}' | head -1)
    NUM_ARCHIVES=$(echo "$REPO_INFO" | grep "Number of archives:" | awk '{print $NF}')
    echo -e "  ${CYAN}Repo size:${NC}   $REPO_SIZE"
  fi
  
  # Show detailed stats if requested
  if [[ "$SHOW_STATS" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Detailed Statistics:${NC}"
    borg info "$REPO_PATH" 2>/dev/null | grep -E "^(Original size|Compressed size|Deduplicated size|Unique chunks|Total chunks)" | sed 's/^/    /'
  fi
  
  # List all archives if requested
  if [[ "$SHOW_ARCHIVES" == true ]]; then
    echo ""
    echo -e "  ${BOLD}All Archives:${NC}"
    borg list "$REPO_PATH" 2>/dev/null | while read -r line; do
      echo "    $line"
    done
  fi
  
  echo ""
  ((TOTAL_CLIENTS++))
  unset BORG_PASSPHRASE 2>/dev/null || true
done

# Summary
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Summary:${NC}"
echo -e "  Total clients:  ${BOLD}$TOTAL_CLIENTS${NC}"
echo -e "  Total archives: ${BOLD}$TOTAL_ARCHIVES${NC}"
echo ""

# Show disk usage
if command -v df &>/dev/null; then
  DISK_USAGE=$(df -h "$BACKUP_ROOT" 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 ")"}')
  echo -e "  Disk usage:     ${BOLD}$DISK_USAGE${NC}"
fi

echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
