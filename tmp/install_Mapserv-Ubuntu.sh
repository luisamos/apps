#!/usr/bin/env bash
set -euo pipefail

APPS_ROOT="/apps"
MAPSERV_DIR="$APPS_ROOT/mapserv"
LOGS_DIR="$APPS_ROOT/logs"
CGI_DIR="/usr/lib/cgi-bin"
SERVICE_NAME="apache2"
VHOST_FILE="/etc/apache2/sites-available/mapserver.conf"
LOG_FILE="$LOGS_DIR/install_ubuntu_log.txt"

log() {
  local level="${2:-INFO}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $1" | tee -a "$LOG_FILE"
}

read_input() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  echo "${value:-$default}"
}

mkdir -p "$LOGS_DIR"
log "Inicio de instalación Ubuntu"

IP="$(read_input 'IP del servidor' '127.0.0.2')"
PORT="$(read_input 'Puerto del servidor' '8081')"

if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  log "IP inválida: $IP" "ERROR"
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  log "Puerto inválido: $PORT" "ERROR"
  exit 1
fi

log "Configuración confirmada: $IP:$PORT"

log "Instalando dependencias"
sudo apt update
sudo apt install -y apache2 cgi-mapserver mapserver-bin libapache2-mod-mapcache python3-mapscript

log "Habilitando módulos Apache"
sudo a2enmod cgi headers alias env >/dev/null

log "Verificando rutas del repositorio"
for d in "$MAPSERV_DIR" "$APPS_ROOT/mapcache" "$LOGS_DIR"; do
  [[ -d "$d" ]] || { log "No existe directorio requerido: $d" "ERROR"; exit 1; }
done

log "Asignando permisos"
sudo chown -R www-data:www-data "$MAPSERV_DIR" "$APPS_ROOT/mapcache" "$LOGS_DIR"
sudo chmod -R 755 "$MAPSERV_DIR" "$APPS_ROOT/mapcache"
sudo chmod -R 775 "$LOGS_DIR"

log "Ajustando IP/puerto en archivos .map"
sudo sed -i -E "s|http://[0-9.]+:[0-9]+/servicio/|http://${IP}:${PORT}/servicio/|g" "$MAPSERV_DIR/wms_kaypacha.map"
sudo sed -i -E "s|http://[0-9.]+:[0-9]+/servicio/|http://${IP}:${PORT}/servicio/|g" "$MAPSERV_DIR/wfs_kaypacha.map"

log "Verificando mapserv CGI"
if [[ ! -f "$CGI_DIR/mapserv" ]]; then
  if [[ -f "/usr/bin/mapserv" ]]; then
    sudo ln -sf /usr/bin/mapserv "$CGI_DIR/mapserv"
  else
    log "No se encontró mapserv en $CGI_DIR/mapserv ni /usr/bin/mapserv" "ERROR"
    exit 1
  fi
fi
sudo chmod +x "$CGI_DIR/mapserv"

log "Copiando mapserv como wms y wfs (sin extensión)"
sudo cp -f "$CGI_DIR/mapserv" "$CGI_DIR/wms"
sudo cp -f "$CGI_DIR/mapserv" "$CGI_DIR/wfs"
sudo chmod +x "$CGI_DIR/wms" "$CGI_DIR/wfs"

log "Generando VirtualHost"
sudo tee "$VHOST_FILE" >/dev/null <<VHOST
Listen $PORT

<VirtualHost ${IP}:${PORT}>
    ServerAdmin luisamos7@gmail.com
    ServerName $IP
    ServerAlias $IP
    ErrorLog /apps/logs/error_kaypacha.log
    CustomLog /apps/logs/custom_kaypacha.log combined

    ScriptAlias /servicio/ /usr/lib/cgi-bin/

    <Directory /usr/lib/cgi-bin>
        AllowOverride None
        Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
        Require all granted
        <IfModule mod_headers.c>
            Header set Access-Control-Allow-Origin "*"
        </IfModule>
    </Directory>

    <IfModule mod_headers.c>
        Header set Access-Control-Allow-Origin "*"
        Header set Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE"
        Header set Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization"
    </IfModule>

    SetEnvIf Request_URI "/servicio/wms" MS_MAPFILE=/apps/mapserv/wms_kaypacha.map
    SetEnvIf Request_URI "/servicio/wfs" MS_MAPFILE=/apps/mapserv/wfs_kaypacha.map
</VirtualHost>
VHOST

log "Habilitando sitio y recargando Apache"
sudo a2ensite mapserver.conf >/dev/null
sudo a2dissite 000-default.conf >/dev/null || true
sudo apache2ctl configtest
sudo systemctl restart "$SERVICE_NAME"

log "Instalación finalizada"
echo "WMS: http://${IP}:${PORT}/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities"
echo "WFS: http://${IP}:${PORT}/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities"