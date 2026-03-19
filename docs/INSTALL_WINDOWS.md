# Instalación en Windows — MS4W + MapServer / MapCache

## Requisitos previos

- Windows 10 / Windows Server 2016 o superior
- [Git para Windows](https://git-scm.com/download/win) instalado
- PowerShell 5.1 o superior
- Permisos de **Administrador**

---

## Paso 1 — Clonar el repositorio en `C:\apps`

El repositorio **debe clonarse exactamente en `C:\apps`** porque todas las rutas
de Apache, los archivos `.map` y los logs apuntan a esa ubicación.

Abrir **PowerShell como Administrador** y ejecutar:

```powershell
git clone https://github.com/luisamos/apps.git C:\apps
```

Después de clonar, la estructura en disco queda así:

```
C:\apps\
├── docs\
│   ├── ms4w_5.0.0.zip          ← instalador de MS4W incluido en el repo
│   ├── INSTALL_WINDOWS.md      ← este archivo
│   └── INSTALL_UBUNTU.md
├── logs\                        ← logs de Apache (se generan al correr)
├── mapcache\                    ← configuración de MapCache
├── mapserv\
│   ├── wms_kaypacha.map
│   └── wfs_kaypacha.map
└── tmp\
    ├── Install-MS4W-Windows.ps1    ← instalador Windows
    ├── Install-Mapserv-Ubuntu.sh      ← instalador Ubuntu
    └── Uninstall-MS4W-Windows.sh    ← desinstalador Windows
    └── Uninstall-Mapserv-Ubuntu.sh    ← desinstalador Ubuntu
```

---

## Paso 2 — Ejecutar el script instalador

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\apps\tmp\Install-MS4W-Windows.ps1
```

El script te pedirá dos datos al inicio:

```
  IP del servidor   [127.0.0.2]: _
  Puerto del servidor    [8081]: _
```

Presiona **Enter** para usar los valores por defecto, o ingresa los tuyos.
El script valida que la IP tenga formato correcto y que el puerto sea un número entre 1 y 65535.

Una vez confirmada la configuración, el script ejecuta automáticamente los pasos del 3 al 10 descritos abajo.

---

## Lo que hace el script (pasos 3 al 10)

**Paso 3 — Descargar e instalar MS4W**
El script detecta si `C:\apps\docs\ms4w_5.0.0.zip` existe. Si no existe, lo descarga
automáticamente desde `https://ms4w.com/release/ms4w_5.0.0.zip` mostrando una barra de
progreso en consola. Una vez descargado, lo descomprime en `C:\ms4w`.
Si MS4W ya estaba instalado, omite ambos pasos.

**Paso 4 — Verificar directorios**
Confirma que `C:\apps\mapserv`, `C:\apps\mapcache` y `C:\apps\logs` existen
(vienen del `git clone`). No crea subcarpetas CGI adicionales; usa binarios en `cgi-bin`.

**Paso 5 — Actualizar IP y puerto en los archivos `.map`**
Abre `wms_kaypacha.map` y `wfs_kaypacha.map` en `C:\apps\mapserv\` y reemplaza
la IP y el puerto en todas las directivas (`ows_onlineresource`, `wms_onlineresource`, URLs, etc.)
con los valores que ingresaste.

**Paso 6 — Duplicar `mapserv.exe`**
Copia `C:\ms4w\Apache\cgi-bin\mapserv.exe` a:

- `C:\ms4w\Apache\cgi-bin\wms`
- `C:\ms4w\Apache\cgi-bin\wfs`

**Paso 7 — Configurar `httpd.conf`**
Agrega `Listen <puerto>` junto al `Listen 80`, habilita `mod_headers` y deja habilitado `Include conf/extra/httpd-vhosts.conf` (descomentándolo si existe comentado).

**Paso 8 — Generar el VirtualHost**
Escribe `C:\ms4w\Apache\conf\extra\httpd-vhosts.conf` con la IP y puerto indicados:

```apache
<VirtualHost <IP>:<PUERTO>>
    ServerAdmin luisamos7@gmail.com
    ServerName <IP>
    ServerAlias <IP>
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
```

**Paso 9 — Alias de IP en loopback**
Si la IP empieza con `127.` la agrega al adaptador loopback de Windows:

```powershell
netsh interface ip add address "Loopback Pseudo-Interface 1" <IP> 255.0.0.0
```

**Paso 10 — Iniciar Apache**
Verifica la sintaxis de configuración (`httpd -t`), registra Apache como
servicio de Windows con nombre `Apache MS4W Web Server` y lo inicia. El log de instalación queda en `C:\apps\logs\install_log.txt`.

---

## Resultado final en disco

```
C:\
├── ms4w\
│   └── Apache\
│       ├── bin\httpd.exe
│       ├── cgi-bin\
│       │   ├── mapserv.exe             ← original
│       │   ├── wms                     ← copia para WMS (sin extensión)
│       │   └── wfs                     ← copia para WFS (sin extensión)
│       └── conf\
│           ├── httpd.conf              ← Listen <puerto> agregado
│           └── extra\
│               └── httpd-vhosts.conf   ← generado con tu IP y puerto
└── apps\                               ← clonado desde GitHub
    ├── docs\
    │   └── ms4w_5.0.0.zip
    ├── logs\
    │   ├── error_kaypacha.log
    │   ├── custom_kaypacha.log
    │   └── install_log.txt
    ├── mapcache\
    ├── mapserv\
    │   ├── wms_kaypacha.map                 ← IP y puerto actualizados
    │   └── wfs_kaypacha.map                 ← IP y puerto actualizados
    └── tmp\
        ├── Install-MS4W-Windows.ps1    ← instalador Windows
        ├── Install-Mapserv-Ubuntu.sh      ← instalador Ubuntu
        └── Uninstall-MS4W-Windows.sh    ← desinstalador Windows
        └── Uninstall-Mapserv-Ubuntu.sh    ← desinstalador Ubuntu
```

---

## Verificar los servicios

### WMS

```
http://<IP>:<PUERTO>/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities
```

### WFS

```
http://<IP>:<PUERTO>/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities
```

Ejemplo con valores por defecto:

```
http://127.0.0.2:8081/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities
http://127.0.0.2:8081/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities
```

---

## Solución de problemas

| Problema                     | Causa probable              | Solución                                                      |
| ---------------------------- | --------------------------- | ------------------------------------------------------------- |
| Apache no inicia             | Puerto ocupado              | `netstat -ano \| findstr :<puerto>` y terminar el proceso     |
| Error 500 en WMS/WFS         | Ruta del `.map` incorrecta  | Verificar `MS_MAPFILE` en el VirtualHost                      |
| `mapserv.exe` no ejecuta     | CGI no configurado          | Verificar `ScriptAlias` y que `mod_cgi` esté habilitado       |
| CORS bloqueado               | `mod_headers` deshabilitado | El script lo habilita automáticamente; reiniciar Apache       |
| IP no responde               | Alias de loopback no creado | Ejecutar manualmente el comando `netsh` del Paso 9            |
| Error al descomprimir `.zip` | PowerShell < 5.1            | Actualizar PowerShell o descomprimir manualmente en `C:\ms4w` |

---

## Desinstalar MS4W

Para revertir la instalación en Windows, ejecutar como Administrador:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\apps\tmp\Uninstall-MS4W-Windows.ps1
```

El desinstalador permite:

- Detener y eliminar el servicio `Apache MS4W Web Server`.
- Eliminar `C:\ms4w` (opcional).
- Quitar la IP loopback `127.x.x.x` configurada durante instalación (opcional).

Guarda su bitácora en: `C:\apps\logs\uninstall_log.txt`.
