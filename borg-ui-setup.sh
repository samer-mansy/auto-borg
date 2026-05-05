#!/usr/bin/env bash
# ============================================================
#  borg-ui-setup.sh — Install borg-ui web interface
#  Run on: Backup server (Debian/Alpine LXC/VM)
#  Run as: sudo bash borg-ui-setup.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
ask()     { echo -e "${YELLOW}[?]${NC} $*"; }

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

clear
echo -e "${BOLD}${BLUE}  borg-ui — Web Interface${NC}\n"

source /etc/borg-server.conf 2>/dev/null || BACKUP_ROOT="/backup"

ask "Web UI port (default: 8080):"
read -r PORT; PORT="${PORT:-8080}"

info "Installing dependencies..."
if [[ -f /etc/debian_version ]]; then
  apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-venv git nginx
else
  apk add --no-cache python3 py3-pip git nginx
fi

info "Cloning borg-ui..."
cd /opt
[[ -d borg-ui ]] && rm -rf borg-ui
git clone https://github.com/karanhudia/borg-ui.git
cd borg-ui

info "Setting up Python environment..."
python3 -m venv venv
source venv/bin/activate
pip install flask flask-login werkzeug

cat > config.py << EOF
BORG_REPO_PATH = "$BACKUP_ROOT"
SECRET_KEY = "$(openssl rand -hex 32)"
HOST = "0.0.0.0"
PORT = $PORT
DEBUG = False
EOF

cat > /etc/systemd/system/borg-ui.service << EOF
[Unit]
Description=BorgBackup Web UI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/borg-ui
Environment="PATH=/opt/borg-ui/venv/bin"
ExecStart=/opt/borg-ui/venv/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now borg-ui
success "borg-ui running on http://$(hostname -I | awk '{print $1}'):$PORT"
