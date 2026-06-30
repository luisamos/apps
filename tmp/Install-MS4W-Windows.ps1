#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instalador automatizado de MS4W con MapServer / MapCache
.DESCRIPTION
    PREREQUISITO: clonar el repositorio en <UNIDAD>:\apps
        git clone https://github.com/luisamos/apps.git D:\apps

    Luego este script hace todo lo demas:
    - Solicita la IP, el puerto, el SRID, el EXTENT y la ruta del raster de la ortofoto
    - Descarga ms4w_5.2.0.zip desde ms4w.com si no existe en <UNIDAD>:\apps\docs\
    - Descomprime <UNIDAD>:\apps\docs\ms4w_5.2.0.zip en <UNIDAD>:\ms4w
    - Verifica que <UNIDAD>:\apps\mapserv, mapcache y logs existan (vienen del repo)
    - Actualiza la IP y el puerto dentro de wms_kaypacha.map y wfs_kaypacha.map
    - Configura el SRID y el EXTENT en los .map de /mapserv/capas/kaypacha
    - Actualiza la ruta DATA del raster (ECW/GeoTIFF) en ortofoto.map
    - Duplica mapserv.exe en cgi-bin\wms y cgi-bin\wfs
    - Agrega Listen <puerto> al httpd.conf y habilita mod_headers
    - Genera httpd-vhosts.conf con DocumentRoot, GDAL_DRIVER_PATH y MapCache
    - Habilita MapCache ajustando mapcache.xml (IP/puerto y unidad de instalacion)
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
$MS4W_VERSION = "5.2.0"
$MS4W_FILE    = "ms4w_$MS4W_VERSION.zip"
$MS4W_URL     = "https://ms4w.com/release/$MS4W_FILE"
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

function Test-Ms4wPackage {
    param(
        [string]$Path,
        [long]$MinimumBytes = $MS4W_MIN_BYTES
    )

    if (-not (Test-Path $Path)) { return $false }

    $bytes = (Get-Item $Path).Length
    if ($bytes -lt $MinimumBytes) { return $false }

    return (Test-ValidZipFile -Path $Path)
}

function Remove-FileIfExists {
    param([string]$Path)
    if (Test-Path $Path) { Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue }
}

