#!/usr/bin/env bash
# ===========================================================================
#  harden-check.sh — Auditoría rápida de la postura de seguridad del stack.
#  Comprueba, sobre los contenedores en marcha, que las medidas de hardening
#  documentadas están realmente aplicadas. Pensado como ejercicio de aula:
#  "no te fíes del compose, verifica el estado real".
# ===========================================================================
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m[FALLO]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[1;33m[AVISO]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
exists() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

echo ""
echo "  ═══ Auditoría de hardening — Laboratorio Zabbix ═══"
echo ""

echo "  · Exposición de red"
# La BD no debe publicar ningún puerto al host
if [ -z "$(docker port zbx-postgres 2>/dev/null)" ]; then
  ok "PostgreSQL no publica puertos al host"
else
  bad "PostgreSQL está publicando puertos: $(docker port zbx-postgres)"
fi
# El servidor Zabbix (10051) no debe estar publicado
if [ -z "$(docker port zbx-server 2>/dev/null)" ]; then
  ok "El servidor Zabbix (10051) no está expuesto al host"
else
  bad "El servidor Zabbix publica puertos: $(docker port zbx-server)"
fi
# El frontend solo debe exponer HTTPS
if docker port zbx-web 2>/dev/null | grep -q 8443; then
  ok "El frontend expone HTTPS (8443)"
else
  warn "No se detecta el frontend en 8443 (¿stack apagado?)"
fi

echo ""
echo "  · Aislamiento de Internet (redes internas)"
for net in back mon; do
  full="academia-zabbix_${net}"
  internal=$(docker network inspect "$full" --format '{{.Internal}}' 2>/dev/null)
  if [ "$internal" = "true" ]; then ok "La red '$net' es interna (sin salida a Internet)";
  else bad "La red '$net' NO es interna"; fi
done

echo ""
echo "  · Cifrado agente <-> servidor (PSK)"
for c in zbx-agent-web zbx-agent-db; do
  exists "$c" || { warn "$c no está en marcha"; continue; }
  conf=$(docker exec "$c" grep -E "^TLS(Connect|Accept)=" /etc/zabbix/zabbix_agent2.conf 2>/dev/null | tr '\n' ' ')
  if echo "$conf" | grep -q "TLSConnect=psk" && echo "$conf" | grep -q "TLSAccept=psk"; then
    ok "$c fuerza cifrado PSK ($conf)"
  else
    bad "$c no fuerza PSK ($conf)"
  fi
done

echo ""
echo "  · Ejecución remota de comandos deshabilitada"
for c in zbx-agent-web zbx-agent-db; do
  exists "$c" || continue
  if docker exec "$c" grep -q "^DenyKey=system.run" /etc/zabbix/zabbix_agent2.conf 2>/dev/null; then
    ok "$c bloquea system.run (DenyKey)"
  else
    bad "$c NO bloquea system.run"
  fi
done

echo ""
echo "  · Contenedores sin privilegios y sin escalada"
for c in zbx-postgres zbx-server zbx-web zbx-agent-web zbx-agent-db; do
  exists "$c" || continue
  nnp=$(docker inspect "$c" --format '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}' 2>/dev/null | grep -c no-new-privileges)
  [ "$nnp" -ge 1 ] && ok "$c: no-new-privileges activo" || bad "$c: sin no-new-privileges"
done
# Agentes deben correr como usuario no root
for c in zbx-agent-web zbx-agent-db; do
  exists "$c" || continue
  uid=$(docker exec "$c" id -u 2>/dev/null)
  [ "$uid" != "0" ] && ok "$c corre como uid $uid (no root)" || bad "$c corre como root"
done

echo ""
echo "  · Secretos fuera de variables de entorno en claro"
leak=$(docker inspect zbx-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -iE "PASSWORD=" | grep -viE "_FILE" )
if [ -z "$leak" ]; then ok "El servidor no expone contraseñas en variables de entorno";
else bad "Contraseña en variable de entorno: $leak"; fi

echo ""
echo "  ─────────────────────────────────────────────"
printf "  Resultado: \033[1;32m%d PASS\033[0m · \033[1;31m%d FALLO\033[0m · \033[1;33m%d AVISO\033[0m\n" "$PASS" "$FAIL" "$WARN"
echo ""
[ "$FAIL" -eq 0 ]
