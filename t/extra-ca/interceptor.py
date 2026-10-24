# interceptor.py — a TLS-intercepting network, for testing `--extra-ca'.
#
# Terminates TLS on 443 with a leaf certificate signed by a throwaway CA (the one
# the test makes), and forwards each request to the real upstream named by its Host
# header.  Plain HTTP on 80 passes through unchanged, as it does on a real network
# where only TLS is intercepted.  The upstream names are pinned in this container's
# /etc/hosts by the test, so the forwarder reaches the real hosts and not itself.
#
# Serves GET and POST, because cairn speaks git smart-HTTP to github.com.
import http.server, ssl, threading, urllib.request, urllib.error

HOP = {"host", "content-length", "connection", "accept-encoding"}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    SCHEME = "https"

    def _forward(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        url = f"{self.SCHEME}://{self.headers['Host']}{self.path}"
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
        try:
            r = urllib.request.urlopen(req, timeout=300)
        except urllib.error.HTTPError as e:
            r = e
        # STREAM the body, chunk by chunk, as it arrives.  Buffering the whole upstream
        # response first makes a large pack wait longer than the client's read timeout
        # for its first byte, and the client gives up.
        self.send_response(r.status if hasattr(r, "status") else r.code)
        ctype = r.headers.get("Content-Type")
        if ctype:
            self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        with r:
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.write(b"0\r\n\r\n")
        print("forwarded", method, url, flush=True)

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def log_message(self, *a):
        pass


class Plain(H):
    SCHEME = "http"


threading.Thread(target=http.server.ThreadingHTTPServer(("0.0.0.0", 80), Plain).serve_forever,
                 daemon=True).start()
tls = http.server.ThreadingHTTPServer(("0.0.0.0", 443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/mock/leaf.pem", "/mock/leaf.key")
tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
print("interceptor up", flush=True)
tls.serve_forever()
