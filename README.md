# apps — MapServer / MapCache

Repositorio de configuración para servicios WMS y WFS basados en MapServer,
con soporte para Windows (MS4W) y Ubuntu (Apache2 + apt).

## Estructura

```
apps/
├── docs/
│   ├── ms4w_5.0.0.zip          ← instalador MS4W para Windows
│   ├── INSTALL_WINDOWS.md      ← guía de instalación en Windows
│   └── INSTALL_UBUNTU.md       ← guía de instalación en Ubuntu
├── logs/                       ← logs de Apache
├── mapcache/                   ← configuración de MapCache
├── mapserv/
│   ├── wms_kaypacha.map        ← mapa de configuración WMS
│   └── wfs_kaypacha.map        ← mapa de configuración WFS
└── tmp/
    ├── Install-MS4W-Windows.ps1    ← instalador Windows
    ├── Install-Mapserv-Ubuntu.sh   ← instalador Ubuntu
    └── Uninstall-MS4W-Windows.sh   ← desinstalador Windows
    └── Uninstall-Mapserv-Ubuntu.sh ← desinstalador Ubuntu
```

---

## Instalación rápida

### Windows

Documentación completa → [docs/INSTALL_WINDOWS.md](docs/INSTALL_WINDOWS.md)

---

### Ubuntu

Documentación completa → [docs/INSTALL_UBUNTU.md](docs/INSTALL_UBUNTU.md)

---

## Servicios expuestos

| Servicio            | URL de prueba                                                                         |
| ------------------- | ------------------------------------------------------------------------------------- |
| WMS GetCapabilities | `http://<IP>:<PUERTO>/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities` |
| WFS GetCapabilities | `http://<IP>:<PUERTO>/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities` |
