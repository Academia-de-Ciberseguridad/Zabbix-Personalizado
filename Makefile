# =============================================================================
#  Laboratorio Zabbix — Academia de Ciberseguridad
#  Comandos de aula. Ejecuta `make` sin argumentos para ver la ayuda.
# =============================================================================
SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help

## help: muestra esta ayuda
help:
	@echo ""
	@echo "  Laboratorio Zabbix — comandos disponibles:"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /   make /'
	@echo ""

## setup: instala los requisitos (Docker, Compose, utilidades) — máquina nueva
setup:
	@bash scripts/setup-host.sh

## preflight: comprueba que la máquina cumple los requisitos (no instala nada)
preflight:
	@bash scripts/preflight.sh

# Guard interno: verifica que Docker + Compose v2 están disponibles antes de arrancar
_require-docker:
	@docker compose version >/dev/null 2>&1 || { \
	  echo ""; \
	  echo "  ✗ Falta Docker o Docker Compose v2."; \
	  echo "    En Linux Debian/Kali/Ubuntu:   make setup"; \
	  echo "    Para diagnosticar en detalle:  make preflight"; \
	  echo ""; exit 1; }

## bootstrap: genera secretos, claves PSK y certificados TLS (ejecutar 1 vez)
bootstrap:
	@bash scripts/bootstrap.sh

## up: arranca el stack base (BD, servidor, frontend, 2 agentes, provisioner)
up: _require-docker bootstrap
	@$(COMPOSE) up -d
	@echo "  Frontend:  https://localhost:$${ZBX_WEB_HTTPS_PORT:-8443}"
	@$(MAKE) --no-print-directory creds

## demo: arranca un 3er cliente (srv-app) con carga real y lo da de alta
demo: _require-docker bootstrap
	@$(COMPOSE) --profile demo up -d
	@echo "  Dando de alta srv-app vía API (re-provisioning idempotente)..."
	@$(COMPOSE) run --rm -e PROVISION_APP=true provisioner
	@echo "  srv-app monitorizado. Sus gráficas de CPU oscilarán en ~1 min."

## grafana: arranca además Grafana con el plugin de Zabbix
grafana: _require-docker bootstrap
	@$(COMPOSE) --profile grafana up -d
	@echo "  Grafana:  http://localhost:$${GRAFANA_PORT:-3000}"

## full: arranca TODO menos el módulo ofensivo (base + demo + grafana)
full: _require-docker bootstrap
	@$(COMPOSE) --profile demo --profile grafana up -d
	@$(COMPOSE) run --rm -e PROVISION_APP=true provisioner
	@echo "  Grafana:  http://localhost:$${GRAFANA_PORT:-3000}"
	@$(MAKE) --no-print-directory creds

## vuln: arranca el agente vulnerable del módulo ofensivo (red aislada)
vuln: _require-docker bootstrap
	@$(COMPOSE) --profile vuln up -d agent-vuln
	@echo "  Agente vulnerable escuchando en 127.0.0.1:10050 (solo laboratorio)"

## ps: estado de los contenedores
ps:
	@$(COMPOSE) --profile demo --profile grafana --profile vuln ps

## logs: sigue los logs de todos los servicios (Ctrl-C para salir)
logs:
	@$(COMPOSE) logs -f --tail=50

## creds: muestra las credenciales de acceso generadas
creds:
	@echo ""
	@echo "  ┌─ Credenciales del laboratorio ───────────────────────────────"
	@printf "  │  Zabbix   https://localhost:%s   Admin / %s\n" "$${ZBX_WEB_HTTPS_PORT:-8443}" "$$(cat secrets/zabbix_admin_password.txt 2>/dev/null || echo '(ejecuta make bootstrap)')"
	@printf "  │  Grafana  http://localhost:%s    admin / %s\n" "$${GRAFANA_PORT:-3000}" "$$(cat secrets/grafana_admin_password.txt 2>/dev/null || echo '(ejecuta make bootstrap)')"
	@echo "  └──────────────────────────────────────────────────────────────"
	@echo ""

## harden-check: comprobaciones rápidas de postura de seguridad del stack
harden-check:
	@bash scripts/harden-check.sh

## down: detiene y elimina los contenedores (conserva datos)
down:
	@$(COMPOSE) --profile demo --profile grafana --profile vuln down

## clean: elimina contenedores Y volúmenes (borra la BD y las gráficas)
clean:
	@$(COMPOSE) --profile demo --profile grafana --profile vuln down -v
	@echo "  Volúmenes eliminados. (secrets/, psk/ y tls/ se conservan)"

## reset: clean + borra también secretos/PSK/TLS (vuelta a cero absoluta)
reset: clean
	@rm -f secrets/*.txt psk/*.psk tls/ssl.* tls/dhparam.pem
	@echo "  Material sensible eliminado. Ejecuta 'make up' para empezar de cero."

.PHONY: help setup preflight _require-docker bootstrap up demo grafana full vuln ps logs creds harden-check down clean reset
