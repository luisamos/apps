#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instalador automatizado de MS4W con MapServer / MapCache

.DESCRIPTION
    PREREQUISITO: clonar el repositorio en <UNIDAD>:\apps
        git clone https://github.com/luisamos/apps.git D:\apps

    Este instalador:
    - Solicita la IP y el puerto donde correra MS4W.
    - Usa ms4w_5.2.0.zip si ya existe en <UNIDAD>:\apps\docs\.
    - Si no existe, descarga ms4w_5.2.0.zip desde ms4w.com.
    - No elimina automaticamente un ZIP manual si supera el tamano minimo.
    - Descomprime <UNIDAD>:\apps\docs\ms4w_5.2.0.zip en <UNIDAD>:\ms4w.
    - Verifica carpetas del repositorio.
    - Actualiza IP y puerto en wms_kaypacha.map y wfs_kaypacha.map.
    - Duplica mapserv.exe como cgi-bin\wms y cgi-bin\wfs.
    - Configura Apache/httpd.conf y VirtualHost.
    - Registra e inicia Apache como servicio de Windows.

.NOTES
    Ejecutar como Administrador:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        C:\apps\tmp\Install-MS4W-Windows.ps1
#>

# --- RUTAS Y URLS -------------------------------------------------------
$INSTALL_DRIVE = $null
$MS4W_ROOT     = $null
$APPS_ROOT     = $null
$APACHE_BIN    = $null
$APACHE_CONF   = $null
$APACHE_EXTRA  = $null
$MS4W_ZIP      = $null
$MS4W_VERSION  = "5.2.0"
$MS4W_FILE     = "ms4w_$MS4W_VERSION.zip"
$MS4W_URL      = "https://ms4w.com/release/$MS4W_FILE"

# MS4W 5.2.0 pesa aprox. 434 MB. Se usa 300 MB para detectar descargas HTML o incompletas.
$MS4W_MIN_BYTES = 300MB

$SERVICE_NAME  = "Apache MS4W Web Server"
$LOG_FILE      = $null

# --- FUNCIONES AUXILIARES -----------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"

    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        default { "Cyan" }
    }

    Write-Host $line -ForegroundColor $color

    $effectiveLogFile = $LOG_FILE
    if ([string]::IsNullOrWhiteSpace($effectiveLogFile)) {
        $effectiveLogFile = Join-Path ([System.IO.Path]::GetTempPath()) "install_ms4w_bootstrap.log"
    }

    try {
        $logDir = Split-Path $effectiveLogFile
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $effectiveLogFile -Value $line
    } catch {
        Write-Host "No se pudo escribir en el log: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Log ("-- {0} --" -f $Name)

    try {
        & $Action
        Write-Log ("{0} completado OK" -f $Name)
    } catch {
        Write-Log ("Error en '{0}': {1}" -f $Name, $_.Exception.Message) "ERROR"
        throw
    }
}

function Read-ValidatedInput {
    param(
        [string]$Prompt,
        [string]$Default,
        [scriptblock]$Validator,
        [string]$ErrorMsg
    )

    while ($true) {
        Write-Host "  $Prompt " -ForegroundColor White -NoNewline
        Write-Host "[$Default]" -ForegroundColor DarkGray -NoNewline
        Write-Host ": " -NoNewline

        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) {
            $val = $Default
        }

        if (& $Validator $val) {
            return $val
        }

        Write-Host "  X $ErrorMsg" -ForegroundColor Red
    }
}

