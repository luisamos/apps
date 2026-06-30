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
│   ├── ms4w_5.2.0.zip          ← instalador de MS4W incluido en el repo
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
```

```powershell
C:\apps\tmp\Install-MS4W-Windows.ps1
```

El script te pedirá cinco datos al inicio:

```
  IP del servidor                                  [127.0.0.2]: _
  Puerto del servidor                                   [8081]: _
  SRID/EPSG de las capas (solo el numero, p.ej. 32719) [32719]: _
  EXTENT minx miny maxx maxy (unidades del SRID)    [<extent>]: _
  Ruta del raster de la ortofoto (ECW/GeoTIFF)      [<raster>]: _
```

Presiona **Enter** para usar los valores por defecto, o ingresa los tuyos.

- La **IP** se valida con formato `n.n.n.n` y el **puerto** debe ser un número entre 1 y 65535.
- El **SRID/EPSG** es el código de referencia espacial de las capas catastrales de
  `/mapserv/capas/kaypacha` (solo el número, p.ej. `32719` para UTM 19S o `4326` para geográficas).
- El **EXTENT** define el área sobre la cual se publicarán los servicios WMS y WFS, expresado en las
  unidades del SRID indicado, con el formato `minx miny maxx maxy` (4 números separados por espacios).
- La **ruta del raster de la ortofoto** es el archivo `ECW`/`GeoTIFF` que usa la capa `ortofoto`
  (directiva `DATA` de `ortofoto.map`), p.ej. `C:/apps/mapserv/archivos/raster/machupicchu.ecw`.
  Debe terminar en `.ecw`, `.tif`, `.tiff`, `.jp2`, `.img` o `.vrt`.

Los valores por defecto de **SRID**, **EXTENT** y **ruta del raster** se detectan automáticamente
leyéndolos de `mapserv\capas\kaypacha\wms\lote.map` y `ortofoto.map` (ajustando la unidad de disco),
por lo que normalmente basta con presionar **Enter**.

Una vez confirmada la configuración, el script ejecuta automáticamente los pasos del 3 al 12 descritos abajo.

---

## Lo que hace el script (pasos 3 al 12)

**Paso 3 — Descargar e instalar MS4W**
El script detecta si `<UNIDAD>:\apps\docs\ms4w_5.2.0.zip` existe y es un ZIP válido. Si ya existe,
lo usa directamente y no intenta descargarlo. Si no existe, lo descarga automáticamente desde el sitio
oficial `https://ms4w.com/release/ms4w_5.2.0.zip`; si queda incompleto o corrupto, reintenta con otro
método de descarga antes de descomprimirlo en `<UNIDAD>:\ms4w`.
Si MS4W ya estaba instalado, omite la descompresión.

**Paso 4 — Verificar directorios**
Confirma que `C:\apps\mapserv`, `C:\apps\mapcache` y `C:\apps\logs` existen
(vienen del `git clone`). No crea subcarpetas CGI adicionales; usa binarios en `cgi-bin`.

**Paso 5 — Actualizar IP y puerto en los archivos `.map`**
Abre `wms_kaypacha.map` y `wfs_kaypacha.map` en `C:\apps\mapserv\` y reemplaza
la IP y el puerto en todas las directivas (`ows_onlineresource`, `wms_onlineresource`, URLs, etc.)
con los valores que ingresaste.

**Paso 6 — Configurar SRID y EXTENT en los archivos `.map`**
Con el SRID y el EXTENT indicados, el script reconfigura automáticamente la georreferenciación de
los servicios:

- **Capas de `C:\apps\mapserv\capas\kaypacha\`** (subcarpetas `wms\` y `wfs\`): en cada `.map`
  actualiza el SRID en la consulta de datos (`using srid=<SRID>`), la proyección
  (`init=epsg:<SRID>`), el SRS anunciado (`"wms_srs"` / `"wfs_srs"` → `EPSG:<SRID>`) y el área
  publicada (`"wms_extent" "minx miny maxx maxy"`).
- **Archivos principales `wms_kaypacha.map` y `wfs_kaypacha.map`**: actualiza el `EXTENT` a nivel
  `MAP` (sin tocar el `EXTENT` del bloque `REFERENCE`), la `PROJECTION` (`init=epsg:<SRID>`) y el
  SRS anunciado en los metadatos del servicio.

> El reemplazo respeta las capas que usan deliberadamente otro SRID (por ejemplo, las capas de
> reportes en `EPSG:4326`): solo se sustituye el SRID catastral anterior por el nuevo, no los
> demás códigos EPSG. Por eso el paso es **idempotente** y puede reejecutarse sin dañar la
> configuración.

Además, actualiza la directiva `DATA` de `capas\kaypacha\wms\ortofoto.map` con la **ruta del raster
de la ortofoto** que indicaste (p.ej. `C:/apps/mapserv/archivos/raster/machupicchu.ecw`), ajustando la
unidad de disco a la de instalación.

**Paso 7 — Duplicar `mapserv.exe`**
Copia `C:\ms4w\Apache\cgi-bin\mapserv.exe` a:

- `C:\ms4w\Apache\cgi-bin\wms`
- `C:\ms4w\Apache\cgi-bin\wfs`

**Paso 8 — Configurar `httpd.conf`**
Agrega `Listen <puerto>` junto al `Listen 80`, habilita `mod_headers` y deja habilitado `Include conf/extra/httpd-vhosts.conf` (descomentándolo si existe comentado).

**Paso 9 — Generar el VirtualHost**
Escribe `C:\ms4w\Apache\conf\extra\httpd-vhosts.conf` con la IP y puerto indicados. Incluye el
`DocumentRoot` del visor (`C:\apps\www\visor-kaypacha`, que se crea si no existe), la variable
`GDAL_DRIVER_PATH` (necesaria para leer rásteres `ECW`) y el alias de **MapCache**:

```apache
<VirtualHost <IP>:<PUERTO>>
    ServerAdmin luisamos7@gmail.com
    ServerName <IP>
    ServerAlias <IP>
    DocumentRoot "C:/apps/www/visor-kaypacha"
    ErrorLog "/apps/logs/error_kaypacha.log"
    CustomLog "/apps/logs/custom_kaypacha.log" common
    <Directory "C:/apps/www/visor-kaypacha">
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
    SetEnvIf Request_URI "/servicio/wms" MS_MAPFILE=/apps/mapserv/wms_kaypacha.map
    SetEnvIf Request_URI "/servicio/wfs" MS_MAPFILE=/apps/mapserv/wfs_kaypacha.map
    SetEnv GDAL_DRIVER_PATH "C:/ms4w/gdalplugins"
    <IfModule mapcache_module>
        <Directory "C:/apps/mapcache/">
            AllowOverride None
            Options None
            Require all granted
        </Directory>
        MapCacheAlias /mapcache "C:/apps/mapcache/mapcache.xml"
    </IfModule>
