# 🔐 Automated SSL/TLS Lifecycle Management & Infrastructure Hardening

Sistema de automatización del ciclo de vida de certificados SSL/TLS sobre **Nginx** y el protocolo **ACME (RFC 8555)**, desplegado en una instancia cloud real, con aislamiento de servicios de red y hardening de cabeceras HTTP validado mediante escaneo de vulnerabilidades (**OWASP ZAP**).

> Proyecto desarrollado como parte de mi formación en Ingeniería de Ciberseguridad (SENATI), orientado a demostrar competencias de Security/Infrastructure Engineering en un entorno de producción real, no simulado.

---

## 📋 Descripción del problema

En arquitecturas web e infraestructura cloud, la expiración de un certificado X.509 es una de las causas más frecuentes de interrupción de servicio no planificada (*Service Outage*): navegadores bloqueando el acceso, fallos de confianza TLS entre servicios, y gestión manual propensa a error humano que no escala.

Este proyecto resuelve el problema mediante una arquitectura de **renovación autónoma de certificados**, con:

- Emisión y renovación desatendida vía protocolo ACME (RFC 8555).
- Validación por **DNS-01**, sin depender de puertos entrantes abiertos.
- Aislamiento de servicios concurrentes (backend, VPN) para evitar colisiones.
- **Zero-downtime reload**: el servidor recarga sus credenciales sin cortar conexiones activas.
- Hardening de cabeceras HTTP verificado con herramientas de pentesting.

---

## 🛠 Arquitectura de la solución

```
Internet
   │
   ▼
[Firewall Cloud]  ──(TCP 80/443)──▶  [iptables INPUT]
   │
   ▼
┌───────────────────── Servidor (Ubuntu 24.04 LTS) ─────────────────────┐
│                                                                        │
│   [Nginx :80] ──301──▶ [Nginx :443 TLS] ──security headers──▶         │
│                              │                                        │
│                              └──▶ proxy_pass ──▶ [Backend :8080]      │
│                                                                        │
│   [Certbot + plugin DNS] ──DNS-01 TXT──▶ [Proveedor DNS dinámico]     │
│            │                                                          │
│            └──systemd timer (2x/día)──▶ renew --dry-run / reload     │
│                                                                        │
│   [VPN] (opera de forma independiente, sin interferencia)            │
└─────────────────────────────────────────────────────────────────────┘
```

**Componentes:**

1. **Frontend / Proxy inverso — Nginx**: terminación TLS 1.3 y enrutamiento perimetral.
2. **Backend desacoplado**: reasignado a un puerto alternativo (8080) para eliminar colisiones de socket con el frontend.
3. **Cliente ACME con desafío DNS-01**: evita depender de validación HTTP-01, útil quandonde el firewall perimetral restringe el puerto 80 de forma intermitente.
4. **Orquestación con systemd timer**: auditoría de expiración dos veces al día y renovación autónoma con hook de recarga segura.

---

## ⚙️ Stack tecnológico

| Categoría | Tecnología |
|---|---|
| Cloud | Oracle Cloud Infrastructure (instancia ARM64) |
| SO | Ubuntu Server 24.04 LTS |
| Servidor web | Nginx (proxy inverso / terminación TLS) |
| Backend | Apache HTTP Server (puerto aislado) |
| PKI / ACME | Certbot, protocolo ACME (RFC 8555) |
| DNS dinámico | Plugin de validación DNS-01 |
| Automatización | systemd timers, Bash, Python |
| Redes | iptables, VPN WireGuard (coexistencia) |
| Hardening | Cabeceras HTTP de seguridad, `server_tokens off` |
| Seguridad ofensiva | OWASP ZAP (escaneo activo/pasivo) |

---

## 📁 Estructura del repositorio

```
automated-ssl-nginx-lifecycle/
├── README.md
├── LICENSE
├── nginx/
│   ├── conf.d/
│   │   └── default.conf.template
│   └── sites-available/
│       └── project.conf.template
├── scripts/
│   ├── setup-environment.sh
│   └── health-check-ssl.py
└── docs/
    └── architecture-flow.png
```

---

## 🚀 Guía de implementación

### 1. Preparación del entorno base
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install nginx apache2 certbot python3-certbot python3-pip -y
```

### 2. Aislamiento de puertos del backend
`nginx/sites-available/project.conf.template` asume que el backend escucha en `8080`. En Apache, edita `/etc/apache2/ports.conf`:
```apache
Listen 8080
<IfModule ssl_module>
	Listen 443
</IfModule>
```
```bash
sudo systemctl restart apache2
```

### 3. Cliente ACME con validación DNS
```bash
sudo pip3 install certbot-dns-<tu-proveedor> --break-system-packages

# /etc/<proveedor>.ini
dns_<proveedor>_token = TU_TOKEN_AQUI

