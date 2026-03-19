# Instalación en Ubuntu — Apache2 + MapServer / MapCache

## Requisitos previos

- Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS
- Acceso a internet para instalar paquetes
- Permisos de **sudo**

---

## Paso 1 — Instalar Git y clonar el repositorio en `/apps`

```bash
# Instalar Git si no está disponible
sudo apt update
sudo apt install -y git

# Clonar el repositorio directamente en /apps (ruta obligatoria)
sudo git clone https://github.com/luisamos/apps.git /apps
```

> **¿Por qué `/apps`?** Las rutas de Apache, los archivos `.map` y los logs
> apuntan a `/apps`. Clonar en otra ubicación requeriría editar manualmente
> todas esas referencias.

Después de clonar, la estructura en disco queda así:

```
/apps/
├── docs/
│   ├── INSTALL_WINDOWS.md
│   └── INSTALL_UBUNTU.md    ← este archivo
├── logs/                     ← logs de Apache (se escriben al iniciar el servicio)
├── mapcache/                 ← configuración de MapCache
├── mapserv/
│   ├── wms_kaypacha.map
│   └── wfs_kaypacha.map
└── tmp/
    ├── Install-MS4W-Windows.ps1    ← instalador Windows
    ├── Install-Mapserv-Ubuntu.sh      ← instalador Ubuntu
    └── Uninstall-MS4W-Windows.sh    ← desinstalador Windows
    └── Uninstall-Mapserv-Ubuntu.sh    ← desinstalador Ubuntu
```

Verificar que el clone fue exitoso:

```bash
ls /apps/mapserv/
# Debe mostrar: wms_kaypacha.map  wfs_kaypacha.map
```

---

## Paso 2 — Instalar dependencias con `apt`

```bash
sudo apt update && sudo apt upgrade -y

# Apache2
sudo apt install -y apache2

# MapServer (incluye el binario CGI /usr/lib/cgi-bin/mapserv)
sudo apt install -y cgi-mapserver mapserver-bin

# MapCache (módulo de Apache)
sudo apt install -y libapache2-mod-mapcache

# Herramientas adicionales de MapServer
sudo apt install -y python3-mapscript

# Habilitar módulos de Apache necesarios
sudo a2enmod cgi headers alias env
```

> **Ubuntu 24.04:** si `libapache2-mod-mapcache` no aparece en los repositorios
> oficiales, agregarlo desde UbuntuGIS:
>
> ```bash
> sudo add-apt-repository ppa:ubuntugis/ppa
> sudo apt update
> sudo apt install -y libapache2-mod-mapcache
> ```

---

## Paso 3 — Asignar permisos a `/apps`

Los archivos ya están en `/apps` gracias al `git clone`. Solo hay que dar
permisos de lectura al usuario de Apache (`www-data`):

```bash
# Dar acceso de lectura a mapserv y mapcache
sudo chown -R www-data:www-data /apps/mapserv /apps/mapcache /apps/logs
sudo chmod -R 755 /apps/mapserv /apps/mapcache

# Dar acceso de escritura a logs (Apache necesita escribir aquí)
sudo chmod -R 775 /apps/logs
```

---

## Paso 4 — Verificar la ruta del binario `mapserv`

En Ubuntu, `mapserv` se instala en `/usr/lib/cgi-bin/mapserv`.
Verificar que existe:

```bash
ls -la /usr/lib/cgi-bin/mapserv
```

Si no aparece, crear un enlace simbólico:

```bash
sudo ln -s /usr/bin/mapserv /usr/lib/cgi-bin/mapserv
sudo chmod +x /usr/lib/cgi-bin/mapserv
```

---

## Paso 4.1 — Copiar `mapserv` como `wms` y `wfs` (sin extensión)

```bash
sudo cp -f /usr/lib/cgi-bin/mapserv /usr/lib/cgi-bin/wms
sudo cp -f /usr/lib/cgi-bin/mapserv /usr/lib/cgi-bin/wfs
sudo chmod +x /usr/lib/cgi-bin/wms /usr/lib/cgi-bin/wfs
```

---

## Paso 5 — Actualizar IP y puerto en los archivos `.map`

Reemplaza `<IP>` y `<PUERTO>` con los valores reales de tu servidor
(por ejemplo `192.168.1.50` y `8081`):

```bash
# Definir variables (editar estos valores)
IP="192.168.1.50"
PUERTO="8081"

# Reemplazar en wms_kaypacha.map
sudo sed -i "s|http://[0-9.]*:[0-9]*/servicio/|http://${IP}:${PUERTO}/servicio/|g" \
    /apps/mapserv/wms_kaypacha.map

# Reemplazar en wfs_kaypacha.map
sudo sed -i "s|http://[0-9.]*:[0-9]*/servicio/|http://${IP}:${PUERTO}/servicio/|g" \
    /apps/mapserv/wfs_kaypacha.map
```

Verificar que el reemplazo fue correcto:

```bash
grep -i "onlineresource\|http" /apps/mapserv/wms_kaypacha.map
grep -i "onlineresource\|http" /apps/mapserv/wfs_kaypacha.map
```

---

## Paso 6 — Configurar el VirtualHost en Apache2 (wms/wfs sin extensión)

Crear el archivo de configuración del sitio (reemplazar `<IP>` y `<PUERTO>`):

```bash
sudo nano /etc/apache2/sites-available/mapserver.conf
```

Pegar el siguiente contenido:

```apache
Listen <PUERTO>

<VirtualHost <IP>:<PUERTO>>
    ServerAdmin luisamos7@gmail.com
    ServerName <IP>
    ServerAlias <IP>
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

    SetEnvIf Request_URI "/servicio/mapserv" MS_MAPFILE=/apps/mapserv/wms_kaypacha.map
    SetEnvIf Request_URI "/servicio/wfs"     MS_MAPFILE=/apps/mapserv/wfs_kaypacha.map
</VirtualHost>
```

