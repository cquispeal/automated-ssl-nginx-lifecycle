#!/usr/bin/env python3
"""
health-check-ssl.py

Audita la vigencia del certificado TLS de un dominio y alerta si está
próximo a expirar. Pensado para ejecutarse manualmente o vía cron/systemd
timer como capa adicional de verificación sobre la renovación automática
de Certbot.

Uso:
    python3 health-check-ssl.py --host tu-dominio.example.com [--port 443] [--threshold 30]
"""

import argparse
import socket
import ssl
import sys
from datetime import datetime


def audit_ssl_certificate(hostname: str, port: int, threshold_days: int) -> int:
    """Conecta al host vía TLS, extrae la fecha de expiración del certificado
    y retorna un código de salida: 0 = OK, 1 = alerta, 2 = error de conexión."""

    context = ssl.create_default_context()
    try:
        with socket.create_connection((hostname, port), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=hostname) as ssock:
                cert = ssock.getpeercert()
                expires = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z")
                days_left = (expires - datetime.utcnow()).days

                print(f"[INFO] Dominio auditado: {hostname}:{port}")
                print(f"[INFO] Emisor: {dict(x[0] for x in cert.get('issuer', [])).get('organizationName', 'N/D')}")
                print(f"[INFO] Expira: {expires.isoformat()} UTC")
                print(f"[INFO] Días de vigencia restantes: {days_left}")

                if days_left < threshold_days:
                    print(f"[ALERTA] El certificado expira en menos de {threshold_days} días.")
                    return 1

                print("[ESTADO] Infraestructura criptográfica segura.")
                return 0

    except (socket.timeout, ConnectionRefusedError, socket.gaierror) as e:
        print(f"[ERROR] No se pudo establecer conexión con {hostname}:{port} -> {e}")
        return 2
    except Exception as e:
        print(f"[ERROR] Falló la auditoría TLS: {e}")
        return 2


def main():
    parser = argparse.ArgumentParser(description="Auditoría de vigencia de certificado TLS.")
    parser.add_argument("--host", required=True, help="Dominio a auditar, ej. tu-dominio.example.com")
    parser.add_argument("--port", type=int, default=443, help="Puerto TLS (por defecto 443)")
    parser.add_argument("--threshold", type=int, default=30, help="Umbral de alerta en días (por defecto 30)")
    args = parser.parse_args()

    exit_code = audit_ssl_certificate(args.host, args.port, args.threshold)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
