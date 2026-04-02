#!/bin/bash
set -e

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      MediaCMS — Instalación rápida       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "⚠  Ejecuta este script como root: sudo bash install.sh"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "Docker no está instalado. Instalando..."
    curl -fsSL https://get.docker.com | bash
fi

if ! command -v docker compose &> /dev/null; then
    echo "Docker Compose no está instalado. Instalando..."
    apt-get install -y docker-compose-plugin
fi

echo "✓ Docker listo"
echo ""

read -p "Dominio (ej: media.miempresa.com): " DOMAIN
read -p "Email para SSL (Let's Encrypt): " EMAIL
read -p "Nombre del portal [MediaCMS]: " PORTAL_NAME
PORTAL_NAME=${PORTAL_NAME:-MediaCMS}
read -p "Usuario admin: " ADMIN_USER

while true; do
    read -s -p "Contraseña del admin (mínimo 8 caracteres): " ADMIN_PASSWORD
    echo ""
    if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
        echo "⚠  La contraseña debe tener al menos 8 caracteres."
    else
        read -s -p "Repite la contraseña: " ADMIN_PASSWORD2
        echo ""
        if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ]; then
            echo "⚠  Las contraseñas no coinciden."
        else
            break
        fi
    fi
done

read -p "Email del administrador: " ADMIN_EMAIL

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
POSTGRES_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(20))")

echo ""
echo "✓ Datos recogidos"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat > "$SCRIPT_DIR/.env" << EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
PORTAL_NAME=$PORTAL_NAME
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
ADMIN_EMAIL=$ADMIN_EMAIL
SECRET_KEY=$SECRET_KEY
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF

echo "✓ Configuración guardada en .env"

echo ""
echo "Descargando MediaCMS..."
if [ -d "/root/mediacms" ]; then
    echo "  Directorio /root/mediacms ya existe. Haciendo backup..."
    mv /root/mediacms /root/mediacms.bak.$(date +%s)
fi

cd /root
git clone https://github.com/mediacms-io/mediacms.git
cd /root/mediacms

echo "✓ MediaCMS descargado"

mkdir -p /root/postgres_data

echo ""
echo "Configurando MediaCMS..."
cat > /root/mediacms/cms/local_settings.py << SETTINGS
import os
FRONTEND_HOST = 'https://${DOMAIN}'
PORTAL_NAME = '${PORTAL_NAME}'
SECRET_KEY = '${SECRET_KEY}'
REDIS_LOCATION = os.getenv('REDIS_LOCATION', 'redis://redis:6379/1')
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.getenv('POSTGRES_NAME', 'mediacms'),
        "HOST": os.getenv('POSTGRES_HOST', 'db'),
        "PORT": os.getenv('POSTGRES_PORT', '5432'),
        "USER": os.getenv('POSTGRES_USER', 'mediacms'),
        "PASSWORD": os.getenv('POSTGRES_PASSWORD', '${POSTGRES_PASSWORD}'),
        "OPTIONS": {'pool': True},
    }
}
CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": REDIS_LOCATION,
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
        },
    }
}
BROKER_URL = REDIS_LOCATION
CELERY_RESULT_BACKEND = BROKER_URL
MP4HLS_COMMAND = "/home/mediacms.io/bento4/bin/mp4hls"
DEBUG = False
SETTINGS

echo "✓ local_settings.py generado"

cat > /root/mediacms/docker-compose-letsencrypt.yaml << COMPOSE
version: "3"

