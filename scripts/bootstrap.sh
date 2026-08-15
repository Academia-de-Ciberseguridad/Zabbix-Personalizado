#!/usr/bin/env bash
# ============================================================================
#  bootstrap.sh — Genera todo el material sensible del laboratorio Zabbix
#  (secretos de BD, contraseñas, claves PSK agente<->servidor y certificados
#   TLS del frontend web). Idempotente: no sobrescribe lo ya generado.
#
#  Academia de Ciberseguridad — Laboratorio formativo. NO usar en producción
#  tal cual: las claves aquí generadas son de un solo laboratorio efímero.
# ============================================================================
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta la herramienta: $1"; exit 1; }; }
need openssl

# --- 1. Secretos (contraseñas) --------------------------------------------
gen_secret() {  # $1 = fichero, $2 = longitud (por defecto 24)
  local f="secrets/$1" len="${2:-24}"
  if [[ -s "$f" ]]; then
    log "secreto ya existe: $f (se conserva)"
  else
    # Alfanumérico sin caracteres problemáticos para URLs/entornos.
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len" > "$f"
    # 644: las imágenes Zabbix corren sin privilegios (uid 1997) y leen el
    # secreto vía *_FILE. Compose (fuera de Swarm) monta el fichero con los
    # permisos del origen, así que debe ser legible por el usuario del servicio.
    # En un despliegue real esto se resuelve con un gestor de secretos (Vault,
    # secrets de Swarm/K8s) montados 0400 con el uid correcto. Ver docs/03.
    chmod 644 "$f"
    log "secreto generado: $f"
  fi
}

gen_secret postgres_password.txt 28
gen_secret zabbix_admin_password.txt 20   # contraseña del usuario Admin de Zabbix
gen_secret grafana_admin_password.txt 20  # contraseña admin de Grafana
gen_secret zabbix_api_password.txt 24     # usuario 'grafana' de la API de Zabbix

# --- 2. Claves PSK para el cifrado agente <-> servidor --------------------
# Zabbix admite PSK de 128 a 2048 bits. Usamos 256 bits (64 hex) = robusto.
gen_psk() {  # $1 = nombre lógico (web|db)
  local f="psk/agent-$1.psk"
  if [[ -s "$f" ]]; then
    log "PSK ya existe: $f (se conserva)"
  else
    openssl rand -hex 32 > "$f"
    # El agente exige que el fichero NO sea legible por 'otros'.
    chmod 640 "$f"
    log "PSK generada: $f (identity: PSK-srv-$1)"
  fi
}
gen_psk web
gen_psk db
gen_psk app
# El servicio 'psk-init' del compose coloca cada clave en un volumen propiedad
# del usuario del agente (uid 1997, modo 0600). Aquí solo generamos el origen.

# --- 3. Certificado TLS del frontend web ----------------------------------
# Self-signed para laboratorio. En el módulo de hardening se explica cómo
# sustituirlo por uno emitido por una CA interna / ACME.
if [[ -s tls/ssl.crt && -s tls/ssl.key ]]; then
  log "certificado TLS ya existe (se conserva)"
else
  log "generando certificado TLS self-signed para el frontend..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout tls/ssl.key -out tls/ssl.crt -days 825 \
    -subj "/C=MX/O=Academia Ciberseguridad/OU=Lab/CN=zabbix.lab.local" \
    -addext "subjectAltName=DNS:zabbix.lab.local,DNS:localhost,IP:127.0.0.1" \
    >/dev/null 2>&1
  chmod 644 tls/ssl.crt
  # 644: el frontend nginx corre sin privilegios (uid 1997) y debe poder leer la
  # clave. Es una clave self-signed efímera de laboratorio. En producción la
  # clave va como secret 0600 propiedad del servicio (ver docs/03-hardening.md).
  chmod 644 tls/ssl.key
fi
if [[ ! -s tls/dhparam.pem ]]; then
  log "generando dhparam (2048 bits, puede tardar)..."
  openssl dhparam -out tls/dhparam.pem 2048 >/dev/null 2>&1
  chmod 644 tls/dhparam.pem
fi

# --- 4. Resumen -----------------------------------------------------------
cat <<EOF

  ┌────────────────────────────────────────────────────────────────┐
  │  Bootstrap completado. Material sensible generado en:            │
  │    secrets/   contraseñas (BD, Admin Zabbix, Grafana, API)       │
  │    psk/       claves PSK del cifrado agente<->servidor           │
  │    tls/       certificado del frontend HTTPS                      │
  │                                                                  │
  │  Credenciales de acceso (guárdalas, no se muestran de nuevo):    │
  │    Zabbix  → https://localhost:${ZBX_WEB_HTTPS_PORT:-8443}   Admin / $(cat secrets/zabbix_admin_password.txt)
  │    Grafana → http://localhost:${GRAFANA_PORT:-3000}    admin / $(cat secrets/grafana_admin_password.txt)
  └────────────────────────────────────────────────────────────────┘

EOF
log "Listo. Siguiente paso:  make up"
