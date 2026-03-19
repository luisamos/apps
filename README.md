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

```powershell
# 1. Clonar en C:\apps (ruta obligatoria)
git clone https://github.com/luisamos/apps.git C:\apps

# 2. Ejecutar el instalador como Administrador
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\apps\tmp\Install-MS4W.ps1
```

El script solicita la **IP** y el **puerto** al inicio, actualiza los archivos `.map`
y deja Apache corriendo como servicio de Windows.

Documentación completa → [docs/INSTALL_WINDOWS.md](docs/INSTALL_WINDOWS.md)

---

### Ubuntu

```bash
# 1. Clonar en /apps (ruta obligatoria)
sudo git clone https://github.com/luisamos/apps.git /apps

# 2. Instalar dependencias
sudo apt update && sudo apt install -y apache2 cgi-mapserver mapserver-bin libapache2-mod-mapcache
sudo a2enmod cgi headers alias env

# 3. Seguir la guía para configurar el VirtualHost e IP/puerto
```

Documentación completa → [docs/INSTALL_UBUNTU.md](docs/INSTALL_UBUNTU.md)

---

## Servicios expuestos

| Servicio            | URL de prueba                                                                         |
| ------------------- | ------------------------------------------------------------------------------------- |
| WMS GetCapabilities | `http://<IP>:<PUERTO>/servicio/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities` |
| WFS GetCapabilities | `http://<IP>:<PUERTO>/servicio/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetCapabilities` |