services:
  nginx-proxy:
    image: nginxproxy/nginx-proxy
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - conf:/etc/nginx/conf.d
      - vhost:/etc/nginx/vhost.d
      - html:/usr/share/nginx/html
      - dhparam:/etc/nginx/dhparam
      - certs:/etc/nginx/certs:ro
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - ./deploy/docker/reverse_proxy/client_max_body_size.conf:/etc/nginx/conf.d/client_max_body_size.conf:ro

  acme-companion:
    image: nginxproxy/acme-companion
    container_name: nginx-proxy-acme
    volumes_from:
      - nginx-proxy
    volumes:
      - certs:/etc/nginx/certs:rw
      - acme:/etc/acme.sh
      - /var/run/docker.sock:/var/run/docker.sock:ro

  migrations:
    image: mediacms/mediacms:latest
    volumes:
      - ./:/home/mediacms.io/mediacms/
    environment:
      ENABLE_UWSGI: 'no'
      ENABLE_NGINX: 'no'
      ENABLE_CELERY_SHORT: 'no'
      ENABLE_CELERY_LONG: 'no'
      ENABLE_CELERY_BEAT: 'no'
      ADMIN_USER: '${ADMIN_USER}'
      ADMIN_EMAIL: '${ADMIN_EMAIL}'
      ADMIN_PASSWORD: '${ADMIN_PASSWORD}'
    command: "./deploy/docker/prestart.sh"
    restart: on-failure
    depends_on:
      redis:
        condition: service_healthy
      db:
        condition: service_healthy

  web:
    image: mediacms/mediacms:latest
    deploy:
      replicas: 1
    volumes:
      - ./:/home/mediacms.io/mediacms/
    environment:
      ENABLE_CELERY_BEAT: 'no'
      ENABLE_CELERY_SHORT: 'no'
      ENABLE_CELERY_LONG: 'no'
      ENABLE_MIGRATIONS: 'no'
      VIRTUAL_HOST: '${DOMAIN}'
      LETSENCRYPT_HOST: '${DOMAIN}'
      LETSENCRYPT_EMAIL: '${EMAIL}'
    depends_on:
      - migrations

  celery_beat:
    image: mediacms/mediacms:latest
    volumes:
      - ./:/home/mediacms.io/mediacms/
    environment:
      ENABLE_UWSGI: 'no'
      ENABLE_NGINX: 'no'
      ENABLE_CELERY_SHORT: 'no'
      ENABLE_CELERY_LONG: 'no'
      ENABLE_MIGRATIONS: 'no'
    depends_on:
      - redis

  celery_worker:
    image: mediacms/mediacms:latest
    deploy:
      replicas: 1
    volumes:
      - ./:/home/mediacms.io/mediacms/
    environment:
      ENABLE_UWSGI: 'no'
      ENABLE_NGINX: 'no'
      ENABLE_CELERY_BEAT: 'no'
      ENABLE_MIGRATIONS: 'no'
    depends_on:
      - migrations

  db:
    image: postgres:17-alpine
    volumes:
      - ../postgres_data:/var/lib/postgresql/data/
    restart: always
    environment:
      POSTGRES_USER: mediacms
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: mediacms
      TZ: Europe/London
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mediacms -d mediacms"]
      interval: 30s
      timeout: 10s
      retries: 5

  redis:
    image: "redis:alpine"
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  conf:
  vhost:
  html:
  dhparam:
  certs:
  acme:
COMPOSE

echo "✓ docker-compose-letsencrypt.yaml generado"

echo ""
echo "Iniciando contenedores (esto puede tardar unos minutos)..."
cd /root/mediacms
docker compose -f docker-compose-letsencrypt.yaml pull
docker compose -f docker-compose-letsencrypt.yaml up -d

echo ""
echo "Esperando a que los servicios arranquen..."
echo "  (La primera vez puede tardar 2-3 minutos mientras se generan los certificados SSL)"
echo ""

for i in $(seq 1 60); do
    if docker compose -f docker-compose-letsencrypt.yaml exec -T db pg_isready -U mediacms -d mediacms > /dev/null 2>&1; then
        echo "✓ Base de datos lista"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "⚠  Timeout esperando la base de datos."
        echo "   Revisa: docker compose -f docker-compose-letsencrypt.yaml logs db"
        exit 1
    fi
    sleep 3
done

echo "  Esperando migraciones..."
for i in $(seq 1 90); do
    STATUS=$(docker compose -f docker-compose-letsencrypt.yaml ps migrations --format '{{.State}}' 2>/dev/null || echo "running")
    if [ "$STATUS" = "exited" ] || [ "$STATUS" = "" ]; then
        echo "✓ Migraciones completadas"
        break
    fi
    if [ $i -eq 90 ]; then
        echo "⚠  Timeout esperando migraciones."
        echo "   Revisa: docker compose -f docker-compose-letsencrypt.yaml logs migrations"
        exit 1
    fi
    sleep 5
done

echo "  Esperando certificado SSL..."
for i in $(seq 1 60); do
    if docker exec nginx-proxy-acme /bin/sh -c "test -f /etc/nginx/certs/${DOMAIN}/fullchain.pem" 2>/dev/null; then
        echo "✓ Certificado SSL obtenido"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "⚠  El certificado SSL puede tardar unos minutos más."
        echo "   Comprueba: docker logs nginx-proxy-acme"
    fi
    sleep 5
done

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          Instalación completada          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Portal:       https://$DOMAIN"
echo "  Admin panel:  https://$DOMAIN/admin/"
echo "  Usuario:      $ADMIN_USER"
echo ""
echo "  Nota: El SSL puede tardar 1-2 minutos en activarse."
echo ""
echo "  Gestión:"
echo "    Ver logs:     cd /root/mediacms && docker compose -f docker-compose-letsencrypt.yaml logs -f"
echo "    Reiniciar:    cd /root/mediacms && docker compose -f docker-compose-letsencrypt.yaml restart"
echo "    Parar:        cd /root/mediacms && docker compose -f docker-compose-letsencrypt.yaml down"
echo ""