</VirtualHost>
```

**Paso 10 — Configurar y habilitar MapCache**
Ajusta `C:\apps\mapcache\mapcache.xml` según los datos indicados:

- Reemplaza la unidad de disco en las rutas (`<base>`, `<template>`, `<dbfile>`, `<lock_dir>`)
  por la unidad de instalación.
- Apunta la fuente WMS (`<source>` → `<url>`) a la IP y el puerto indicados
  (`http://<IP>:<PUERTO>/servicio/wms?`; si el puerto es `80` se omite del host).

El `tileset` `ortofoto` queda servido en `http://<IP>:<PUERTO>/mapcache` (WMS, WMTS, TMS, KML,
GMaps y VE habilitados).

**Paso 11 — Alias de IP en loopback**
Si la IP empieza con `127.` la agrega al adaptador loopback de Windows:

```powershell
netsh interface ip add address "Loopback Pseudo-Interface 1" <IP> 255.0.0.0
```

**Paso 12 — Iniciar Apache**
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
    │   └── ms4w_5.2.0.zip
    ├── logs\
    │   ├── error_kaypacha.log
    │   ├── custom_kaypacha.log
    │   └── install_log.txt
    ├── mapcache\
    │   └── mapcache.xml                     ← IP/puerto y unidad actualizados (MapCache)
    ├── mapserv\
    │   ├── capas\
    │   │   └── kaypacha\                     ← SRID y EXTENT actualizados (wms\ y wfs\)
    │   │       └── wms\ortofoto.map          ← ruta DATA del raster actualizada
    │   ├── wms_kaypacha.map                 ← IP, puerto, SRID y EXTENT actualizados
    │   └── wfs_kaypacha.map                 ← IP, puerto, SRID y EXTENT actualizados
    ├── www\
    │   └── visor-kaypacha\                  ← DocumentRoot del visor (se crea si no existe)
    └── tmp\
        ├── Install-MS4W-Windows.ps1    ← instalador Windows
        ├── Install-Mapserv-Ubuntu.sh      ← instalador Ubuntu
        └── Uninstall-MS4W-Windows.sh    ← desinstalador Windows
        └── Uninstall-Mapserv-Ubuntu.sh    ← desinstalador Ubuntu
```

> **MapCache** queda disponible en `http://<IP>:<PUERTO>/mapcache` y la lectura de rásteres `ECW`
> se habilita mediante `GDAL_DRIVER_PATH` (`C:\ms4w\gdalplugins`) declarado en el VirtualHost.

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
| Capas fuera del área / vacías | SRID o EXTENT incorrectos  | Reejecutar el instalador e ingresar el SRID y el EXTENT correctos (el paso es idempotente) |
| Ortofoto `ECW` no se ve        | Driver ECW no encontrado   | Verificar `SetEnv GDAL_DRIVER_PATH` en el VirtualHost y que el `.ecw` exista en la ruta `DATA` de `ortofoto.map` |
| `/mapcache` no responde        | URL/unidad mal en `mapcache.xml` | Revisar `<url>` (IP/puerto) y las rutas de `<base>`/`<lock_dir>` en `C:\apps\mapcache\mapcache.xml` |

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