function Remove-FileIfExists {
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Set-ModernSecurityProtocol {
    try {
        $protocol = [System.Net.SecurityProtocolType]::Tls12
        if ([Enum]::GetNames([System.Net.SecurityProtocolType]) -contains "Tls13") {
            $protocol = $protocol -bor [System.Net.SecurityProtocolType]::Tls13
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $protocol
    } catch {
        Write-Log ("No se pudo forzar TLS moderno: {0}" -f $_.Exception.Message) "WARN"
    }
}

function Get-FileSizeMB {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return 0
    }

    return [math]::Round((Get-Item $Path).Length / 1MB, 1)
}

function Test-PackageSize {
    param(
        [string]$Path,
        [long]$MinimumBytes = $MS4W_MIN_BYTES
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $bytes = (Get-Item $Path).Length
    return ($bytes -ge $MinimumBytes)
}

function Test-ZipReadableBestEffort {
    param([string]$Path)

    # Esta validacion es informativa. En algunas instalaciones de Windows PowerShell
    # ZipArchive puede fallar por ensamblados .NET, aun cuando el ZIP sea correcto.
    # Por eso NO se usa para eliminar el archivo manual.
    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        try {
            $zip = New-Object System.IO.Compression.ZipArchive(
                $fs,
                [System.IO.Compression.ZipArchiveMode]::Read,
                $false
            )

            try {
                return ($zip.Entries.Count -gt 0)
            } finally {
                $zip.Dispose()
            }
        } finally {
            $fs.Dispose()
        }
    } catch {
        Write-Log ("Validacion ZIP no concluyente para {0}: {1}" -f $Path, $_.Exception.Message) "WARN"
        return $null
    }
}

function Assert-Ms4wPackageAvailable {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw ("No existe el paquete MS4W: {0}" -f $Path)
    }

    $sizeMB = Get-FileSizeMB -Path $Path
    if (-not (Test-PackageSize -Path $Path -MinimumBytes $MS4W_MIN_BYTES)) {
        throw ("El paquete {0} parece incompleto. Tamano actual: {1} MB. Debe superar aprox. {2} MB." -f $Path, $sizeMB, [math]::Round($MS4W_MIN_BYTES / 1MB, 0))
    }

    $zipCheck = Test-ZipReadableBestEffort -Path $Path
    if ($zipCheck -eq $true) {
        Write-Log ("ZIP verificado correctamente: {0} ({1} MB)" -f $Path, $sizeMB)
    } elseif ($zipCheck -eq $false) {
        Write-Log ("No se pudo confirmar la estructura ZIP de {0}; se continuara y Expand-Archive hara la validacion definitiva." -f $Path) "WARN"
    } else {
        Write-Log ("Se continuara con {0} ({1} MB). Expand-Archive validara al descomprimir." -f $Path, $sizeMB) "WARN"
    }
}

function Complete-DownloadIfValid {
    param(
        [string]$TempPath,
        [string]$Destination,
        [long]$MinimumBytes
    )

    if (Test-PackageSize -Path $TempPath -MinimumBytes $MinimumBytes) {
        $sizeMB = Get-FileSizeMB -Path $TempPath
        Move-Item -Path $TempPath -Destination $Destination -Force
        Write-Log ("Descarga aceptada por tamano: {0} ({1} MB)" -f $Destination, $sizeMB)
        return $true
    }

    if (Test-Path $TempPath) {
        $sizeMB = Get-FileSizeMB -Path $TempPath
        Write-Log ("Descarga temporal incompleta ({0} MB); se elimina y se intentara otro metodo." -f $sizeMB) "WARN"
        Remove-FileIfExists -Path $TempPath
    }

    return $false
}

