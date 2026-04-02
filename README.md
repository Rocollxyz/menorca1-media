# MediaCMS — Instalador automático

Instala [MediaCMS](https://github.com/mediacms-io/mediacms) en un servidor Ubuntu limpio con SSL automático (Let's Encrypt), en un solo comando.

## Requisitos

1. Servidor Ubuntu 22.04 / 24.04 limpio
2. Dominio apuntando a la IP del servidor (registro A en tu DNS)
3. Acceso root

## Instalación
```bash
git clone https://github.com/Rocollxyz/menorca1-media
cd menorca1-media
bash install.sh
```

El script te preguntará dominio, email SSL, nombre del portal, usuario admin, contraseña y email. La instalación tarda 3-5 minutos.

## Gestión
```bash
# Ver logs
cd /root/mediacms && docker compose -f docker-compose-letsencrypt.yaml logs -f

# Reiniciar
cd /root/mediacms && docker compose -f docker-compose-letsencrypt.yaml restart

# Parar
cd /root/mediacms && docker compose -f docker-compose-letsencrypt.yaml down
```

## Desinstalación
```bash
bash uninstall.sh
```

## Arquitectura

| Contenedor | Función |
|---|---|
| nginx-proxy | Reverse proxy con SSL |
| nginx-proxy-acme | Renovación automática de certificados |
| web | Aplicación MediaCMS (Django + uWSGI) |
| celery_worker | Procesamiento de vídeos |
| celery_beat | Tareas programadas |
| db | PostgreSQL |
| redis | Cache y broker de Celery |
