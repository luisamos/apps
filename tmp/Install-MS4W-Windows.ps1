#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instalador automatizado de MS4W con MapServer / MapCache
.DESCRIPTION
    PREREQUISITO: clonar el repositorio en <UNIDAD>:\apps
        git clone https://github.com/luisamos/apps.git D:\apps

    Luego este script hace todo lo demas:
    - Solicita la IP y el puerto donde correra MS4W (con valores por defecto)
    - Descarga ms4w_5.0.0.zip desde ms4w.com si no existe en <UNIDAD>:\apps\docs\
    - Descomprime <UNIDAD>:\apps\docs\ms4w_5.0.0.zip en <UNIDAD>:\ms4w
    - Verifica que <UNIDAD>:\apps\mapserv, mapcache y logs existan (vienen del repo)
    - Actualiza la IP y el puerto dentro de wms_kaypacha.map y wfs_kaypacha.map
    - Duplica mapserv.exe en cgi-bin\wms y cgi-bin\wfs
    - Agrega Listen <puerto> al httpd.conf y habilita mod_headers
    - Genera httpd-vhosts.conf con la IP y puerto indicados
    - Agrega la IP al adaptador loopback si es 127.x.x.x
    - Registra Apache como servicio de Windows y lo arranca
.NOTES
    Ejecutar como Administrador:
    Set-ExecutionPolicy Bypass -Scope Process -Force
    D:\apps\tmp\Install-MS4W-Windows.ps1
#>

# --- RUTAS Y URLS -------------------------------------------------------
$INSTALL_DRIVE = $null
$MS4W_ROOT    = $null
$APPS_ROOT    = $null
$APACHE_BIN   = $null
$APACHE_CONF  = $null
$APACHE_EXTRA = $null
$MS4W_ZIP     = $null
$MS4W_URL     = "https://ms4w.com/release/ms4w_5.0.0.zip"
$MS4W_MIN_BYTES = 50MB
$SERVICE_NAME = "Apache MS4W Web Server"
$LOG_FILE     = $null

# --- FUNCIONES AUXILIARES -----------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "ERROR" { "Red" } "WARN" { "Yellow" } default { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
    $effectiveLogFile = $LOG_FILE
    if ([string]::IsNullOrWhiteSpace($effectiveLogFile)) {
        $effectiveLogFile = Join-Path ([System.IO.Path]::GetTempPath()) "install_ms4w_bootstrap.log"
    }
    $logDir = Split-Path $effectiveLogFile
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $effectiveLogFile -Value $line
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ""
    Write-Log "-- $Name --"
    try { & $Action; Write-Log "$Name completado OK" }
    catch { Write-Log "Error en '$Name': $_" "ERROR"; throw }
}

function Read-ValidatedInput {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validator, [string]$ErrorMsg)
    while ($true) {
        Write-Host "  $Prompt " -ForegroundColor White -NoNewline
        Write-Host "[$Default]" -ForegroundColor DarkGray -NoNewline
        Write-Host ": " -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) { $val = $Default }
        if (& $Validator $val) { return $val }
        Write-Host "  X $ErrorMsg" -ForegroundColor Red
    }
}

function Test-ValidZipFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read, $false)
            try { return ($zip.Entries.Count -gt 0) }
            finally { $zip.Dispose() }
        }
        finally { $fs.Dispose() }
    } catch {
        return $false
    }
}

function Download-FileWithRetry {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = 900
    )

    # Fuerza TLS moderno para evitar respuestas inesperadas por handshake
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12 -bor `
        [System.Net.SecurityProtocolType]::Tls13

    $tmpFile = "$Destination.part"
    if (Test-Path $tmpFile) { Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue }

    # Metodo 1: BITS (mas estable para archivos grandes en Windows)
    try {
        Write-Log "Intentando descarga con BITS..."
        Start-BitsTransfer -Source $Url -Destination $tmpFile -DisplayName "MS4W Download" -Description "Descargando ms4w_5.0.0.zip" -ErrorAction Stop
    } catch {
        Write-Log "BITS fallo: $($_.Exception.Message)" "WARN"
    }

    # Metodo 2: WebClient con timeout
    if (-not (Test-Path $tmpFile)) {
        try {
            Write-Log "Intentando descarga con WebClient..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MS4W-Installer")
            $task = $wc.DownloadFileTaskAsync($Url, $tmpFile)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $task.IsCompleted) {
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                    throw "Timeout de descarga ($TimeoutSec s)"
                }
                Start-Sleep -Milliseconds 400
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
        } catch {
            Write-Log "WebClient fallo: $($_.Exception.Message)" "WARN"
        }
    }

    # Metodo 3: Invoke-WebRequest como ultimo recurso
    if (-not (Test-Path $tmpFile)) {
        Write-Log "Intentando descarga con Invoke-WebRequest..." "WARN"
        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $tmpFile `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MS4W-Installer" }
    }

    if (-not (Test-Path $tmpFile)) {
        throw "No fue posible descargar el archivo con ninguno de los metodos."
    }

    Move-Item -Path $tmpFile -Destination $Destination -Force
}

