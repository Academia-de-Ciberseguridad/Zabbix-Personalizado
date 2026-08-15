# Laboratorio Zabbix — Academia de Ciberseguridad

Stack de monitorización **Zabbix 7.0 LTS sobre Docker** con hardening por
defecto, pensado como **clase única intensiva (4 h)**. Cubre cuatro ángulos:

1. **Observabilidad** — desplegar Zabbix y monitorizar clientes reales.
2. **Monitorización como control de seguridad** — telemetría, detección, MITRE ATT&CK.
3. **Hardening del propio Zabbix** — TLS PSK, secretos, RBAC, aislamiento, no-root.
4. **Zabbix como superficie de ataque** — por qué el monitor es objetivo de alto valor.

> **Ámbito.** Es un **laboratorio formativo aislado**. No forma parte de ningún
> engagement de pentesting ni apunta a sistemas de terceros. El módulo ofensivo
> se ejecuta contra un contenedor deliberadamente vulnerable, en red separada.

---

## Arquitectura (resumen)

```
                 ┌─────────── Host (Kali) ───────────┐
   HTTPS :8443 ──┤  zbx-web (nginx+php)   red: edge   │──▶ Internet (solo web/grafana)
   Grafana :3000─┤  zbx-grafana                        │
                 │        │ red: back (interna)        │
                 │  zbx-server ── zbx-postgres         │  (sin puertos, sin Internet)
                 │        │ red: mon (interna)          │
                 │  srv-web   srv-db   srv-app          │  agentes con cifrado PSK
                 └────────────────────────────────────┘
   red: vuln (aislada)  →  srv-vuln  (solo módulo ofensivo, :10050 en localhost)
```

- **La base de datos y el servidor no publican puertos ni tienen salida a Internet.**
- **Único servicio expuesto: el frontend, y solo por HTTPS.**
- **Cifrado PSK obligatorio** entre agentes y servidor.

Detalle completo en [`docs/02-arquitectura.md`](docs/02-arquitectura.md).

---

## Puesta en marcha

**Requisitos:** Docker Engine + Docker Compose v2, y `make`/`openssl`/`python3`.
El resto lo genera el propio laboratorio. ¿Máquina recién instalada?

```bash
make preflight   # ¿tengo lo necesario? (no instala nada, solo diagnostica)
make setup       # instala Docker + Compose + utilidades (Linux Debian/Kali/Ubuntu)
```

En macOS/Windows se usa Docker Desktop. Guía completa desde cero (incluida la
pre-descarga de imágenes para aulas sin Internet) en
[`docs/10-requisitos-e-instalacion.md`](docs/10-requisitos-e-instalacion.md).

```bash
make up        # base: BD, servidor, frontend, 2 clientes (srv-web, srv-db) + provisioning
make full      # todo lo anterior + 3er cliente con carga (srv-app) + Grafana
make creds     # muestra las credenciales generadas
make harden-check   # audita la postura de seguridad del stack en marcha
```

Accesos (las contraseñas las genera `make bootstrap`, se muestran con `make creds`):

| Servicio | URL | Usuario |
|---|---|---|
| Zabbix  | `https://localhost:8443` | `Admin` |
| Grafana | `http://localhost:3000`  | `admin` |

> El certificado del frontend es self-signed: el navegador avisará. Es esperado
> en laboratorio (ver módulo de hardening para emitir uno de confianza).

### Perfiles opcionales

```bash
make demo      # añade srv-app: 3er cliente con carga real -> gráficas vivas
make grafana   # añade Grafana con el plugin de Zabbix y un dashboard provisionado
make vuln      # arranca el agente vulnerable del módulo ofensivo (red aislada)
```

### Ciclo de vida

```bash
make ps        # estado de los contenedores
make logs      # logs en vivo
make down      # detiene (conserva datos)
make clean     # detiene y borra volúmenes (BD, gráficas)
make reset     # borra además secretos/PSK/TLS (vuelta a cero)
```

---

## Qué hay dentro

| Ruta | Contenido |
|---|---|
| `docker-compose.yml` | El stack completo, comentado como material de aula |
| `.env` | Versiones, puertos, zona horaria (nada sensible) |
| `Makefile` | Comandos del aula |
| `scripts/bootstrap.sh` | Genera secretos, claves PSK y certificados TLS |
| `scripts/harden-check.sh` | Auditoría de la postura de seguridad |
| `scripts/zabbix_get.py` | Cliente del protocolo Zabbix para el módulo ofensivo |
| `provisioner/provision.py` | Configura Zabbix por API (idempotente) |
| `config/agent-*/lab.conf` | Config de los agentes (endurecida y vulnerable) |
| `grafana/` | Datasource y dashboard provisionados |
| `secrets/`, `psk/`, `tls/` | Material sensible generado (git-ignorado) |
| `docs/` | **Material de la clase** (ver abajo) |

---

## Material de la clase (`docs/`)

| Documento | Para qué |
|---|---|
| [`fundamentos-zabbix.md`](docs/fundamentos-zabbix.md) | **Teoría:** qué es Zabbix, para qué sirve, cómo funciona |
| [`00-guion-instructor.md`](docs/00-guion-instructor.md) | Guion minuto a minuto de las 4 h |
| [`01-guia-alumno.md`](docs/01-guia-alumno.md) | Cuaderno del alumno con ejercicios |
| [`02-arquitectura.md`](docs/02-arquitectura.md) | Arquitectura, redes y flujo de datos |
| [`03-hardening.md`](docs/03-hardening.md) | Hardening del propio Zabbix |
| [`04-superficie-ataque.md`](docs/04-superficie-ataque.md) | Zabbix como objetivo (ofensivo) |
| [`05-monitorizacion-como-control.md`](docs/05-monitorizacion-como-control.md) | Detección y MITRE ATT&CK |
| [`06-observabilidad-dashboards.md`](docs/06-observabilidad-dashboards.md) | Plantillas, triggers y dashboards |
| [`07-retos.md`](docs/07-retos.md) | Retos, CTF y rúbrica de evaluación |
| [`08-troubleshooting.md`](docs/08-troubleshooting.md) | Problemas comunes y soluciones |
| [`09-cheatsheet.md`](docs/09-cheatsheet.md) | Chuleta de comandos |
| [`10-requisitos-e-instalacion.md`](docs/10-requisitos-e-instalacion.md) | Instalación desde cero por plataforma |

---

## Componentes y versiones (verificado)

- Zabbix **7.0.29** LTS (server, web-nginx, agent2) — imágenes `alpine-7.0`
- PostgreSQL **16** (alpine)
- Grafana **11.3.0** + plugin `alexanderzobnin-zabbix-app` **6.6.0**

Estado validado en el despliegue de referencia: 3 clientes `DISPONIBLE` sobre
PSK, datasource de Grafana con salud `OK`, y `harden-check` con **17/17 PASS**.