function Download-FileWithRetry {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = 1200,
        [long]$MinimumBytes = $MS4W_MIN_BYTES
    )

    Set-ModernSecurityProtocol

    $tmpFile = "$Destination.part"
    Remove-FileIfExists -Path $tmpFile

    try {
        Write-Log "Intentando descarga con BITS..."
        Start-BitsTransfer `
            -Source $Url `
            -Destination $tmpFile `
            -DisplayName "MS4W Download" `
            -Description ("Descargando {0}" -f $MS4W_FILE) `
            -ErrorAction Stop
    } catch {
        Write-Log ("BITS fallo: {0}" -f $_.Exception.Message) "WARN"
        Remove-FileIfExists -Path $tmpFile
    }

    if (Complete-DownloadIfValid -TempPath $tmpFile -Destination $Destination -MinimumBytes $MinimumBytes) {
        return
    }

    try {
        Write-Log "Intentando descarga con WebClient..."
        $wc = New-Object System.Net.WebClient

        try {
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MS4W-Installer")
            $task = $wc.DownloadFileTaskAsync($Url, $tmpFile)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            while (-not $task.IsCompleted) {
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                    throw ("Timeout de descarga ({0} s)" -f $TimeoutSec)
                }
                Start-Sleep -Milliseconds 400
            }

            if ($task.IsFaulted) {
                throw $task.Exception.InnerException
            }
        } finally {
            $wc.Dispose()
        }
    } catch {
        Write-Log ("WebClient fallo: {0}" -f $_.Exception.Message) "WARN"
        Remove-FileIfExists -Path $tmpFile
    }

    if (Complete-DownloadIfValid -TempPath $tmpFile -Destination $Destination -MinimumBytes $MinimumBytes) {
        return
    }

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
        Write-Log ("Invoke-WebRequest fallo: {0}" -f $_.Exception.Message) "WARN"
        Remove-FileIfExists -Path $tmpFile
    }

    if (Complete-DownloadIfValid -TempPath $tmpFile -Destination $Destination -MinimumBytes $MinimumBytes) {
        return
    }

    throw ("No fue posible descargar un paquete valido desde {0}. Descargalo manualmente y copialo en {1}" -f $Url, $Destination)
}

function Add-Or-ReplaceLine {
    param(
        [string]$Content,
        [string]$Pattern,
        [string]$Replacement,
        [switch]$AppendIfMissing
    )

    if ($Content -match $Pattern) {
        return ($Content -replace $Pattern, $Replacement)
    }

    if ($AppendIfMissing) {
        return ($Content + "`r`n" + $Replacement + "`r`n")
    }

    return $Content
}

trap {
    $msg = $_.Exception.Message
    $detail = $_ | Out-String

    Write-Log ("FALLO NO CONTROLADO: {0}" -f $msg) "ERROR"
    Write-Log ("DETALLE: {0}" -f $detail) "ERROR"

    Write-Host ""
    Write-Host ("  La instalacion fallo. Revisa el log en: {0}" -f $LOG_FILE) -ForegroundColor Red
    Write-Host "  Si ejecutas con doble click, abre PowerShell como administrador y ejecuta el script desde consola." -ForegroundColor Yellow
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
    throw ("No se encontro {0}. Clona el repositorio en esa ruta, por ejemplo:`n  git clone https://github.com/luisamos/apps.git {0}" -f $APPS_ROOT)
}

Write-Log ("Unidad de instalacion seleccionada: {0} (APPS={1}, MS4W={2})" -f $INSTALL_DRIVE, $APPS_ROOT, $MS4W_ROOT)

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
Write-Host ("  |  IP configurada : {0}" -f $SERVER_IP) -ForegroundColor Cyan
Write-Host ("  |  Puerto         : {0}" -f $SERVER_PORT) -ForegroundColor Cyan
Write-Host ("  |  WMS : http://{0}:{1}/servicio/wms" -f $SERVER_IP, $SERVER_PORT) -ForegroundColor Cyan
Write-Host ("  |  WFS : http://{0}:{1}/servicio/wfs" -f $SERVER_IP, $SERVER_PORT) -ForegroundColor Cyan
Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ""

$confirm = Read-Host "  Confirmas la configuracion? (S/N) [S]"
if ($confirm -ne "" -and $confirm -notmatch "^[Ss]$") {
    Write-Host "  Instalacion cancelada." -ForegroundColor Yellow
    exit 0
}

Write-Log ("Configuracion confirmada - IP: {0}  Puerto: {1}" -f $SERVER_IP, $SERVER_PORT)