sudo chmod 600 /etc/<proveedor>.ini

sudo certbot certonly \
  --authenticator dns-<proveedor> \
  --dns-<proveedor>-credentials /etc/<proveedor>.ini \
  --dns-<proveedor>-propagation-seconds 60 \
  -d tu-dominio.example.com \
  --non-interactive --agree-tos -m tu-correo@example.com
```

### 4. Configuración de Nginx (plantilla)
Ver [`nginx/sites-available/project.conf.template`](./nginx/sites-available/project.conf.template):

```nginx
server {
    listen 80;
    server_name tu-dominio.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name tu-dominio.example.com;

    ssl_certificate     /etc/letsencrypt/live/tu-dominio.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/tu-dominio.example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    root /var/www/html;
    index index.html index.htm;

    # Hardening de seguridad
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Content-Security-Policy "default-src 'self'" always;

    location / {
        add_header Cache-Control "no-cache, no-store, must-revalidate, private";
        try_files $uri $uri/ =404;
    }
}
```

```bash
sudo ln -sf /etc/nginx/sites-available/tu-dominio.example.com /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
```

### 5. Firewall (dos capas)
- **Capa cloud**: reglas de entrada para TCP 80 y 443.
- **Capa de sistema (iptables)**:
```bash
sudo iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
```

---

## 🔍 Monitoreo y pruebas de resiliencia

**Simulación de renovación autónoma (sin consumir cuota real):**
```bash
sudo certbot renew --dry-run
```
Salida esperada: `Congratulations, all simulated renewals succeeded!`

**Verificación de cabeceras de seguridad:**
```bash
curl -I -k https://tu-dominio.example.com
```

**Script de auditoría de certificado — [`scripts/health-check-ssl.py`](./scripts/health-check-ssl.py):**
```python
import ssl
import socket
from datetime import datetime

HOSTNAME = "tu-dominio.example.com"
PORT = 443
THRESHOLD_DAYS = 30

def audit_ssl_certificate():
    context = ssl.create_default_context()
    try:
        with socket.create_connection((HOSTNAME, PORT), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=HOSTNAME) as ssock:
                cert = ssock.getpeercert()
                expires = datetime.strptime(cert['notAfter'], '%b %d %H:%M:%S %Y %Z')
                days_left = (expires - datetime.utcnow()).days
                print(f"[INFO] Dominio auditado: {HOSTNAME}")
                print(f"[INFO] Días de vigencia restantes: {days_left} días.")
                if days_left < THRESHOLD_DAYS:
                    print("[ALERTA] El certificado expira pronto.")
                else:
                    print("[ESTADO] Infraestructura criptográfica segura.")
    except Exception as e:
        print(f"[ERROR] Falló la auditoría TLS: {e}")

if __name__ == "__main__":
    audit_ssl_certificate()
```

---

## ✅ Resultados de validación

| Prueba | Resultado |
|---|---|
| `certbot renew --dry-run` | Renovación simulada exitosa |
| `systemctl status certbot.timer` | Timer activo y habilitado en el arranque |
| `curl -I` sobre HTTPS | Cabeceras HSTS, CSP, X-Frame-Options y X-Content-Type-Options presentes |
| Escaneo OWASP ZAP (2ª iteración) | Hallazgos de cabeceras faltantes remediados |
| Coexistencia con VPN activa | Servicio web sin interferencia sobre la interfaz VPN |
| Aislamiento frontend/backend | Sin colisión de puertos tras reasignación del backend |

---

## 🎯 Competencias demostradas

- Gestión de PKI y protocolos criptográficos (ACME / RFC 8555, X.509)
- Hardening de servidores web (cabeceras HTTP, ocultamiento de banner, control de caché)
- Segmentación y aislamiento de red (reasignación de puertos, iptables, VPN)
- Automatización de infraestructura (systemd timers, Bash, Python)
- Pruebas de seguridad ofensivas/defensivas (OWASP ZAP, verificación empírica con curl)
- Diagnóstico y resolución de incidentes de configuración
- Documentación técnica de arquitectura

---

## 🔭 Próximos pasos

- [ ] Migrar el despliegue a Ansible (playbook idempotente, multi-nodo)
- [ ] Integrar `health-check-ssl.py` con webhook de alertas (Slack/Telegram)
- [ ] Pipeline CI que ejecute OWASP ZAP automáticamente contra staging
- [ ] Evaluar Zero Trust / mTLS para el acceso administrativo

---

## 📄 Licencia

Este proyecto se distribuye bajo la licencia MIT. Consulta el archivo [`LICENSE`](./LICENSE) para más detalles.

---

## 👤 Autor

**Christian Quispe Alarcón**
Estudiante de Ingeniería de Ciberseguridad — SENATI
[LinkedIn](#) · [GitHub](#) · [Correo](#)
