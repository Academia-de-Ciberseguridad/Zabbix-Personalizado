#!/usr/bin/env bash
# ===========================================================================
#  preflight.sh — Comprueba que la máquina del alumno cumple los requisitos
#  ANTES de arrancar el laboratorio. No instala nada: solo diagnostica y dice
#  qué hacer. Para instalar lo que falte en Linux Debian/Kali/Ubuntu:
#      make setup      (o  bash scripts/setup-host.sh)
# ===========================================================================
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[1;32m[OK]\033[0m    %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m[FALTA]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[1;33m[AVISO]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo ""
echo "  ═══ Requisitos del Laboratorio Zabbix ═══"
echo ""

# --- 1. Docker Engine ------------------------------------------------------
echo "  · Motor de contenedores"
if have docker; then
  ok "docker instalado ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  if docker info >/dev/null 2>&1; then
    ok "el demonio de Docker está en marcha y es accesible"
  elif sudo -n docker info >/dev/null 2>&1; then
    warn "el demonio responde con sudo pero tu usuario no está en el grupo 'docker' (usa 'newgrp docker' o reinicia sesión)"
  else
    bad "el demonio de Docker no responde: arráncalo con 'sudo systemctl enable --now docker'"
  fi
else
  bad "docker NO está instalado  ->  ejecuta 'make setup'"
fi

# --- 2. Docker Compose v2 --------------------------------------------------
echo ""
echo "  · Docker Compose v2"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose v2 ($(docker compose version --short 2>/dev/null))"
elif have docker-compose; then
  warn "solo tienes docker-compose v1 (sintaxis antigua). El lab usa 'docker compose' (v2) -> instala el plugin con 'make setup'"
else
  bad "docker compose v2 NO disponible  ->  ejecuta 'make setup'"
fi

# --- 3. Utilidades base ----------------------------------------------------
echo ""
echo "  · Utilidades base"
for tool in make openssl python3 git; do
  if have "$tool"; then ok "$tool"; else bad "$tool ausente  ->  'make setup' lo instala"; fi
done

# --- 4. Puertos del host ---------------------------------------------------
echo ""
echo "  · Puertos libres en el host (8443 Zabbix, 3000 Grafana, 10050 lab ofensivo)"
port_busy() {
  if have ss; then ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
  elif have lsof; then lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else return 2; fi
}
for p in 8443 3000 10050; do
  port_busy "$p"; rc=$?
  if   [ $rc -eq 0 ]; then warn "el puerto $p está ocupado (libéralo o cambia el mapeo en .env)"
  elif [ $rc -eq 2 ]; then warn "no puedo comprobar el puerto $p (sin ss/lsof)"
  else ok "puerto $p libre"; fi
done

# --- 5. Recursos -----------------------------------------------------------
echo ""
echo "  · Recursos"
if have free; then
  memmb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  if [ "${memmb:-0}" -ge 2000 ]; then ok "RAM total ${memmb} MB (>= 2 GB)"; else warn "RAM total ${memmb} MB: el stack completo pide ~2 GB"; fi
fi
freg=$(df -Pk . 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')
if [ "${freg:-0}" -ge 5 ]; then ok "disco libre ${freg} GB (>= 5 GB para las imágenes)"; else warn "disco libre ~${freg} GB: las imágenes ocupan ~2-3 GB"; fi

# --- 6. Conectividad para la PRIMERA descarga de imágenes ------------------
echo ""
echo "  · Conectividad (solo para la primera descarga de imágenes)"
if curl -fsS --max-time 6 https://registry-1.docker.io/v2/ >/dev/null 2>&1 \
   || curl -fsIS --max-time 6 https://hub.docker.com >/dev/null 2>&1; then
  ok "hay salida a Docker Hub (o ya tienes las imágenes en caché)"
else
  warn "sin acceso a Docker Hub ahora mismo: descarga las imágenes antes de clase (ver docs/10)"
fi

echo ""
echo "  ─────────────────────────────────────────────"
printf "  Resultado: \033[1;32m%d OK\033[0m · \033[1;31m%d FALTA\033[0m · \033[1;33m%d AVISO\033[0m\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then
  echo "  Todo listo. Arranca el laboratorio con:  make full"
else
  echo "  Faltan requisitos. En Linux Debian/Kali/Ubuntu:  make setup"
fi
echo ""
[ "$FAIL" -eq 0 ]
