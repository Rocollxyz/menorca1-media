#!/bin/bash
set -e

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      MediaCMS — Desinstalación           ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "⚠  Ejecuta este script como root: sudo bash uninstall.sh"
    exit 1
fi

read -p "⚠  Esto eliminará MediaCMS y TODOS sus datos. ¿Continuar? (s/N): " CONFIRM
if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then
    echo "Cancelado."
    exit 0
fi

echo ""
echo "Parando contenedores..."
cd /root/mediacms 2>/dev/null && docker compose -f docker-compose-letsencrypt.yaml down -v 2>/dev/null || true

echo "Eliminando datos..."
rm -rf /root/mediacms
rm -rf /root/postgres_data

echo ""
echo "✓ MediaCMS desinstalado completamente."
echo ""
