#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="apache2"
VHOST_FILE="/etc/apache2/sites-available/mapserver.conf"
CGI_DIR="/usr/lib/cgi-bin"
LOG_FILE="/apps/logs/uninstall_ubuntu_log.txt"

mkdir -p /apps/logs

log() {
  local level="${2:-INFO}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $1" | tee -a "$LOG_FILE"
}

ask_yes_no() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  [[ "$value" =~ ^[sSyY]$ ]]
}

log "Inicio de desinstalación Ubuntu"

if ask_yes_no "Eliminar CGI wms y wfs (sin extensión)? (S/N)" "S"; then
  sudo rm -f "$CGI_DIR/wms" "$CGI_DIR/wfs"
  log "CGI wms y wfs eliminados"
else
  log "Se conservan CGI wms y wfs" "WARN"
fi

if [[ -f "$VHOST_FILE" ]]; then
  log "Deshabilitando sitio mapserver.conf"
  sudo a2dissite mapserver.conf >/dev/null || true
  sudo rm -f "$VHOST_FILE"
else
  log "No existe $VHOST_FILE, se omite" "WARN"
fi

sudo apache2ctl configtest
sudo systemctl restart "$SERVICE_NAME"

log "Desinstalación finalizada"