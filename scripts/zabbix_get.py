#!/usr/bin/env python3
# ===========================================================================
#  zabbix_get.py — Cliente mínimo del protocolo pasivo de Zabbix (get).
#  Herramienta de aula para el módulo ofensivo: consulta una clave a un
#  agente Zabbix, igual que hace el servidor. Sirve para DEMOSTRAR por qué
#  un agente con system.run o UserParameters peligrosos es una RCE.
#
#  Uso:   python3 zabbix_get.py <host> <puerto> '<clave>'
#  Ej.:   python3 zabbix_get.py 127.0.0.1 10050 'system.run[id]'
#
#  Solo para el laboratorio aislado. No apuntar a sistemas de terceros.
# ===========================================================================
import socket
import struct
import sys

def zabbix_get(host, port, key, timeout=5):
    payload = key.encode()
    # Cabecera del protocolo Zabbix: "ZBXD" + flags(0x01) + longitud(uint64 LE)
    packet = b"ZBXD" + b"\x01" + struct.pack("<Q", len(payload)) + payload
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(packet)
        # Respuesta: cabecera de 13 bytes + datos
        header = b""
        while len(header) < 13:
            chunk = s.recv(13 - len(header))
            if not chunk:
                break
            header += chunk
        if header[:4] != b"ZBXD":
            # Algunos agentes responden en texto plano
            return (header + s.recv(65535)).decode(errors="replace")
        (length,) = struct.unpack("<Q", header[5:13])
        data = b""
        while len(data) < length:
            chunk = s.recv(min(65535, length - len(data)))
            if not chunk:
                break
            data += chunk
        return data.decode(errors="replace")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    host, port, key = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    try:
        print(zabbix_get(host, port, key), end="")
    except Exception as e:
        print(f"[error] {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
