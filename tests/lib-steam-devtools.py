#!/usr/bin/env python3
# Stand-in for the Steam client's DevTools port (127.0.0.1:8080, which the helpers reach through
# steam-install-app's page_url and evaluate), for suites that test a call made in the client's UI.
#
#     python3 tests/lib-steam-devtools.py <state dir>
#
#   <state dir>/port     written once the port listens (the suite's RETROFORGE_STEAM_DEVTOOLS is
#                        http://127.0.0.1:<port>)
#   <state dir>/mode     read at every request: `nopage` and /json/list names no SharedJSContext page
#   <state dir>/client   run for every Runtime.evaluate with the file holding the expression as its
#                        argument: what it prints is the value the page answers with (the real page
#                        answers "ok" once it has made the call, "nofn" before SteamClient is there),
#                        and what it does is what the client would do. Without one the answer is nofn.
#
# One connection at a time, one evaluate a connection, as steam-install-app's client makes them.
import base64
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys

state = sys.argv[1]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
port = srv.getsockname()[1]
with open(os.path.join(state, "port.part"), "w") as f:
    f.write(str(port))
os.replace(os.path.join(state, "port.part"), os.path.join(state, "port"))


def mode():
    try:
        with open(os.path.join(state, "mode")) as f:
            return f.read().strip()
    except OSError:
        return ""


def serve(c):
    head = b""
    while b"\r\n\r\n" not in head:
        d = c.recv(4096)
        if not d:
            return
        head += d
    if b"/json/list" in head.split(b"\r\n", 1)[0]:
        pages = [] if mode() == "nopage" else [{"title": "SharedJSContext", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/1"}]
        body = json.dumps(pages).encode()
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        return
    key = re.search(rb"Sec-WebSocket-Key: (\S+)", head).group(1)
    accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")

    def read(n):
        buf = b""
        while len(buf) < n:
            d = c.recv(n - len(buf))
            if not d:
                raise OSError("closed")
            buf += d
        return buf
    _, b1 = read(2)
    n = b1 & 0x7F
    n = struct.unpack(">H", read(2))[0] if n == 126 else struct.unpack(">Q", read(8))[0] if n == 127 else n
    mask = read(4)
    request = json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(read(n))))
    with open(os.path.join(state, "expr"), "w") as f:
        f.write(request["params"]["expression"])
    value, client = "nofn", os.path.join(state, "client")
    if os.access(client, os.X_OK):
        value = subprocess.run([client, os.path.join(state, "expr")], capture_output=True, text=True, timeout=30).stdout.strip()
    out = json.dumps({"id": request.get("id", 1), "result": {"result": {"type": "string", "value": value}}}).encode()
    c.sendall(b"\x81" + (bytes([len(out)]) if len(out) < 126 else b"\x7e" + struct.pack(">H", len(out))) + out)


while True:
    conn, _ = srv.accept()
    try:
        serve(conn)
    except (OSError, ValueError, AttributeError, KeyError, subprocess.SubprocessError):
        pass
    finally:
        conn.close()
