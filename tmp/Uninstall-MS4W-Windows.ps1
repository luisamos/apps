#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Desinstalador de MS4W (Apache MS4W Web Server)
.DESCRIPTION
    - Detiene y elimina el servicio "Apache MS4W Web Server".
    - Elimina C:\ms4w por completo (opcional).
    - Quita alias loopback 127.x.x.x configurados previamente (opcional).
.NOTES
    Ejecutar como Administrador:
    Set-ExecutionPolicy Bypass -Scope Process -Force
    C:\apps\tmp\Uninstall-MS4W.ps1
#>

$MS4W_ROOT    = "C:\ms4w"
$SERVICE_NAME = "Apache MS4W Web Server"
$LOG_FILE     = "C:\apps\logs\uninstall_log.txt"

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

Clear-Host
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor Yellow
Write-Host "        Desinstalador MS4W + Apache Service            " -ForegroundColor Yellow
Write-Host "  =====================================================" -ForegroundColor Yellow
Write-Host ""

$removeMs4w = Read-Host "  Eliminar carpeta C:\ms4w completa? (S/N) [S]"
if ([string]::IsNullOrWhiteSpace($removeMs4w)) { $removeMs4w = "S" }

$removeLoopback = Read-Host "  Quitar una IP loopback 127.x.x.x? (S/N) [N]"
if ([string]::IsNullOrWhiteSpace($removeLoopback)) { $removeLoopback = "N" }

$loopbackIp = $null
if ($removeLoopback -match "^[Ss]$") {
    $loopbackIp = Read-Host "  IP loopback a quitar (ej: 127.0.0.2)"
    if ($loopbackIp -notmatch '^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        throw "IP loopback invalida: $loopbackIp"
    }
}

Invoke-Step "Detener y eliminar servicio $SERVICE_NAME" {
    $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "Servicio no encontrado, se omite." "WARN"
    } else {
        if ($svc.Status -eq "Running") {
            Stop-Service -Name $SERVICE_NAME -Force
            Write-Log "Servicio detenido"
        }

        $httpdExe = "$MS4W_ROOT\Apache\bin\httpd.exe"
        if (Test-Path $httpdExe) {
            & $httpdExe -k uninstall -n $SERVICE_NAME | Out-Null
            Write-Log "Servicio eliminado con httpd.exe"
        } else {
            sc.exe delete "$SERVICE_NAME" | Out-Null
            Write-Log "Servicio eliminado con sc.exe"
        }
    }
}

Invoke-Step "Eliminar carpeta MS4W" {
    if ($removeMs4w -match "^[Ss]$") {
        if (Test-Path $MS4W_ROOT) {
            Remove-Item -Path $MS4W_ROOT -Recurse -Force
            Write-Log "Carpeta eliminada: $MS4W_ROOT"
        } else {
            Write-Log "No existe $MS4W_ROOT, se omite." "WARN"
        }
    } else {
        Write-Log "Se conserva $MS4W_ROOT por eleccion del usuario." "WARN"
    }
}

Invoke-Step "Eliminar IP loopback" {
    if ($loopbackIp) {
        netsh interface ip delete address "Loopback Pseudo-Interface 1" $loopbackIp | Out-Null
        Write-Log "IP loopback eliminada: $loopbackIp"
    } else {
        Write-Log "No se solicito eliminar IP loopback." "WARN"
    }
}

Write-Host ""
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host "              Desinstalacion finalizada                " -ForegroundColor Green
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Log: $LOG_FILE" -ForegroundColor Yellow
Write-Host ""
Write-Log "Desinstalacion finalizada"