trap {
    $msg = $_.Exception.Message
    $detail = $_ | Out-String
    Write-Log "FALLO NO CONTROLADO: $msg" "ERROR"
    Write-Log "DETALLE: $detail" "ERROR"
    Write-Host ""
    Write-Host "  La instalacion fallo. Revisa el log en: $LOG_FILE" -ForegroundColor Red
    Write-Host "  (Si ejecutas con doble click, abre PowerShell y ejecuta el script desde consola para evitar cierre automatico)." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Presiona Enter para salir" | Out-Null
    break
}

# --- PANTALLA DE BIENVENIDA ----------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host "       Instalador MS4W + MapServer / MapCache          " -ForegroundColor Green
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host ""
Write-Log "Inicio de instalacion"

# --- SOLICITAR UNIDAD DE INSTALACION -------------------------------------
$INSTALL_DRIVE = Read-ValidatedInput `
    -Prompt    "Unidad para instalar MS4W y apps (C:, D:, E:, ...)" `
    -Default   "C:" `
    -Validator { param($v) $v -match '^[A-Za-z]:$' } `
    -ErrorMsg  "Unidad no valida. Usa el formato C:, D:, E:, etc."

$INSTALL_DRIVE = $INSTALL_DRIVE.ToUpper()
$MS4W_ROOT     = "$INSTALL_DRIVE\ms4w"
$APPS_ROOT     = "$INSTALL_DRIVE\apps"
$APACHE_BIN    = "$MS4W_ROOT\Apache\cgi-bin"
$APACHE_CONF   = "$MS4W_ROOT\Apache\conf"
$APACHE_EXTRA  = "$MS4W_ROOT\Apache\conf\extra"
$MS4W_ZIP      = "$APPS_ROOT\docs\ms4w_5.0.0.zip"
$LOG_FILE      = "$APPS_ROOT\logs\install_log.txt"
$APPS_ROOT_APACHE = $APPS_ROOT -replace '\\', '/'

if (-not (Test-Path $APPS_ROOT)) {
    throw "No se encontro $APPS_ROOT. Clona el repositorio en esa ruta, por ejemplo:`n  git clone https://github.com/luisamos/apps.git $APPS_ROOT"
}

Write-Log "Unidad de instalacion seleccionada: $INSTALL_DRIVE (APPS=$APPS_ROOT, MS4W=$MS4W_ROOT)"

# --- SOLICITAR IP Y PUERTO -----------------------------------------------
Write-Host "  Configuracion del servidor" -ForegroundColor Yellow
Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

$SERVER_IP = Read-ValidatedInput `
    -Prompt    "IP del servidor" `
    -Default   "127.0.0.2" `
    -Validator { param($v) $v -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' } `
    -ErrorMsg  "Formato de IP no valido. Ejemplo: 127.0.0.2 o 192.168.1.10"

$SERVER_PORT = Read-ValidatedInput `
    -Prompt    "Puerto del servidor" `
    -Default   "8081" `
    -Validator { param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535 } `
    -ErrorMsg  "Puerto no valido. Debe ser un numero entre 1 y 65535."

Write-Host ""
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ("  |  IP configurada : " + $SERVER_IP)                  -ForegroundColor Cyan
Write-Host ("  |  Puerto         : " + $SERVER_PORT)                 -ForegroundColor Cyan
Write-Host ("  |  WMS : http://" + $SERVER_IP + ":" + $SERVER_PORT + "/servicio/wms") -ForegroundColor Cyan
Write-Host ("  |  WFS : http://" + $SERVER_IP + ":" + $SERVER_PORT + "/servicio/wfs") -ForegroundColor Cyan
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ""

