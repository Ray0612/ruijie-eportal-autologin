#!/usr/bin/env python3
"""A tiny logging HTTP proxy for capturing a campus portal login request.

WHY THIS EXISTS
    Portal error messages are often misleading. Guessing parameter formats can
    waste hours. The reliable way is: capture ONE real successful request from
    the browser, then compare field by field.

    Asking someone to "open DevTools and find the POST named login" is a real
    hurdle. This proxy removes it: start it, point a browser at it, log in
    normally, and everything is recorded.

    Campus portals are plain HTTP, so there is NO certificate to install.
    HTTPS traffic is tunnelled through untouched (CONNECT), never inspected.

USAGE
    python3 capture-proxy.py
    # then start a browser with:
    #   chrome --proxy-server="127.0.0.1:8899" --user-data-dir=/tmp/capture

    On Windows, capture-login.bat does all of that for you.

OUTPUT
    captured-requests.txt                every interesting request/response
    captured-bodies/last-post-body.txt   the last POST body (form fields split)
    captured-bodies/last-post-response.txt

SECURITY
    Binds to 127.0.0.1 only. Do NOT change that to 0.0.0.0 -- other devices on
    your LAN would then route through it. Captured files contain your
    credentials: never commit them to git (.gitignore already excludes them).
"""
import datetime
import os
import select
import socket
import threading

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8899

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "captured-requests.txt")
BODY_DIR = os.path.join(HERE, "captured-bodies")

# Hosts whose traffic you care about. Leave empty to log every POST.
INTERESTING_HOSTS = ()

os.makedirs(BODY_DIR, exist_ok=True)
_loglock = threading.Lock()


def log(msg):
    line = "%s %s" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    with _loglock:
        with open(LOG_PATH, "a", encoding="utf-8", errors="replace") as fh:
            fh.write(line + "\n")
        try:
            print(line, flush=True)
        except Exception:
            pass


def recv_headers(sock):
    """Read until the blank line that ends the header block."""
    buf = b""
    while b"\r\n\r\n" not in buf and b"\n\n" not in buf:
        try:
            chunk = sock.recv(4096)
        except Exception:
            return None, b""
        if not chunk:
            return None, b""
        buf += chunk
        if len(buf) > 262144:
            break
    for sep in (b"\r\n\r\n", b"\n\n"):
        i = buf.find(sep)
        if i >= 0:
            return buf[:i], buf[i + len(sep):]
    return buf, b""


def read_body(sock, head, already):
    cl = 0
    for line in head.split(b"\n"):
        if line.lower().startswith(b"content-length:"):
            try:
                cl = int(line.split(b":", 1)[1].strip())
            except Exception:
                cl = 0
    body = already
    while len(body) < cl:
        try:
            chunk = sock.recv(min(65536, cl - len(body)))
        except Exception:
            break
        if not chunk:
            break
        body += chunk
    return body[:cl] if cl else body


def decode(b):
    try:
        return b.decode("utf-8", "replace")
    except Exception:
        return repr(b)


def handle_tunnel(client, first_line):
    """CONNECT -> plain bidirectional tunnel (HTTPS, not inspected)."""
    parts = first_line.split()
    hostport = parts[1] if len(parts) > 1 else ""
    if ":" not in hostport:
        hostport += ":443"
    host, _, port = hostport.rpartition(":")
    try:
        upstream = socket.create_connection((host, int(port)), timeout=15)
    except Exception as e:
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except Exception:
            pass
        log("CONNECT FAIL %s (%s)" % (hostport, e))
        return
    try:
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    except Exception:
        return
    log("CONNECT %s  (tunnelled)" % hostport)

    def pump(a, b):
        try:
            while True:
                r, _, _ = select.select([a], [], [], 60)
                if not r:
                    break
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except Exception:
            pass
        finally:
            try:
                b.shutdown(socket.SHUT_WR)
            except Exception:
                pass

    t1 = threading.Thread(target=pump, args=(client, upstream), daemon=True)
    t2 = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    t1.start()
    t2.start()
    t1.join(timeout=120)
    t2.join(timeout=120)
    try:
        upstream.close()
    except Exception:
        pass


