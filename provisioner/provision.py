#!/usr/bin/env python3
# ===========================================================================
#  provision.py — Configura el Zabbix del laboratorio vía API JSON-RPC (7.0).
#  Idempotente: se puede re-ejecutar sin duplicar nada.
#
#  Hace, en orden:
#    1. Espera a que la API responda.
#    2. Inicia sesión (contraseña fuerte si ya está puesta; si no, la default).
#    3. Cambia la contraseña de Admin a la del secreto (solo la primera vez).
#    4. Crea el grupo de hosts "Academia/Lab".
#    5. Crea los 2 hosts (srv-web, srv-db) con cifrado PSK y plantilla Linux.
#    6. Crea el usuario de solo lectura "grafana" para el datasource.
#
#  Sin dependencias externas: solo biblioteca estándar de Python.
# ===========================================================================
import json
import os
import sys
import time
import urllib.request
import urllib.error

API_URL   = os.environ["ZBX_API_URL"]
ID_WEB    = os.environ.get("PSK_IDENTITY_WEB", "PSK-srv-web")
ID_DB     = os.environ.get("PSK_IDENTITY_DB", "PSK-srv-db")
ID_APP    = os.environ.get("PSK_IDENTITY_APP", "PSK-srv-app")
PROV_APP  = os.environ.get("PROVISION_APP", "false").lower() in ("1", "true", "yes")

