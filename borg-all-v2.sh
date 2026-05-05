#!/usr/bin/env bash
# ============================================================
# Borg Monitoring Dashboard — FINAL STABLE VERSION
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

STALE_HOURS=24

source /etc/borg-server.conf
[[ -f /etc/borg-passphrases.conf ]] && source /etc/borg-passphrases.conf

export BORG_DISPLAY_UNITS=iec

clear

# ---------------- HEADER ----------------
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║            Borg Backup Monitoring Dashboard                 ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

printf "%-15s %s\n" "Server:" "$(hostname)"
printf "%-15s %s\n" "Backup Root:" "$BACKUP_ROOT"
printf "%-15s %s\n" "Time:" "$(date '+%F %T')"
echo ""

# ---------------- DISCOVER REPOS ----------------
CLIENTS=()
declare -A REPO_PATHS

while IFS= read -r -d '' dir; do
  [[ -f "$dir/config" && -d "$dir/data" ]] || continue
  CLIENT=$(basename "$dir")

  CLIENTS+=("$CLIENT")
  REPO_PATHS["$CLIENT"]="$dir"
done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 2 -type d -print0)

IFS=$'\n' CLIENTS=($(sort <<<"${CLIENTS[*]}"))
unset IFS

NOW_TS=$(date +%s)

TOTAL=0; OK=0; WARN=0; FAIL=0

# ---------------- PROCESS ----------------
for CLIENT in "${CLIENTS[@]}"; do
  REPO="${REPO_PATHS[$CLIENT]}"

  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf "Client: %-18s Repo: %s\n" "$CLIENT" "$REPO"

  CLIENT_VAR="${CLIENT//-/_}_PASSPHRASE"
  [[ -n "${!CLIENT_VAR:-}" ]] && export BORG_PASSPHRASE="${!CLIENT_VAR}"

  # ---------------- ACCESS CHECK ----------------
  if ! borg list "$REPO" &>/dev/null; then
    echo -e "  ${RED}🔴 Status: Failed (cannot access repo)${NC}"
    ((FAIL++, TOTAL++))
    echo ""
    continue
  fi

  # ---------------- JSON SOURCE (NO SIZE BUG) ----------------
  JSON=$(borg list --json "$REPO" 2>/dev/null)

  COUNT=$(echo "$JSON" | jq '.archives | length')

  if [[ "$COUNT" -eq 0 ]]; then
    echo -e "  ${YELLOW}🟡 Status: No backups${NC}"
    ((WARN++, TOTAL++))
    echo ""
    continue
  fi

  # latest backup
  LATEST_TIME=$(echo "$JSON" | jq -r '.archives[-1].start')
  LATEST_TS=$(date -d "$LATEST_TIME" +%s 2>/dev/null || echo 0)

  AGE_HOURS=$(( (NOW_TS - LATEST_TS) / 3600 ))

  printf "  %-18s %d\n" "Total Archives:" "$COUNT"
  printf "  %-18s %dh\n" "Last Backup Age:" "$AGE_HOURS"

  if (( AGE_HOURS <= STALE_HOURS )); then
    echo -e "  ${GREEN}🟢 Status: Healthy${NC}"
    ((OK++))
  else
    echo -e "  ${YELLOW}🟡 Status: Stale (>24h)${NC}"
    ((WARN++))
  fi

  echo ""

  # ---------------- TABLE ----------------
  printf "  %-45s %-20s %-10s\n" "Archive Name" "Date" "Size"
  printf "  %-45s %-20s %-10s\n" "---------------------------------------------" "--------------------" "----------"

  echo "$JSON" | jq -c '.archives[]' | while read -r a; do

    NAME=$(echo "$a" | jq -r '.name')
    TIME=$(echo "$a" | jq -r '.start')

    # SAFE SIZE (from stats if available)
    SIZE=$(echo "$a" | jq -r '.stats.deduplicated_size // 0')

    if [[ "$SIZE" -gt 0 ]]; then
      SIZE_FMT=$(numfmt --to=iec "$SIZE")
    else
      SIZE_FMT="N/A"
    fi

    DATE_FMT=$(date -d "$TIME" '+%Y-%m-%d %H:%M')

    printf "  %-45s %-20s %-10s\n" "$NAME" "$DATE_FMT" "$SIZE_FMT"

  done

  echo ""

  ((TOTAL++))
done

# ---------------- SUMMARY ----------------
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "Summary"
echo "  Total:   $TOTAL"
echo -e "  🟢 OK:   $OK"
echo -e "  🟡 Warn: $WARN"
echo -e "  🔴 Fail: $FAIL"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"