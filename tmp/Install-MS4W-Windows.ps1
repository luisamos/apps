#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instalador automatizado de MS4W con MapServer / MapCache
.DESCRIPTION
    PREREQUISITO: clonar el repositorio en C:\apps
        git clone https://github.com/luisamos/apps.git C:\apps

    Luego este script hace todo lo demas:
    - Solicita la IP y el puerto donde correra MS4W (con valores por defecto)
    - Descarga ms4w_5.0.0.zip desde ms4w.com si no existe en C:\apps\docs\
    - Descomprime C:\apps\docs\ms4w_5.0.0.zip en C:\ms4w
    - Verifica que C:\apps\mapserv, mapcache y logs existan (vienen del repo)
    - Actualiza la IP y el puerto dentro de wms_kaypacha.map y wfs_kaypacha.map
    - Duplica mapserv.exe en cgi-bin\wms y cgi-bin\wfs
    - Agrega Listen <puerto> al httpd.conf y habilita mod_headers
    - Genera httpd-vhosts.conf con la IP y puerto indicados
    - Agrega la IP al adaptador loopback si es 127.x.x.x
    - Registra Apache como servicio de Windows y lo arranca
.NOTES
    Ejecutar como Administrador:
    Set-ExecutionPolicy Bypass -Scope Process -Force
    C:\apps\tmp\Install-MS4W-Windows.ps1
#>

# --- RUTAS Y URLS -------------------------------------------------------
$MS4W_ROOT    = "C:\ms4w"
$APPS_ROOT    = "C:\apps"
$APACHE_BIN   = "$MS4W_ROOT\Apache\cgi-bin"
$APACHE_CONF  = "$MS4W_ROOT\Apache\conf"
$APACHE_EXTRA = "$MS4W_ROOT\Apache\conf\extra"
$MS4W_ZIP     = "$APPS_ROOT\docs\ms4w_5.0.0.zip"
$MS4W_URL     = "https://ms4w.com/release/ms4w_5.0.0.zip"
$SERVICE_NAME = "Apache MS4W Web Server"
$LOG_FILE     = "$APPS_ROOT\logs\install_log.txt"

# --- FUNCIONES AUXILIARES -----------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "ERROR" { "Red" } "WARN" { "Yellow" } default { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
    $logDir = Split-Path $LOG_FILE
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LOG_FILE -Value $line
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

# --- PANTALLA DE BIENVENIDA ----------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host "       Instalador MS4W + MapServer / MapCache          " -ForegroundColor Green
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host ""
Write-Log "Inicio de instalacion"

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

    if (Test-Path $MS4W_ZIP) {
        $sizeMB = [math]::Round((Get-Item $MS4W_ZIP).Length / 1MB, 1)
        Write-Log "ms4w_5.0.0.zip ya existe ($sizeMB MB), se omite la descarga." "WARN"
    } else {
        Write-Log "Descargando desde $MS4W_URL"
        Write-Host "  Destino: $MS4W_ZIP" -ForegroundColor DarkGray
        Write-Host "  Esto puede tardar varios minutos segun la velocidad de internet..." -ForegroundColor DarkGray

        try {
            # WebClient con barra de progreso en consola
            $wc = New-Object System.Net.WebClient
            $wc.add_DownloadProgressChanged({
                param($s, $e)
                if ($e.TotalBytesToReceive -gt 0) {
                    $pct   = [math]::Round(($e.BytesReceived / $e.TotalBytesToReceive) * 100, 1)
                    $recvMB  = [math]::Round($e.BytesReceived / 1MB, 1)
                    $totalMB = [math]::Round($e.TotalBytesToReceive / 1MB, 1)
                    Write-Host ("`r  [{0,-30}] {1}% — {2} MB / {3} MB  " -f `
                        ("=" * [int]($pct / 100 * 30)), $pct, $recvMB, $totalMB) `
                        -NoNewline -ForegroundColor Cyan
                }
            })
            $task = $wc.DownloadFileTaskAsync($MS4W_URL, $MS4W_ZIP)
            while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 300 }
            Write-Host ""
            if ($task.IsFaulted) { throw $task.Exception.InnerException }

        } catch {
            Write-Host ""
            Write-Log "Reintentando con Invoke-WebRequest..." "WARN"
            Invoke-WebRequest -Uri $MS4W_URL -OutFile $MS4W_ZIP -UseBasicParsing
        }

        if (-not (Test-Path $MS4W_ZIP)) {
            throw "La descarga fallo. Verifica la conexion o descarga manualmente desde:`n  $MS4W_URL`ny coloca el archivo en $MS4W_ZIP"
        }

        $sizeMB = [math]::Round((Get-Item $MS4W_ZIP).Length / 1MB, 1)
        Write-Log "Descarga completada: $MS4W_ZIP ($sizeMB MB)"
    }
}

# --- PASO 2: Instalar MS4W descomprimiendo el zip -------------------------
Invoke-Step "Instalar MS4W en C:\ms4w" {
    if (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe") {
        Write-Log "MS4W ya esta instalado en $MS4W_ROOT, se omite la descompresion." "WARN"
    } else {
        Write-Log "Descomprimiendo $MS4W_ZIP  -->  C:\"
        Expand-Archive -Path $MS4W_ZIP -DestinationPath "C:\" -Force
        Write-Log "MS4W descomprimido en $MS4W_ROOT"
        if (-not (Test-Path "$MS4W_ROOT\Apache\bin\httpd.exe")) {
            throw "No se encontro httpd.exe tras la descompresion. Verifica que el zip contiene la carpeta ms4w/"
        }
    }
}

# --- PASO 3: Verificar directorios del repo --------------------------------
Invoke-Step "Verificar C:\apps" {
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
    ErrorLog "/apps/logs/error_kaypacha.log"
    CustomLog "/apps/logs/custom_kaypacha.log" common

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

    SetEnvIf Request_URI "/servicio/wms" MS_MAPFILE=/apps/mapserv/wms_kaypacha.map
    SetEnvIf Request_URI "/servicio/wfs" MS_MAPFILE=/apps/mapserv/wfs_kaypacha.map
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