# --- PASO 1: Preparar paquete MS4W ----------------------------------------
Invoke-Step ("Preparar paquete {0}" -f $MS4W_FILE) {
    $docsDir = "$APPS_ROOT\docs"

    if (-not (Test-Path $docsDir)) {
        New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
        Write-Log ("Creado directorio: {0}" -f $docsDir)
    }

    $mustDownload = $true

    if (Test-Path $MS4W_ZIP) {
        $sizeMB = Get-FileSizeMB -Path $MS4W_ZIP

        if (Test-PackageSize -Path $MS4W_ZIP -MinimumBytes $MS4W_MIN_BYTES) {
            Write-Log ("{0} ya existe en {1} ({2} MB). Se usara este archivo local; NO se eliminara." -f $MS4W_FILE, $MS4W_ZIP, $sizeMB) "WARN"
            Assert-Ms4wPackageAvailable -Path $MS4W_ZIP
            $mustDownload = $false
        } else {
            Write-Log ("{0} existe pero esta incompleto ({1} MB). Se eliminara para descargar nuevamente." -f $MS4W_FILE, $sizeMB) "WARN"
            Remove-Item -Path $MS4W_ZIP -Force -ErrorAction Stop
        }
    }

    if ($mustDownload) {
        Write-Log ("Descargando desde {0}" -f $MS4W_URL)
        Write-Host ("  Destino: {0}" -f $MS4W_ZIP) -ForegroundColor DarkGray
        Write-Host "  Esto puede tardar varios minutos segun la velocidad de internet..." -ForegroundColor DarkGray

        Download-FileWithRetry -Url $MS4W_URL -Destination $MS4W_ZIP -TimeoutSec 1200 -MinimumBytes $MS4W_MIN_BYTES
        Assert-Ms4wPackageAvailable -Path $MS4W_ZIP

        $sizeMB = Get-FileSizeMB -Path $MS4W_ZIP
        Write-Log ("Descarga completada: {0} ({1} MB)" -f $MS4W_ZIP, $sizeMB)
    }
}

