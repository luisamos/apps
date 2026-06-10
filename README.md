# apps — MapServer / MapCache

Repositorio de configuración para servicios WMS y WFS basados en MapServer,
con soporte para Windows (MS4W) y Ubuntu (Apache2 + apt).

## Estructura

```
apps/
├── docs/
│   ├── ms4w_5.2.0.zip          ← instalador MS4W para Windows
│   ├── INSTALL_WINDOWS.md      ← manual de instalación en Windows
│   └── INSTALL_UBUNTU.md       ← manual de instalación en Ubuntu
├── logs/                       ← logs de Apache
├── mapcache/                   ← configuración de MapCache
├── mapserv/
│   ├── wms_kaypacha.map        ← mapa de configuración WMS
│   └── wfs_kaypacha.map        ← mapa de configuración WFS
└── tmp/
    ├── Install-MS4W-Windows.ps1        ← instalador Windows
    ├── install_Mapserv-Ubuntu.sh       ← instalador Ubuntu
    ├── Uninstall-MS4W-Windows.ps1      ← desinstalador Windows
    └── Uninstall-Mapserv-Ubuntu.sh     ← desinstalador Ubuntu
```

---

## Manuales disponibles

| Sistema operativo | Instalación                                              | Desinstalación                                                               |
| ----------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Windows           | [Manual de instalación Windows](docs/INSTALL_WINDOWS.md) | Script: [`tmp/Uninstall-MS4W-Windows.ps1`](tmp/Uninstall-MS4W-Windows.ps1)   |
| Ubuntu / Linux    | [Manual de instalación Ubuntu](docs/INSTALL_UBUNTU.md)   | Script: [`tmp/Uninstall-Mapserv-Ubuntu.sh`](tmp/Uninstall-Mapserv-Ubuntu.sh) |

> **Nota:** actualmente la documentación detallada está en los manuales de instalación.
> Para la desinstalación se incluyen scripts automatizados para Windows y Ubuntu/Linux;
> las instrucciones de ejecución rápida se muestran en la sección **Desinstalación rápida**.

---

## Instalación

### Windows

## Documentación completa → [docs/INSTALL_WINDOWS.md](docs/INSTALL_WINDOWS.md)

### Ubuntu / Linux

## Documentación completa → [docs/INSTALL_UBUNTU.md](docs/INSTALL_UBUNTU.md)

## Desinstalación rápida

### Windows

Ejecutar **PowerShell como Administrador**:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\apps\tmp\Uninstall-MS4W-Windows.ps1
```

El desinstalador permite:

- Detener y eliminar el servicio `Apache MS4W Web Server`.
- Eliminar la carpeta `C:\ms4w` si se confirma durante la ejecución.
- Quitar una IP loopback `127.x.x.x` si fue configurada durante la instalación.
- Registrar el proceso en `C:\apps\logs\uninstall_log.txt`.

---

### Ubuntu / Linux

```bash
sudo chmod +x /apps/tmp/Uninstall-Mapserv-Ubuntu.sh
sudo /apps/tmp/Uninstall-Mapserv-Ubuntu.sh
```

El desinstalador permite:

- Eliminar los CGI `wms` y `wfs` de `/usr/lib/cgi-bin/`.
- Deshabilitar y borrar el VirtualHost `/etc/apache2/sites-available/mapserver.conf`.
- Validar la configuración de Apache y reiniciar el servicio `apache2`.
- Registrar el proceso en `/apps/logs/uninstall_ubuntu_log.txt`.

---