$confirm = Read-Host "  Confirmas la configuracion? (S/N) [S]"
if ($confirm -ne "" -and $confirm -notmatch "^[Ss]$") {
    Write-Host "  Instalacion cancelada." -ForegroundColor Yellow
    exit 0
}
Write-Log "Configuracion confirmada — IP: $SERVER_IP  Puerto: $SERVER_PORT"

# --- PASO 1: Descargar MS4W si no existe en docs/ -------------------------
Invoke-Step "Descargar ms4w_5.0.0.zip desde ms4w.com" {
    $docsDir = "$APPS_ROOT\docs"
    if (-not (Test-Path $docsDir)) {
        New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
        Write-Log "Creado directorio: $docsDir"
    }

    $mustDownload = $true
    if (Test-Path $MS4W_ZIP) {
        $existingBytes = (Get-Item $MS4W_ZIP).Length
        $sizeMB = [math]::Round($existingBytes / 1MB, 1)
        if ($existingBytes -ge $MS4W_MIN_BYTES -and (Test-ValidZipFile -Path $MS4W_ZIP)) {
            Write-Log "ms4w_5.0.0.zip ya existe ($sizeMB MB) y es valido, se omite la descarga." "WARN"
            $mustDownload = $false
        } else {
            Write-Log "ms4w_5.0.0.zip existente parece incompleto/corrupto ($sizeMB MB). Se eliminara para descargar nuevamente." "WARN"
            Remove-Item -Path $MS4W_ZIP -Force -ErrorAction Stop
        }
    }

    if ($mustDownload) {
        Write-Log "Descargando desde $MS4W_URL"
        Write-Host "  Destino: $MS4W_ZIP" -ForegroundColor DarkGray
        Write-Host "  Esto puede tardar varios minutos segun la velocidad de internet..." -ForegroundColor DarkGray

        Download-FileWithRetry -Url $MS4W_URL -Destination $MS4W_ZIP -TimeoutSec 1200

        if (-not (Test-Path $MS4W_ZIP)) {
            throw "La descarga fallo. Verifica la conexion o descarga manualmente desde:`n  $MS4W_URL`ny coloca el archivo en $MS4W_ZIP"
        }

        $downloadedBytes = (Get-Item $MS4W_ZIP).Length
        if ($downloadedBytes -lt $MS4W_MIN_BYTES) {
            $sizeMB = [math]::Round($downloadedBytes / 1MB, 1)
            throw "La descarga termino con un archivo demasiado pequeno ($sizeMB MB). Se esperaba un paquete mucho mayor. Elimina el archivo y reintenta."
        }
        if (-not (Test-ValidZipFile -Path $MS4W_ZIP)) {
            throw "El archivo descargado no es un .zip valido. Reintenta la descarga o descarga manualmente desde $MS4W_URL"
        }

        $sizeMB = [math]::Round($downloadedBytes / 1MB, 1)
        Write-Log "Descarga completada: $MS4W_ZIP ($sizeMB MB)"
    }
}