> **Nota:** además de `mapserv`, crea copias sin extensión `wms` y `wfs`
> en `/usr/lib/cgi-bin/` para mantener el mismo patrón operativo que en Windows.

---

## Paso 7 — Habilitar el sitio y reiniciar Apache

```bash
# Habilitar el nuevo sitio
sudo a2ensite mapserver.conf

# Deshabilitar el sitio por defecto si no se necesita
sudo a2dissite 000-default.conf

# Verificar que la sintaxis de configuración es correcta
sudo apache2ctl configtest
# Debe responder: Syntax OK

# Reiniciar Apache
sudo systemctl restart apache2

# Verificar que Apache está corriendo
sudo systemctl status apache2
```

---

## Paso 8 — Verificar los servicios

### WMS

```
http://<IP>:<PUERTO>/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities
```

### WFS

```
http://<IP>:<PUERTO>/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities
```

Prueba rápida desde el mismo servidor:

```bash
curl -s "http://<IP>:<PUERTO>/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities" \
  | grep -i "WMS_Capabilities\|ServiceException" | head -5
```

---

## Resultado final en disco

```
/
├── usr/lib/cgi-bin/
│   ├── mapserv              ← binario MapServer instalado por apt
│   ├── wms                  ← copia CGI sin extensión
│   └── wfs                  ← copia CGI sin extensión
└── apps/                    ← clonado desde https://github.com/luisamos/apps.git
    ├── docs/
    │   ├── INSTALL_WINDOWS.md
    │   └── INSTALL_UBUNTU.md
    ├── logs/
    │   ├── error_.log    ← generado por Apache al primer request
    │   └── custom_kaypacha.log
    ├── mapcache/
    ├── mapserv/
    │   ├── wms_kaypacha.map      ← IP y puerto actualizados en Paso 5
    │   └── wfs_kaypacha.map      ← IP y puerto actualizados en Paso 5
    └── tmp/
```

---

## Instalación automatizada en Ubuntu

También puedes ejecutar el instalador automatizado:

```bash
chmod +x /apps/tmp/Install-Mapserv-Ubuntu.sh
sudo /apps/tmp/Install-Mapserv-Ubuntu.sh
```

Este script realiza automáticamente:

- Instalación de dependencias Apache2/MapServer/MapCache.
- Actualización de IP/puerto en archivos `.map`.
- Copia de `mapserv` como `wms` y `wfs` sin extensión en `/usr/lib/cgi-bin/`.
- Creación/habilitación de `mapserver.conf` y reinicio de Apache.

## Desinstalación en Ubuntu

```bash
chmod +x /apps/tmp/Uninstall-Mapserv-Ubuntu.sh
sudo /apps/tmp/Uninstall-Mapserv-Ubuntu.sh
```

El desinstalador elimina `mapserver.conf` y, opcionalmente, los CGI `wms` y `wfs`.

---

## Diferencias clave respecto a la instalación en Windows

| Aspecto                  | Windows (MS4W)                                            | Ubuntu (apt)                                                                |
| ------------------------ | --------------------------------------------------------- | --------------------------------------------------------------------------- |
| Instalación del servidor | Script descarga y descomprime `ms4w_5.0.0.zip`            | `sudo apt install apache2 cgi-mapserver`                                    |
| Binario MapServer        | `C:\ms4w\Apache\cgi-bin\mapserv.exe`                      | `/usr/lib/cgi-bin/mapserv`                                                  |
| Binarios WMS/WFS         | Dos copias: `cgi-bin\wms` y `cgi-bin\wfs` (sin extensión) | Dos copias: `/usr/lib/cgi-bin/wms` y `/usr/lib/cgi-bin/wfs` (sin extensión) |
| Usuario de Apache        | Cuenta de servicio de Windows                             | `www-data`                                                                  |
| VirtualHost              | `C:\ms4w\Apache\conf\extra\httpd-vhosts.conf`             | `/etc/apache2/sites-available/mapserver.conf`                               |
| Logs                     | `C:\apps\logs\`                                           | `/apps/logs/`                                                               |
| Automatización           | Script PowerShell `Install-MS4W-Windows.ps1`              | Script Bash `Install-Mapserv-Ubuntu.sh` o pasos manuales                    |
| Clonar repo en           | `C:\apps`                                                 | `/apps`                                                                     |

---

## Solución de problemas

| Problema                           | Causa probable                         | Solución                                                 |
| ---------------------------------- | -------------------------------------- | -------------------------------------------------------- |
| Apache no inicia                   | Puerto ocupado                         | `sudo ss -tlnp \| grep <puerto>` y terminar el proceso   |
| Error 500 en WMS/WFS               | `mapserv` sin permisos de ejecución    | `sudo chmod +x /usr/lib/cgi-bin/mapserv`                 |
| Error 403 Forbidden                | `www-data` sin acceso a `/apps`        | `sudo chown -R www-data:www-data /apps`                  |
| `mod_cgi` no habilitado            | No se ejecutó `a2enmod cgi`            | `sudo a2enmod cgi && sudo systemctl restart apache2`     |
| CORS bloqueado                     | `mod_headers` no habilitado            | `sudo a2enmod headers && sudo systemctl restart apache2` |
| Logs vacíos                        | `/apps/logs` sin permisos de escritura | `sudo chmod 775 /apps/logs`                              |
| `git clone` falla en `/apps`       | Directorio ya existe                   | `sudo rm -rf /apps` y volver a clonar                    |
| `mapserv` no encontrado tras `apt` | Paquete instalado en otra ruta         | `which mapserv` para encontrar la ruta correcta          |