def read_secret(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default

ADMIN_PW   = read_secret("/run/secrets/zabbix_admin_password")
API_PW     = read_secret("/run/secrets/zabbix_api_password")
PSK_WEB    = read_secret("/psk/agent-web.psk")
PSK_DB     = read_secret("/psk/agent-db.psk")
PSK_APP    = read_secret("/psk/agent-app.psk")
DEFAULT_PW = "zabbix"

_req_id = 0

def api(method, params=None, auth=None):
    """Llama a la API JSON-RPC. Lanza excepción con el error de Zabbix si lo hay."""
    global _req_id
    _req_id += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": _req_id}
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json-rpc"}
    # apiinfo.version y user.login no llevan cabecera de autorización
    if auth and method not in ("apiinfo.version", "user.login"):
        headers["Authorization"] = f"Bearer {auth}"
    req = urllib.request.Request(API_URL, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read().decode())
    if "error" in body:
        raise RuntimeError(f"{method}: {body['error'].get('data') or body['error']}")
    return body["result"]

def log(msg):
    print(f"[provision] {msg}", flush=True)

# --- 1. Esperar a que la API esté disponible -------------------------------
def wait_api(max_wait=180):
    deadline = time.time() + max_wait
    while time.time() < deadline:
        try:
            ver = api("apiinfo.version")
            log(f"API Zabbix disponible, versión {ver}")
            return ver
        except (urllib.error.URLError, urllib.error.HTTPError, ConnectionError, RuntimeError, OSError) as e:
            log(f"esperando a la API... ({type(e).__name__})")
            time.sleep(5)
    log("ERROR: la API no respondió a tiempo")
    sys.exit(1)

# --- 2/3. Login + fijar contraseña de Admin --------------------------------
def login_and_secure():
    # ¿La contraseña fuerte ya está puesta? (re-ejecución)
    try:
        token = api("user.login", {"username": "Admin", "password": ADMIN_PW})
        log("sesión iniciada con la contraseña de Admin ya endurecida")
        return token
    except RuntimeError:
        pass
    # Primera vez: entrar con la default y cambiarla
    try:
        token = api("user.login", {"username": "Admin", "password": DEFAULT_PW})
    except RuntimeError as e:
        log(f"ERROR: no se pudo iniciar sesión ni con la contraseña fuerte ni con la default: {e}")
        sys.exit(1)
    log("sesión iniciada con la contraseña por defecto; cambiándola por la del secreto...")
    admin = api("user.get", {"output": ["userid"], "filter": {"username": ["Admin"]}}, auth=token)
    uid = admin[0]["userid"]
    api("user.update", {"userid": uid, "passwd": ADMIN_PW, "current_passwd": DEFAULT_PW}, auth=token)
    log("contraseña de Admin endurecida ✔")
    # Re-login con la nueva contraseña para refrescar la sesión
    return api("user.login", {"username": "Admin", "password": ADMIN_PW})

# --- 4. Grupo de hosts -----------------------------------------------------
def ensure_group(token, name="Academia/Lab"):
    got = api("hostgroup.get", {"output": ["groupid"], "filter": {"name": [name]}}, auth=token)
    if got:
        return got[0]["groupid"]
    gid = api("hostgroup.create", {"name": name}, auth=token)["groupids"][0]
    log(f"grupo de hosts '{name}' creado (id {gid})")
    return gid

# --- 5. Plantilla Linux ----------------------------------------------------
def linux_template(token):
    for name in ("Linux by Zabbix agent", "Linux by Zabbix agent active"):
        got = api("template.get", {"output": ["templateid"], "filter": {"host": [name]}}, auth=token)
        if got:
            return got[0]["templateid"]
    # Búsqueda laxa como último recurso
    got = api("template.get", {"output": ["templateid", "host"], "search": {"host": "Linux by Zabbix agent"}}, auth=token)
    if got:
        return got[0]["templateid"]
    log("AVISO: no se encontró la plantilla Linux; los hosts se crean sin plantilla")
    return None

# --- 5. Hosts con PSK ------------------------------------------------------
def ensure_host(token, name, dns_alias, psk_identity, psk_key, groupid, templateid):
    exists = api("host.get", {"output": ["hostid"], "filter": {"host": [name]}}, auth=token)
    if exists:
        log(f"host '{name}' ya existe (id {exists[0]['hostid']}) — sin cambios")
        return exists[0]["hostid"]
    params = {
        "host": name,
        "groups": [{"groupid": groupid}],
        "interfaces": [{
            "type": 1, "main": 1, "useip": 0,
            "ip": "127.0.0.1", "dns": dns_alias, "port": "10050",
        }],
        "tls_connect": 2,          # el servidor conecta al agente con PSK
        "tls_accept": 2,           # el servidor acepta del agente solo PSK
        "tls_psk_identity": psk_identity,
        "tls_psk": psk_key,
    }
    if templateid:
        params["templates"] = [{"templateid": templateid}]
    hid = api("host.create", params, auth=token)["hostids"][0]
    log(f"host '{name}' creado con cifrado PSK (identity {psk_identity}) ✔")
    return hid

# --- 6. Usuario de solo lectura para Grafana -------------------------------
def ensure_grafana_user(token, groupid):
    if not API_PW:
        log("AVISO: sin contraseña de API; se omite el usuario de Grafana")
        return
    users = api("user.get", {"output": ["userid"], "filter": {"username": ["grafana"]}}, auth=token)
    if users:
        log("usuario 'grafana' ya existe — sin cambios")
        return
    # Grupo de usuarios de solo lectura sobre el grupo de hosts del lab
    ug = api("usergroup.get", {"output": ["usrgrpid"], "filter": {"name": ["Grafana RO"]}}, auth=token)
    if ug:
        usrgrpid = ug[0]["usrgrpid"]
    else:
        usrgrpid = api("usergroup.create", {
            "name": "Grafana RO",
            "hostgroup_rights": [{"id": groupid, "permission": 2}],  # 2 = lectura
        }, auth=token)["usrgrpids"][0]
        log("grupo de usuarios 'Grafana RO' creado (solo lectura) ✔")
    # Rol 'User role' (permisos básicos de lectura de la UI/API)
    role = api("role.get", {"output": ["roleid"], "filter": {"name": ["User role"]}}, auth=token)
    roleid = role[0]["roleid"] if role else "1"
    api("user.create", {
        "username": "grafana",
        "passwd": API_PW,
        "roleid": roleid,
        "usrgrps": [{"usrgrpid": usrgrpid}],
    }, auth=token)
    log("usuario 'grafana' (solo lectura) creado para el datasource ✔")

def main():
    wait_api()
    token = login_and_secure()
    gid = ensure_group(token)
    tid = linux_template(token)
    ensure_host(token, "srv-web", "agent-web", ID_WEB, PSK_WEB, gid, tid)
    ensure_host(token, "srv-db",  "agent-db",  ID_DB,  PSK_DB,  gid, tid)
    if PROV_APP:
        ensure_host(token, "srv-app", "srv-app", ID_APP, PSK_APP, gid, tid)
    ensure_grafana_user(token, gid)
    log("PROVISIONING COMPLETADO ✔  — hosts monitorizados con PSK y usuario de Grafana listo.")

if __name__ == "__main__":
    main()