# --- PASO 2: Instalar MS4W descomprimiendo el zip -------------------------
Invoke-Step ("Instalar MS4W en {0}" -f $MS4W_ROOT) {
    if (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe") {
        Write-Log ("MS4W ya esta instalado en {0}, se omite la descompresion." -f $MS4W_ROOT) "WARN"
    } else {
        Assert-Ms4wPackageAvailable -Path $MS4W_ZIP
        Write-Log ("Descomprimiendo {0} --> {1}\" -f $MS4W_ZIP, $INSTALL_DRIVE)

        try {
            Expand-Archive -Path $MS4W_ZIP -DestinationPath "$INSTALL_DRIVE\" -Force -ErrorAction Stop
        } catch {
            throw ("No se pudo descomprimir {0}. Si el archivo fue descargado manualmente, vuelve a descargarlo desde MS4W y verifica que Windows pueda abrirlo. Detalle: {1}" -f $MS4W_ZIP, $_.Exception.Message)
        }

        if (-not (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe")) {
            throw "No se encontro httpd.exe tras la descompresion. Verifica que el ZIP contiene la carpeta ms4w/"
        }
    }
}

# --- PASO 3: Verificar directorios del repo --------------------------------
Invoke-Step ("Verificar {0}" -f $APPS_ROOT) {
    foreach ($dir in @("$APPS_ROOT\mapserv", "$APPS_ROOT\mapcache", "$APPS_ROOT\logs")) {
        if (Test-Path $dir) {
            Write-Log ("OK (del repo): {0}" -f $dir)
        } else {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Log ("Creado: {0}" -f $dir)
        }
    }
}

# --- PASO 4: Actualizar IP y puerto en los archivos .map ------------------
Invoke-Step ("Actualizar IP ({0}:{1}) en archivos .map" -f $SERVER_IP, $SERVER_PORT) {
    foreach ($mapFile in @("$APPS_ROOT\mapserv\wms_kaypacha.map", "$APPS_ROOT\mapserv\wfs_kaypacha.map")) {
        if (Test-Path $mapFile) {
            $c = Get-Content $mapFile -Raw -Encoding UTF8
            $c = $c -replace 'http://[\d\.]+:\d+/servicio/', ("http://{0}:{1}/servicio/" -f $SERVER_IP, $SERVER_PORT)
            $c = $c -replace '(?<=["''\s=])\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?=:\d)', $SERVER_IP
            $c = $c -replace ("(?<=http://{0}:)\d+(?=/)" -f [regex]::Escape($SERVER_IP)), $SERVER_PORT

            Set-Content -Path $mapFile -Value $c -Encoding UTF8
            Write-Log ("Actualizado: {0} (IP={1} Puerto={2})" -f (Split-Path $mapFile -Leaf), $SERVER_IP, $SERVER_PORT)
        } else {
            Write-Log ("No encontrado, se omite: {0}" -f $mapFile) "WARN"
        }
    }
}

# --- PASO 5: Duplicar mapserv.exe en wms y wfs ----------------------------
Invoke-Step "Duplicar mapserv.exe --> cgi-bin\wms y cgi-bin\wfs (sin extension)" {
    $src = "$APACHE_BIN\mapserv.exe"

    if (-not (Test-Path $src)) {
        throw ("mapserv.exe no encontrado en {0}" -f $src)
    }

    Copy-Item -Path $src -Destination "$APACHE_BIN\wms" -Force
    Copy-Item -Path $src -Destination "$APACHE_BIN\wfs" -Force

    Write-Log "mapserv.exe copiado como cgi-bin\wms y cgi-bin\wfs"
}

# --- PASO 6: Configurar httpd.conf ----------------------------------------
Invoke-Step ("Configurar httpd.conf (Listen {0} + mod_headers)" -f $SERVER_PORT) {
    $httpdConf = "$APACHE_CONF\httpd.conf"

    if (-not (Test-Path $httpdConf)) {
        throw ("No se encontro {0}" -f $httpdConf)
    }

    $c = Get-Content $httpdConf -Raw

    if ($c -notmatch ("(?m)^\s*Listen\s+{0}\s*$" -f [regex]::Escape($SERVER_PORT))) {
        if ($c -match "(?m)^\s*Listen\s+80\s*$") {
            $c = $c -replace "(?m)^(\s*Listen\s+80\s*)$", ("`$1`r`nListen {0}" -f $SERVER_PORT)
            Write-Log ("Agregado 'Listen {0}'" -f $SERVER_PORT)
        } else {
            $c += ("`r`nListen {0}`r`n" -f $SERVER_PORT)
            Write-Log ("Agregado 'Listen {0}' al final de httpd.conf" -f $SERVER_PORT)
        }
    } else {
        Write-Log ("'Listen {0}' ya estaba configurado" -f $SERVER_PORT) "WARN"
    }

    if ($c -match "(?m)^#\s*(LoadModule\s+headers_module\s+)") {
        $c = $c -replace "(?m)^#\s*(LoadModule\s+headers_module\s+)", '$1'
        Write-Log "Habilitado mod_headers"
    }

    if ($c -match "(?m)^#\s*Include\s+conf/extra/httpd-vhosts\.conf\s*$") {
        $c = $c -replace "(?m)^#\s*Include\s+conf/extra/httpd-vhosts\.conf\s*$", "Include conf/extra/httpd-vhosts.conf"
        Write-Log "Descomentado Include conf/extra/httpd-vhosts.conf"
    } elseif ($c -notmatch "(?m)^Include\s+conf/extra/httpd-vhosts\.conf\s*$") {
        $c += "`r`n# Virtual hosts`r`nInclude conf/extra/httpd-vhosts.conf`r`n"
        Write-Log "Agregado bloque de Virtual hosts en httpd.conf"
    }

    Set-Content -Path $httpdConf -Value $c -Encoding UTF8
}

# --- PASO 7: Generar VirtualHost ------------------------------------------
Invoke-Step ("Generar VirtualHost <{0}:{1}>" -f $SERVER_IP, $SERVER_PORT) {
    if (-not (Test-Path $APACHE_EXTRA)) {
        New-Item -ItemType Directory -Path $APACHE_EXTRA -Force | Out-Null
    }

    $vhost = @"
# VirtualHost MS4W MapServer/MapCache
# Generado por Install-MS4W-Windows.ps1 | IP: $SERVER_IP | Puerto: $SERVER_PORT

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
    Write-Log ("VirtualHost escrito en {0}\httpd-vhosts.conf" -f $APACHE_EXTRA)
}

# --- PASO 8: Agregar IP al loopback si aplica -----------------------------
Invoke-Step ("Configurar IP {0} en adaptador de red" -f $SERVER_IP) {
    if ($SERVER_IP -match "^127\.") {
        $existing = netsh interface ip show address "Loopback Pseudo-Interface 1" 2>&1

        if ($existing -notmatch [regex]::Escape($SERVER_IP)) {
            netsh interface ip add address "Loopback Pseudo-Interface 1" $SERVER_IP 255.0.0.0 | Out-Null
            Write-Log ("IP {0} agregada al adaptador loopback" -f $SERVER_IP)
        } else {
            Write-Log ("IP {0} ya estaba configurada" -f $SERVER_IP) "WARN"
        }
    } else {
        Write-Log ("IP {0} no es loopback. Asegurate de que este asignada a una interfaz activa." -f $SERVER_IP) "WARN"
    }
}

# --- PASO 9: Registrar e iniciar Apache como servicio ---------------------
Invoke-Step "Registrar e iniciar Apache como servicio Windows" {
    $httpdExe = "$MS4W_ROOT\Apache\bin\httpd.exe"

    if (-not (Test-Path $httpdExe)) {
        throw ("No se encontro Apache httpd.exe en {0}" -f $httpdExe)
    }

    $result = & $httpdExe -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("Error de sintaxis en Apache:`n{0}" -f ($result | Out-String))
    }

    Write-Log "Sintaxis OK"

    $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        & $httpdExe -k install -n $SERVICE_NAME | Out-Null
        Write-Log "Servicio registrado"
    }

    $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        throw ("No se encontro el servicio Windows despues de registrarlo: {0}" -f $SERVICE_NAME)
    }

    if ($svc.Status -eq "Running") {
        Restart-Service -Name $SERVICE_NAME -Force
        Write-Log "Apache reiniciado"
    } else {
        Start-Service -Name $SERVICE_NAME
        Write-Log "Apache iniciado"
    }

    Start-Sleep -Seconds 2
    Write-Log ("Estado del servicio: {0}" -f ((Get-Service -Name $SERVICE_NAME).Status))
}

# --- RESUMEN FINAL --------------------------------------------------------
Write-Host ""
Write-Host "  =============================================================" -ForegroundColor Green
Write-Host "    Instalacion completada exitosamente" -ForegroundColor Green
Write-Host "  =============================================================" -ForegroundColor DarkGreen
Write-Host ("  Servidor : http://{0}:{1}" -f $SERVER_IP, $SERVER_PORT) -ForegroundColor Cyan
Write-Host ""
Write-Host "  WMS:" -ForegroundColor White
Write-Host ("  http://{0}:{1}/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities" -f $SERVER_IP, $SERVER_PORT) -ForegroundColor Cyan
Write-Host ""
Write-Host "  WFS:" -ForegroundColor White
Write-Host ("  http://{0}:{1}/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities" -f $SERVER_IP, $SERVER_PORT) -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Log de instalacion : {0}" -f $LOG_FILE) -ForegroundColor Yellow
Write-Host "  =============================================================" -ForegroundColor Green
Write-Host ""

Write-Log ("Instalacion finalizada. IP={0} Puerto={1}" -f $SERVER_IP, $SERVER_PORT)