# --- PASO 2: Instalar MS4W descomprimiendo el zip -------------------------
Invoke-Step "Instalar MS4W en $MS4W_ROOT" {
    if (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe") {
        Write-Log "MS4W ya esta instalado en $MS4W_ROOT, se omite la descompresion." "WARN"
    } else {
        Write-Log "Descomprimiendo $MS4W_ZIP  -->  C:\"
        Write-Log "Descomprimiendo $MS4W_ZIP  -->  $INSTALL_DRIVE\"
        Expand-Archive -Path $MS4W_ZIP -DestinationPath "$INSTALL_DRIVE\" -Force
        if (-not (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe")) {
            throw "No se encontro httpd.exe tras la descompresion. Verifica que el zip contiene la carpeta ms4w/"
        }
    }
}

# --- PASO 3: Verificar directorios del repo --------------------------------
Invoke-Step "Verificar $APPS_ROOT" {
    foreach ($dir in @("$APPS_ROOT\mapserv", "$APPS_ROOT\mapcache", "$APPS_ROOT\logs")) {
        if (Test-Path $dir) { Write-Log "OK (del repo): $dir" }
        else { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Write-Log "Creado: $dir" }
    }
}

# --- PASO 4: Actualizar IP y puerto en los archivos .map ------------------
Invoke-Step "Actualizar IP (${SERVER_IP}:${SERVER_PORT}) en archivos .map" {
    foreach ($mapFile in @("$APPS_ROOT\mapserv\wms_kaypacha.map", "$APPS_ROOT\mapserv\wfs_kaypacha.map")) {
        if (Test-Path $mapFile) {
            $c = Get-Content $mapFile -Raw -Encoding UTF8
            $c = $c -replace 'http://[\d\.]+:\d+/servicio/', "http://${SERVER_IP}:${SERVER_PORT}/servicio/"
            $c = $c -replace '(?<=["''\s=])\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?=:\d)', $SERVER_IP
            $c = $c -replace "(?<=http://${SERVER_IP}:)\d+(?=/)", $SERVER_PORT
            Set-Content -Path $mapFile -Value $c -Encoding UTF8
            Write-Log "Actualizado: $(Split-Path $mapFile -Leaf)  (IP=$SERVER_IP Puerto=$SERVER_PORT)"
        } else {
            Write-Log "No encontrado, se omite: $mapFile" "WARN"
        }
    }
}

# --- PASO 5: Duplicar mapserv.exe en wms y wfs (sin extension) ------------
Invoke-Step "Duplicar mapserv.exe  -->  cgi-bin\wms  y  cgi-bin\wfs (sin extension)" {
    $src = "$APACHE_BIN\mapserv.exe"
    if (-not (Test-Path $src)) { throw "mapserv.exe no encontrado en $src" }
    Copy-Item -Path $src -Destination "$APACHE_BIN\wms" -Force
    Copy-Item -Path $src -Destination "$APACHE_BIN\wfs" -Force
    Write-Log "mapserv.exe copiado como cgi-bin\wms y cgi-bin\wfs"
}

# --- PASO 6: Configurar httpd.conf ----------------------------------------
Invoke-Step "Configurar httpd.conf  (Listen $SERVER_PORT + mod_headers)" {
    $httpdConf = "$APACHE_CONF\httpd.conf"
    if (-not (Test-Path $httpdConf)) { throw "No se encontro $httpdConf" }
    $c = Get-Content $httpdConf -Raw
    if ($c -notmatch "Listen $SERVER_PORT\b") {
        $c = $c -replace "(Listen 80\b[^\r\n]*)", "`$1`nListen $SERVER_PORT"
        Write-Log "Agregado 'Listen $SERVER_PORT'"
    } else { Write-Log "'Listen $SERVER_PORT' ya estaba configurado" "WARN" }
    if ($c -match "#LoadModule headers_module") {
        $c = $c -replace "#(LoadModule headers_module)", '$1'
        Write-Log "Habilitado mod_headers"
    }
    if ($c -match "(?m)^#\s*Include\s+conf/extra/httpd-vhosts\.conf\s*$") {
        $c = $c -replace "(?m)^#\s*Include\s+conf/extra/httpd-vhosts\.conf\s*$", "Include conf/extra/httpd-vhosts.conf"
        Write-Log "Descomentado Include conf/extra/httpd-vhosts.conf"
    } elseif ($c -notmatch "(?m)^Include\s+conf/extra/httpd-vhosts\.conf\s*$") {
        $c += "`n# Virtual hosts`nInclude conf/extra/httpd-vhosts.conf`n"
        Write-Log "Agregado bloque de Virtual hosts en httpd.conf"
    }
    Set-Content -Path $httpdConf -Value $c -Encoding UTF8
}

# --- PASO 7: Generar VirtualHost ------------------------------------------
Invoke-Step "Generar VirtualHost <${SERVER_IP}:${SERVER_PORT}>" {
    if (-not (Test-Path $APACHE_EXTRA)) { New-Item -ItemType Directory -Path $APACHE_EXTRA -Force | Out-Null }
    $vhost = @"
# VirtualHost MS4W MapServer/MapCache
# Generado por Install-MS4W-Windows.ps1  |  IP: $SERVER_IP  |  Puerto: $SERVER_PORT

<VirtualHost ${SERVER_IP}:${SERVER_PORT}>
    ServerAdmin luisamos7@gmail.com
    ServerName $SERVER_IP
    ServerAlias $SERVER_IP
    ErrorLog "$APPS_ROOT_APACHE/logs/error_kaypacha.log"
    CustomLog "$APPS_ROOT_APACHE/logs/custom_kaypacha.log" common

    ScriptAlias /servicio/ "/ms4w/Apache/cgi-bin/"

    <Directory "/ms4w/Apache/cgi-bin">
        AllowOverride None
        Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
        Order allow,deny
        Allow from all
        <IfModule mod_headers.c>
            Header set Access-Control-Allow-Origin "*"
        </IfModule>
    </Directory>

    <IfModule mod_headers.c>
        Header set Access-Control-Allow-Origin "*"
        Header set Access-Control-Allow-Methods "GET, POST, OPTIONS, PUT, DELETE"
        Header set Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization"
    </IfModule>

    SetEnvIf Request_URI "/servicio/wms" MS_MAPFILE=$APPS_ROOT_APACHE/mapserv/wms_kaypacha.map
    SetEnvIf Request_URI "/servicio/wfs" MS_MAPFILE=$APPS_ROOT_APACHE/mapserv/wfs_kaypacha.map

    <IfModule mapcache_module>
        <Directory "$APPS_ROOT_APACHE/mapcache/">
            AllowOverride None
            Options None
            Require all granted
        </Directory>
        MapCacheAlias /mapcache "$APPS_ROOT_APACHE/mapcache/mapcache.xml"
    </IfModule>
</VirtualHost>
"@
    Set-Content -Path "$APACHE_EXTRA\httpd-vhosts.conf" -Value $vhost -Encoding UTF8
    Write-Log "VirtualHost escrito en $APACHE_EXTRA\httpd-vhosts.conf"
}

# --- PASO 8: Agregar IP al loopback (solo 127.x.x.x) ---------------------
Invoke-Step "Configurar IP $SERVER_IP en adaptador de red" {
    if ($SERVER_IP -match "^127\.") {
        $existing = netsh interface ip show address "Loopback Pseudo-Interface 1" 2>&1
        if ($existing -notmatch [regex]::Escape($SERVER_IP)) {
            netsh interface ip add address "Loopback Pseudo-Interface 1" $SERVER_IP 255.0.0.0 | Out-Null
            Write-Log "IP $SERVER_IP agregada al adaptador loopback"
        } else { Write-Log "IP $SERVER_IP ya estaba configurada" "WARN" }
    } else {
        Write-Log "IP $SERVER_IP no es loopback. Asegurate de que este asignada a una interfaz activa." "WARN"
    }
}

# --- PASO 9: Registrar e iniciar Apache como servicio ---------------------
Invoke-Step "Registrar e iniciar Apache como servicio Windows" {
    $httpdExe = "$MS4W_ROOT\Apache\bin\httpd.exe"
    $result = & $httpdExe -t 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en Apache:`n$result" }
    Write-Log "Sintaxis OK"
    $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($null -eq $svc) { & $httpdExe -k install -n $SERVICE_NAME | Out-Null; Write-Log "Servicio registrado" }
    $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc.Status -eq "Running") { Restart-Service -Name $SERVICE_NAME -Force; Write-Log "Apache reiniciado" }
    else { Start-Service -Name $SERVICE_NAME; Write-Log "Apache iniciado" }
    Start-Sleep -Seconds 2
    Write-Log "Estado del servicio: $((Get-Service -Name $SERVICE_NAME).Status)"
}

# --- RESUMEN FINAL --------------------------------------------------------
Write-Host ""
Write-Host "  =============================================================" -ForegroundColor Green
Write-Host "    Instalacion completada exitosamente" -ForegroundColor Green
Write-Host "  =============================================================" -ForegroundColor DarkGreen
Write-Host ("  Servidor : http://" + $SERVER_IP + ":" + $SERVER_PORT) -ForegroundColor Cyan
Write-Host ""
Write-Host "  WMS:" -ForegroundColor White
Write-Host ("  http://" + $SERVER_IP + ":" + $SERVER_PORT + "/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities") -ForegroundColor Cyan
Write-Host ""
Write-Host "  WFS:" -ForegroundColor White
Write-Host ("  http://" + $SERVER_IP + ":" + $SERVER_PORT + "/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities") -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Log de instalacion : " + $LOG_FILE) -ForegroundColor Yellow
Write-Host "  =============================================================" -ForegroundColor Green
Write-Host ""
Write-Log "Instalacion finalizada. IP=$SERVER_IP Puerto=$SERVER_PORT"