def handle_http(client, first_line, head, rest):
    parts = first_line.split()
    if len(parts) < 3:
        return
    method, target = parts[0], parts[1]

    hdrs = {}
    hlines = []
    for line in head.split(b"\n")[1:]:
        line = line.rstrip(b"\r")
        if not line:
            continue
        if b":" in line:
            k, v = line.split(b":", 1)
            hdrs[k.strip().lower()] = v.strip()
        hlines.append(line.decode("utf-8", "replace"))

    body = read_body(client, head, rest)

    if target.startswith("http://"):
        rest_url = target[7:]
        hostport, _, path = rest_url.partition("/")
        path = "/" + path
    else:
        hostport = hdrs.get(b"host", b"").decode("utf-8", "replace")
        path = target
    if ":" not in hostport:
        hostport += ":80"
    host, _, port = hostport.rpartition(":")

    interesting = (method in ("POST", "PUT")) or any(h in host for h in INTERESTING_HOSTS)

    if interesting:
        log("")
        log("=" * 70)
        log(">>> %s http://%s%s" % (method, hostport, path))
        for h in hlines:
            log("      %s" % h)
        if body:
            bs = decode(body)
            log("    ---- BODY (%d bytes) ----" % len(body))
            for kv in bs.split("&"):
                log("      %s" % kv[:400])
            with open(os.path.join(BODY_DIR, "last-post-body.txt"), "w",
                      encoding="utf-8") as fh:
                fh.write(bs)
        log("=" * 70)

    out = ("%s %s HTTP/1.1\r\n" % (method, path)).encode()
    skip = (b"proxy-connection", b"connection", b"keep-alive")
    for line in head.split(b"\n")[1:]:
        line = line.rstrip(b"\r")
        if not line:
            continue
        if b":" in line:
            k = line.split(b":", 1)[0].strip().lower()
            if k in skip:
                continue
        out += line + b"\r\n"
    out += b"Connection: close\r\n\r\n"

    try:
        upstream = socket.create_connection((host, int(port)), timeout=15)
        upstream.sendall(out + body)
        resp = b""
        while True:
            try:
                chunk = upstream.recv(65536)
            except Exception:
                break
            if not chunk:
                break
            resp += chunk
            if len(resp) > 3_000_000:
                break
        upstream.close()
        client.sendall(resp)

        if interesting:
            rb = resp.split(b"\r\n\r\n", 1)
            log("<<< RESPONSE %d bytes: %s" % (len(resp), decode(rb[0])[:300].replace("\n", " | ")))
            if method == "POST" and len(rb) > 1:
                log("    <<< BODY: %s" % decode(rb[1])[:600])
                with open(os.path.join(BODY_DIR, "last-post-response.txt"), "w",
                          encoding="utf-8") as fh:
                    fh.write(decode(rb[1]))
    except Exception as e:
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        except Exception:
            pass
        log("FORWARD FAIL %s%s (%s)" % (hostport, path, e))


def handle(client):
    try:
        head, rest = recv_headers(client)
        if not head:
            return
        first_line = head.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
        if not first_line:
            return
        if first_line.upper().startswith("CONNECT"):
            handle_tunnel(client, first_line)
        else:
            handle_http(client, first_line, head, rest)
    except Exception as e:
        log("HANDLER ERROR %s" % e)
    finally:
        try:
            client.close()
        except Exception:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(64)

    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write("\n\n########## proxy started %s ##########\n" %
                 datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

    print("=" * 70)
    print(" capture proxy listening on %s:%d" % (LISTEN_HOST, LISTEN_PORT))
    print(" log: %s" % LOG_PATH)
    print()
    print(" Start a browser with:")
    print('   chrome --proxy-server="127.0.0.1:%d" --user-data-dir=<temp dir>' % LISTEN_PORT)
    print()
    print(" Then log in to the campus portal normally.")
    print(" Stop with Ctrl+C.")
    print("=" * 70)

    while True:
        try:
            client, _addr = srv.accept()
        except KeyboardInterrupt:
            break
        except Exception:
            continue
        threading.Thread(target=handle, args=(client,), daemon=True).start()
    srv.close()


if __name__ == "__main__":
    main()
