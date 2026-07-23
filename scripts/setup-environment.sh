#!/usr/bin/env bash
# ==============================================================================
# setup-environment.sh
#
# Aprovisiona un servidor Ubuntu con Nginx, Apache (backend aislado en :8080),
# Certbot con validación DNS-01 y hardening básico, de forma no interactiva.
#
# Uso:
#   sudo ./setup-environment.sh -d midominio.duckdns.org -e correo@example.com -t <TOKEN_DNS>
#
# Requisitos previos:
#   - Ubuntu 22.04+/24.04
#   - Reglas de firewall del proveedor cloud abiertas para TCP 443
#   - Plugin certbot-dns-<proveedor> compatible con tu proveedor DNS
# ==============================================================================

set -euo pipefail

DOMAIN=""
EMAIL=""
DNS_TOKEN=""
DNS_PROVIDER="duckdns"     # cambiar según tu proveedor DNS (duckdns, cloudflare, route53, etc.)
BACKEND_PORT="8080"

usage() {
  echo "Uso: sudo $0 -d <dominio> -e <correo> -t <token_dns> [-p <proveedor_dns>] [-b <puerto_backend>]"
  exit 1
}

while getopts "d:e:t:p:b:h" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    t) DNS_TOKEN="$OPTARG" ;;
    p) DNS_PROVIDER="$OPTARG" ;;
    b) BACKEND_PORT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$DNS_TOKEN" ]]; then
  echo "[ERROR] Faltan parámetros obligatorios."
  usage
fi

echo "=== [1/6] Actualizando el sistema ==="
apt update && apt upgrade -y

echo "=== [2/6] Instalando Nginx, Apache y Certbot ==="
apt install -y nginx apache2 certbot python3-certbot python3-pip

echo "=== [3/6] Aislando el backend (Apache) en el puerto ${BACKEND_PORT} ==="
sed -i "s/^Listen 80$/Listen ${BACKEND_PORT}/" /etc/apache2/ports.conf || true
if ! grep -q "Listen ${BACKEND_PORT}" /etc/apache2/ports.conf; then
  echo "Listen ${BACKEND_PORT}" >> /etc/apache2/ports.conf
fi
systemctl restart apache2

echo "=== [4/6] Instalando plugin ACME DNS-01 (${DNS_PROVIDER}) ==="
pip3 install "certbot-dns-${DNS_PROVIDER}" --break-system-packages

CRED_FILE="/etc/${DNS_PROVIDER}.ini"
echo "dns_${DNS_PROVIDER}_token = ${DNS_TOKEN}" > "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo "=== [5/6] Emitiendo certificado TLS mediante desafío DNS-01 ==="
certbot certonly \
  --authenticator "dns-${DNS_PROVIDER}" \
  --dns-${DNS_PROVIDER}-credentials "$CRED_FILE" \
  --dns-${DNS_PROVIDER}-propagation-seconds 60 \
  -d "$DOMAIN" \
  --non-interactive \
  --agree-tos \
  -m "$EMAIL"

echo "=== [6/6] Desplegando virtual host de Nginx ==="
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_CONF="/etc/nginx/sites-available/${DOMAIN}"

sed -e "s/<TU_DOMINIO>/${DOMAIN}/g" \
    -e "s/<PUERTO_BACKEND>/${BACKEND_PORT}/g" \
    "${TEMPLATE_DIR}/nginx/sites-available/project.conf.template" > "$SITE_CONF"

ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl restart nginx

echo "=== Aplicando reglas de firewall local (iptables) ==="
iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT

echo "=== Verificando temporizador de renovación automática ==="
systemctl status certbot.timer --no-pager || true
certbot renew --dry-run

echo ""
echo "✅ Despliegue completado para ${DOMAIN}"
echo "   Verifica las cabeceras de seguridad con:"
echo "   curl -I -k https://${DOMAIN}"