function Set-ModernSecurityProtocol {
    # Fuerza TLS moderno, pero sin romper PowerShell/.NET antiguos que no tienen Tls13.
    $protocol = [System.Net.SecurityProtocolType]::Tls12
    if ([Enum]::GetNames([System.Net.SecurityProtocolType]) -contains "Tls13") {
        $protocol = $protocol -bor [System.Net.SecurityProtocolType]::Tls13
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $protocol
}

function Complete-DownloadIfValid {
    param(
        [string]$TempPath,
        [string]$Destination,
        [long]$MinimumBytes
    )

    if (Test-Ms4wPackage -Path $TempPath -MinimumBytes $MinimumBytes) {
        Move-Item -Path $TempPath -Destination $Destination -Force
        return $true
    }

    if (Test-Path $TempPath) {
        $sizeMB = [math]::Round((Get-Item $TempPath).Length / 1MB, 1)
        Write-Log "Descarga temporal invalida ($sizeMB MB); se elimina y se intentara otro metodo." "WARN"
        Remove-FileIfExists -Path $TempPath
    }
    return $false
}

function Download-FileWithRetry {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = 900,
        [long]$MinimumBytes = 50MB
    )

    Set-ModernSecurityProtocol

    $tmpFile = "$Destination.part"
    Remove-FileIfExists -Path $tmpFile

    try {
        Write-Log "Intentando descarga con BITS..."
        Start-BitsTransfer -Source $Url -Destination $tmpFile -DisplayName "MS4W Download" -Description "Descargando $MS4W_FILE" -ErrorAction Stop
    } catch {
        Write-Log "BITS fallo: $($_.Exception.Message)" "WARN"
        Remove-FileIfExists -Path $tmpFile
    }
    if (Complete-DownloadIfValid -TempPath $tmpFile -Destination $Destination -MinimumBytes $MinimumBytes) { return }

    try {
        Write-Log "Intentando descarga con WebClient..."
        $wc = New-Object System.Net.WebClient
        try {
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
        } finally {
            $wc.Dispose()
        }
    } catch {
        Write-Log "WebClient fallo: $($_.Exception.Message)" "WARN"
        Remove-FileIfExists -Path $tmpFile
    }
    if (Complete-DownloadIfValid -TempPath $tmpFile -Destination $Destination -MinimumBytes $MinimumBytes) { return }

    try {
        Write-Log "Intentando descarga con Invoke-WebRequest..." "WARN"
        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $tmpFile `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MS4W-Installer" } `
            -ErrorAction Stop
    } catch {
        Write-Log "Invoke-WebRequest fallo: $($_.Exception.Message)" "WARN"
        Remove-FileIfExists -Path $tmpFile
    }
    if (Complete-DownloadIfValid -TempPath $tmpFile -Destination $Destination -MinimumBytes $MinimumBytes) { return }

    throw "No fue posible descargar un paquete valido desde $Url. Descargalo manualmente y copialo en $Destination"
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
$MS4W_ZIP      = "$APPS_ROOT\docs\$MS4W_FILE"
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

# --- DETECTAR SRID Y EXTENT ACTUALES (valores por defecto) ----------------
# Se leen desde una capa de referencia para proponerlos como valores por defecto.
$DEFAULT_SRID   = "32719"
$DEFAULT_EXTENT = "178070.01586802542 8501210.991231522 184071.98480267922 8503438.897198547"
$refLayer = "$APPS_ROOT\mapserv\capas\kaypacha\wms\lote.map"
if (Test-Path $refLayer) {
    $refContent = Get-Content $refLayer -Raw -Encoding UTF8
    if ($refContent -match 'using\s+srid=(\d+)') { $DEFAULT_SRID = $Matches[1] }
    if ($refContent -match '"wms_extent"\s+"([^"]+)"') { $DEFAULT_EXTENT = $Matches[1] }
}

Write-Host ""
Write-Host "  Configuracion geoespacial (capas de /mapserv/capas/kaypacha)" -ForegroundColor Yellow
Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# SRID sobre el cual se desplegaran los servicios WMS y WFS
$SERVICE_SRID = Read-ValidatedInput `
    -Prompt    "SRID/EPSG de las capas (solo el numero, p.ej. 32719)" `
    -Default   $DEFAULT_SRID `
    -Validator { param($v) $v -match '^\d{4,6}$' } `
    -ErrorMsg  "SRID no valido. Ingresa solo el codigo numerico EPSG, p.ej. 32719 o 4326."

# EXTENT (en las unidades del SRID indicado): minx miny maxx maxy
$SERVICE_EXTENT = Read-ValidatedInput `
    -Prompt    "EXTENT minx miny maxx maxy (unidades del SRID)" `
    -Default   $DEFAULT_EXTENT `
    -Validator { param($v) ($v.Trim() -split '\s+').Count -eq 4 -and -not (($v.Trim() -split '\s+') | Where-Object { $_ -notmatch '^-?\d+(\.\d+)?$' }) } `
    -ErrorMsg  "EXTENT no valido. Deben ser 4 numeros separados por espacios: minx miny maxx maxy."
$SERVICE_EXTENT = ($SERVICE_EXTENT.Trim() -split '\s+') -join ' '

# --- DETECTAR RUTA DEL RASTER (ortofoto) ----------------------------------
# Ruta del archivo raster (ECW/GeoTIFF) usado por la capa ortofoto del WMS.
$DEFAULT_RASTER = "$APPS_ROOT_APACHE/mapserv/archivos/raster/machupicchu.ecw"
$ortofotoMap = "$APPS_ROOT\mapserv\capas\kaypacha\wms\ortofoto.map"
if (Test-Path $ortofotoMap) {
    $ortoContent = Get-Content $ortofotoMap -Raw -Encoding UTF8
    if ($ortoContent -match '(?im)^\s*DATA\s+"([^"]+)"') {
        $detected = $Matches[1]
        # Normaliza la unidad al disco de instalacion y usa "/"
        $detected = $detected -replace '\\', '/'
        $detected = $detected -replace '^[A-Za-z]:', $INSTALL_DRIVE
        $detected = $detected -replace '^/apps', "$APPS_ROOT_APACHE"
        $DEFAULT_RASTER = $detected
    }
}

$RASTER_PATH = Read-ValidatedInput `
    -Prompt    "Ruta del raster de la ortofoto (ECW/GeoTIFF)" `
    -Default   $DEFAULT_RASTER `
    -Validator { param($v) $v -match '\.(ecw|tif|tiff|jp2|img|vrt)$' } `
    -ErrorMsg  "Ruta no valida. Debe terminar en .ecw, .tif, .tiff, .jp2, .img o .vrt"
$RASTER_PATH = $RASTER_PATH -replace '\\', '/'

Write-Host ""
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ("  |  IP configurada : " + $SERVER_IP)                  -ForegroundColor Cyan
Write-Host ("  |  Puerto         : " + $SERVER_PORT)                 -ForegroundColor Cyan
Write-Host ("  |  SRID/EPSG      : " + $SERVICE_SRID)                -ForegroundColor Cyan
Write-Host ("  |  EXTENT         : " + $SERVICE_EXTENT)              -ForegroundColor Cyan
Write-Host ("  |  Raster ortofoto: " + $RASTER_PATH)                 -ForegroundColor Cyan
Write-Host ("  |  WMS : http://" + $SERVER_IP + ":" + $SERVER_PORT + "/servicio/wms") -ForegroundColor Cyan
Write-Host ("  |  WFS : http://" + $SERVER_IP + ":" + $SERVER_PORT + "/servicio/wfs") -ForegroundColor Cyan
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ""

$confirm = Read-Host "  Confirmas la configuracion? (S/N) [S]"
if ($confirm -ne "" -and $confirm -notmatch "^[Ss]$") {
    Write-Host "  Instalacion cancelada." -ForegroundColor Yellow
    exit 0
}
Write-Log "Configuracion confirmada — IP: $SERVER_IP  Puerto: $SERVER_PORT  SRID: $SERVICE_SRID  EXTENT: $SERVICE_EXTENT  Raster: $RASTER_PATH"

# --- PASO 1: Descargar MS4W si no existe en docs/ -------------------------
Invoke-Step "Preparar paquete $MS4W_FILE" {
    $docsDir = "$APPS_ROOT\docs"
    if (-not (Test-Path $docsDir)) {
        New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
        Write-Log "Creado directorio: $docsDir"
    }

    $mustDownload = $true
    if (Test-Path $MS4W_ZIP) {
        $existingBytes = (Get-Item $MS4W_ZIP).Length
        $sizeMB = [math]::Round($existingBytes / 1MB, 1)
        if (Test-Ms4wPackage -Path $MS4W_ZIP) {
            Write-Log "$MS4W_FILE ya existe en $MS4W_ZIP ($sizeMB MB) y es valido; se instala sin descargar." "WARN"
            $mustDownload = $false
        } else {
            Write-Log "$MS4W_FILE existente parece incompleto/corrupto ($sizeMB MB). Se eliminara para descargar nuevamente." "WARN"
            Remove-Item -Path $MS4W_ZIP -Force -ErrorAction Stop
        }
    }

    if ($mustDownload) {
        Write-Log "Descargando desde $MS4W_URL"
        Write-Host "  Destino: $MS4W_ZIP" -ForegroundColor DarkGray
        Write-Host "  Esto puede tardar varios minutos segun la velocidad de internet..." -ForegroundColor DarkGray

        Download-FileWithRetry -Url $MS4W_URL -Destination $MS4W_ZIP -TimeoutSec 1200 -MinimumBytes $MS4W_MIN_BYTES

        $sizeMB = [math]::Round((Get-Item $MS4W_ZIP).Length / 1MB, 1)
        Write-Log "Descarga completada: $MS4W_ZIP ($sizeMB MB)"
    }
}

# --- PASO 2: Instalar MS4W descomprimiendo el zip -------------------------
Invoke-Step "Instalar MS4W en $MS4W_ROOT" {
    if (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe") {
        Write-Log "MS4W ya esta instalado en $MS4W_ROOT, se omite la descompresion." "WARN"
    } else {
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

# --- PASO 5: Configurar SRID y EXTENT en los archivos .map ----------------
Invoke-Step "Configurar SRID ($SERVICE_SRID) y EXTENT en archivos .map de Kaypacha" {
    $OLD_SRID = $DEFAULT_SRID

    # 5.1 — Capas de /mapserv/capas/kaypacha (WMS y WFS)
    $capasDir = "$APPS_ROOT\mapserv\capas\kaypacha"
    if (Test-Path $capasDir) {
        $layerFiles = Get-ChildItem -Path $capasDir -Recurse -Filter *.map -File
        foreach ($f in $layerFiles) {
            $c = Get-Content $f.FullName -Raw -Encoding UTF8
            $orig = $c
            # SRID principal del catastro: se reemplaza solo el SRID anterior,
            # respetando capas que usan deliberadamente otro SRID (p.ej. EPSG:4326 en reportes).
            $c = $c -replace "using\s+srid=$OLD_SRID", "using srid=$SERVICE_SRID"
            $c = $c -replace "init=epsg:$OLD_SRID", "init=epsg:$SERVICE_SRID"
            $c = $c -replace "EPSG:$OLD_SRID\b", "EPSG:$SERVICE_SRID"
            # EXTENT de cada capa (metadato wms_extent)
            $c = $c -replace '("wms_extent"\s+")[^"]*(")', "`${1}$SERVICE_EXTENT`${2}"
            if ($c -ne $orig) {
                Set-Content -Path $f.FullName -Value $c -Encoding UTF8
                Write-Log "SRID/EXTENT actualizado en capa: capas\kaypacha\$($f.Directory.Name)\$($f.Name)"
            }
        }
    } else {
        Write-Log "No se encontro $capasDir, se omite la configuracion de capas." "WARN"
    }

    # 5.2 — Archivos principales wms_kaypacha.map y wfs_kaypacha.map
    foreach ($mapFile in @("$APPS_ROOT\mapserv\wms_kaypacha.map", "$APPS_ROOT\mapserv\wfs_kaypacha.map")) {
        if (Test-Path $mapFile) {
            $c = Get-Content $mapFile -Raw -Encoding UTF8
            # EXTENT a nivel MAP (primera ocurrencia; NO toca el EXTENT del bloque REFERENCE)
            $rxExtent = [regex]'(?m)^(\s*EXTENT\s+).*$'
            $c = $rxExtent.Replace($c, "`${1}$SERVICE_EXTENT", 1)
            # PROJECTION a nivel MAP
            $c = $c -replace 'init=epsg:\d+', "init=epsg:$SERVICE_SRID"
            # SRS anunciado: se reemplaza el SRID anterior por el nuevo
            $c = $c -replace "EPSG:$OLD_SRID\b", "EPSG:$SERVICE_SRID"
            Set-Content -Path $mapFile -Value $c -Encoding UTF8
            Write-Log "SRID/EXTENT actualizado en: $(Split-Path $mapFile -Leaf)  (SRID=$SERVICE_SRID)"
        } else {
            Write-Log "No encontrado, se omite: $mapFile" "WARN"
        }
    }

    # 5.3 — Ruta del raster en la capa ortofoto (DATA)
    if (Test-Path $ortofotoMap) {
        $c = Get-Content $ortofotoMap -Raw -Encoding UTF8
        $rxData = [regex]'(?im)^(\s*DATA\s+")[^"]*(")'
        if ($rxData.IsMatch($c)) {
            $c = $rxData.Replace($c, "`${1}$RASTER_PATH`${2}", 1)
            Set-Content -Path $ortofotoMap -Value $c -Encoding UTF8
            Write-Log "Raster de ortofoto actualizado: $RASTER_PATH"
        } else {
            Write-Log "No se encontro directiva DATA en ortofoto.map; se omite." "WARN"
        }
    } else {
        Write-Log "No se encontro $ortofotoMap; se omite la ruta del raster." "WARN"
    }
}

# --- PASO 6: Duplicar mapserv.exe en wms y wfs (sin extension) ------------
Invoke-Step "Duplicar mapserv.exe  -->  cgi-bin\wms  y  cgi-bin\wfs (sin extension)" {
    $src = "$APACHE_BIN\mapserv.exe"
    if (-not (Test-Path $src)) { throw "mapserv.exe no encontrado en $src" }
    Copy-Item -Path $src -Destination "$APACHE_BIN\wms" -Force
    Copy-Item -Path $src -Destination "$APACHE_BIN\wfs" -Force
    Write-Log "mapserv.exe copiado como cgi-bin\wms y cgi-bin\wfs"
}

# --- PASO 7: Configurar httpd.conf ----------------------------------------
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

# --- PASO 8: Generar VirtualHost (con DocumentRoot y MapCache) ------------
Invoke-Step "Generar VirtualHost <${SERVER_IP}:${SERVER_PORT}>" {
    if (-not (Test-Path $APACHE_EXTRA)) { New-Item -ItemType Directory -Path $APACHE_EXTRA -Force | Out-Null }

    $MS4W_ROOT_APACHE = $MS4W_ROOT -replace '\\', '/'
    $DOCROOT_APACHE   = "$APPS_ROOT_APACHE/www/visor-kaypacha"
    $docRootWin       = "$APPS_ROOT\www\visor-kaypacha"
    if (-not (Test-Path $docRootWin)) {
        New-Item -ItemType Directory -Path $docRootWin -Force | Out-Null
        Write-Log "Creado DocumentRoot: $docRootWin"
    }

    $vhost = @"
# VirtualHost MS4W MapServer/MapCache
# Generado por Install-MS4W-Windows.ps1  |  IP: $SERVER_IP  |  Puerto: $SERVER_PORT

<VirtualHost ${SERVER_IP}:${SERVER_PORT}>
    ServerAdmin luisamos7@gmail.com
    ServerName $SERVER_IP
    ServerAlias $SERVER_IP
    DocumentRoot "$DOCROOT_APACHE"
    ErrorLog "$APPS_ROOT_APACHE/logs/error_kaypacha.log"
    CustomLog "$APPS_ROOT_APACHE/logs/custom_kaypacha.log" common

    <Directory "$DOCROOT_APACHE">
        Options Indexes FollowSymLinks MultiViews
        AllowOverride all
        Order allow,deny
        allow from all
        Header set Access-Control-Allow-Origin "*"
        Header set Access-Control-Allow-Methods "GET, POST, OPTIONS"
        Header set Access-Control-Allow-Headers "Content-Type, Authorization"
    </Directory>

    ScriptAlias /servicio/ "/ms4w/Apache/cgi-bin/"

    <Directory "/ms4w/Apache/cgi-bin">
        AllowOverride None
        Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
        Order allow,deny
        Allow from all
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

    SetEnvIf Request_URI "/servicio/wms" MS_MAPFILE=$APPS_ROOT_APACHE/mapserv/wms_kaypacha.map
    SetEnvIf Request_URI "/servicio/wfs" MS_MAPFILE=$APPS_ROOT_APACHE/mapserv/wfs_kaypacha.map

    SetEnv GDAL_DRIVER_PATH "$MS4W_ROOT_APACHE/gdalplugins"

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

# --- PASO 9: Configurar y habilitar MapCache (mapcache.xml) ----------------
Invoke-Step "Configurar MapCache (mapcache.xml) con IP/puerto y unidad $INSTALL_DRIVE" {
    $mapcacheXml = "$APPS_ROOT\mapcache\mapcache.xml"
    if (-not (Test-Path $mapcacheXml)) {
        Write-Log "No se encontro $mapcacheXml; se omite la configuracion de MapCache." "WARN"
        return
    }

    # El servicio WMS/WMTS al que apunta MapCache. Si el puerto es 80 se omite (host por defecto).
    $WMS_HOST = if ($SERVER_PORT -eq "80") { $SERVER_IP } else { "${SERVER_IP}:${SERVER_PORT}" }

    $c = Get-Content $mapcacheXml -Raw -Encoding UTF8
    # Ajusta la unidad de instalacion en las rutas (<base>, <template>, <dbfile>, <lock_dir>)
    $c = $c -replace '[A-Za-z]:/apps', "$APPS_ROOT_APACHE"
    # Apunta cada fuente WMS a la IP y puerto indicados
    $c = $c -replace '(<url>\s*http://)[^/]+(/servicio/wms\?\s*</url>)', "`${1}$WMS_HOST`${2}"
    Set-Content -Path $mapcacheXml -Value $c -Encoding UTF8
    Write-Log "mapcache.xml actualizado (host WMS=$WMS_HOST, unidad=$INSTALL_DRIVE)"
}

# --- PASO 10: Agregar IP al loopback (solo 127.x.x.x) --------------------
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

# --- PASO 11: Registrar e iniciar Apache como servicio --------------------
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