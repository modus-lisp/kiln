# connect_proxy.py — an HTTP CONNECT proxy, for testing `--https-proxy'.
# Answers CONNECT host:port with 200 and tunnels bytes both ways without looking at
# them, logging each tunnel and the Proxy-Authorization it carried.  Port is argv[1].
import socket, threading, sys

def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass

def handle(c):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = c.recv(4096)
            if not d:
                return
            buf += d
        head, _, rest = buf.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        line = lines[0].decode()
        auth = [l.split(b":", 1)[1].strip().decode() for l in lines[1:]
                if l.lower().startswith(b"proxy-authorization:")]
        method, target, _ = line.split(" ", 2)
        if method != "CONNECT":
            c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        host, port = target.rsplit(":", 1)
        up = socket.create_connection((host, int(port)), timeout=60)
        print("tunnel", target, ("auth " + auth[0]) if auth else "noauth", flush=True)
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        if rest:
            up.sendall(rest)
        t = threading.Thread(target=pipe, args=(up, c), daemon=True)
        t.start()
        pipe(c, up)
        t.join()
        up.close()
    except OSError as e:
        print("proxy error", e, flush=True)
    finally:
        c.close()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 3128))
srv.listen(64)
print("proxy up", flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
