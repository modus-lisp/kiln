#!/usr/bin/env python3
"""kiln-ota-serve.py -- install the phone build over the network: Apple's over-the-air install.

    kiln ios device --ota      build, and package $KILN_STATE/ota/modus.ipa (--app=ferry: ferry.ipa)
    kiln ios serve             run this: from then on, any phone on the LAN (or a VPN into it)

  http://HOST:8080/    the local CA's certificate -- once per phone: Safari, Settings > Profile
                       Downloaded > Install, then General > About > Certificate Trust Settings > on
  https://HOST:8443/   the install page, a button per .ipa in $KILN_STATE/ota; each manifest is made
                       per request from the Host the phone used, so any address of this Mac works

The CA and the server certificate live in $KILN_STATE/ota-ca (the CA's key 0600), made on first run.
Three things about iOS that each cost a silent failure (nothing on the phone but "Unable to Install"):
  - the downloader (appstored) refuses a long-lived server certificate -- 800 days was refused while
    Safari and the manifest fetch took it; this one is 45 days, renewed every 30;
  - a certificate that starts NOW is not valid yet to a phone whose clock is a little behind, so it
    starts a day ago;
  - the Mac's addresses change (a DHCP lease, a VPN), and the certificate must name the one the
    phone used: they are checked every minute and the certificate is reissued when they change.
A failed TLS handshake is logged (Python's server otherwise drops it without a word): that is what
a phone that does not trust the certificate looks like from here.
"""
import html, http.server, os, plistlib, re, ssl, subprocess, sys, threading, time, zipfile

STATE = os.environ.get('KILN_STATE') or os.path.expanduser('~/.kiln')
OTA = os.path.join(STATE, 'ota')
CA = os.path.join(STATE, 'ota-ca')

HTTP_PORT = int(os.environ.get('KILN_OTA_HTTP_PORT', '8080'))
HTTPS_PORT = int(os.environ.get('KILN_OTA_HTTPS_PORT', '8443'))


def ca_path(name):
    return os.path.join(CA, name)


def openssl(*args):
    subprocess.run(['openssl', *args], check=True, capture_output=True)


def ensure_ca():
    """The local CA and the server's key and request, once."""
    os.makedirs(CA, mode=0o700, exist_ok=True)
    if not os.path.exists(ca_path('ca.crt')):
        host = local_hostname()
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', ca_path('ca.key'),
                '-out', ca_path('ca.crt'), '-days', '3650', '-subj', f'/CN=kiln OTA local CA ({host})',
                '-addext', 'basicConstraints=critical,CA:TRUE',
                '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        os.chmod(ca_path('ca.key'), 0o600)
        print(f'kiln-ota: made a local CA in {CA}', flush=True)
    if not os.path.exists(ca_path('server.key')):
        openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', ca_path('server.key'),
                '-out', ca_path('server.csr'), '-subj', f'/CN={local_hostname()}.local')
        os.chmod(ca_path('server.key'), 0o600)


def local_hostname():
    out = subprocess.run(['scutil', '--get', 'LocalHostName'], capture_output=True, text=True).stdout.strip()
    return out or 'mac'


def local_addresses():
    """This Mac's IPv4 addresses, loopback aside: en0, VPN tunnels."""
    out = subprocess.run(['ifconfig'], capture_output=True, text=True).stdout
    return sorted({a for a in re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)', out) if not a.startswith('127.')})


def issue_server_cert(addrs):
    """A server certificate for ADDRS, NAME.local and localhost: 45 days, started a day ago."""
    host = local_hostname()
    sans = ','.join([f'IP:{a}' for a in addrs] + [f'DNS:{host}.local', 'DNS:localhost', 'IP:127.0.0.1'])
    with open(ca_path('server.ext'), 'w') as f:
        f.write('basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
                f'extendedKeyUsage=serverAuth\nsubjectAltName={sans}\n')
    fmt = '%Y%m%d%H%M%SZ'
    now = time.time()
    openssl('x509', '-req', '-in', ca_path('server.csr'), '-CA', ca_path('ca.crt'), '-CAkey', ca_path('ca.key'),
            '-CAserial', ca_path('ca.srl'), '-CAcreateserial', '-out', ca_path('server.crt'),
            '-not_before', time.strftime(fmt, time.gmtime(now - 86400)),
            '-not_after', time.strftime(fmt, time.gmtime(now + 44 * 86400)), '-extfile', ca_path('server.ext'))
    print(f'kiln-ota: certificate for {", ".join(addrs)}, {host}.local', flush=True)


def ipas():
    """The apps on offer: NAME for each NAME.ipa in the OTA directory, modus first."""
    names = sorted(f[:-4] for f in os.listdir(OTA) if f.endswith('.ipa')) if os.path.isdir(OTA) else []
    return sorted(names, key=lambda n: n != 'modus')


def ipa_path(name):
    return os.path.join(OTA, name + '.ipa')


def ipa_info(name):
    """The bundle id, build number and name of the app in NAME.ipa."""
    with zipfile.ZipFile(ipa_path(name)) as z:
        name = next(n for n in z.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n))
        info = plistlib.loads(z.read(name))
    return info['CFBundleIdentifier'], info['CFBundleVersion'], info.get('CFBundleName', 'app')


def page(body):
    return ('<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<style>body{font:18px -apple-system,sans-serif;margin:2em;line-height:1.5}'
            'a.b{display:block;padding:.8em;margin:1em 0;background:#0a7;color:#fff;text-align:center;'
            'border-radius:10px;text-decoration:none;font-weight:600}p.w{margin-top:-.6em;color:#888;font-size:15px}</style>' + body).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def send_bytes(self, data, ctype):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def host(self):
        return (self.headers.get('Host') or 'localhost').split(':')[0]


class CertHandler(Handler):
    """Plain http: the CA's certificate, for a phone that does not trust anything here yet."""
    def do_GET(self):
        if self.path == '/ca.cer':
            self.send_bytes(open(ca_path('ca.crt'), 'rb').read(), 'application/x-x509-ca-cert')
            return
        h = html.escape(self.host())
        self.send_bytes(page(f'''<h2>One-time phone setup</h2>
<ol><li>Tap the button, then <b>Allow</b>.</li>
<li>Settings &rarr; <b>Profile Downloaded</b> &rarr; Install.</li>
<li>Settings &rarr; General &rarr; About &rarr; <b>Certificate Trust Settings</b> &rarr; turn the kiln CA on
(installing the profile again turns it off).</li></ol>
<a class=b href="/ca.cer">Get the certificate</a>
<p>Then: <a href="https://{h}:{HTTPS_PORT}/">https://{h}:{HTTPS_PORT}/</a></p>'''), 'text/html; charset=utf-8')

    do_HEAD = do_GET


class InstallHandler(Handler):
    """https: the install page, its manifest and the .ipa."""
    def setup(self):
        try:
            self.request.do_handshake()
        except Exception as e:
            print(f'kiln-ota: TLS refused by {self.client_address[0]}: {e} (is the CA trusted on it?)', flush=True)
            raise
        super().setup()

    def do_GET(self):
        base = f'https://{self.headers.get("Host") or "localhost"}'
        names = ipas()
        if not names:
            self.send_bytes(page('<h2>No build yet</h2><p>Run <code>kiln ios device --ota</code> on the Mac.</p>'),
                            'text/html; charset=utf-8')
            return
        # /NAME.manifest.plist and /NAME.ipa; /manifest.plist is modus's (the links of older pages)
        m = re.fullmatch(r'/(?:([A-Za-z0-9_-]+)\.)?manifest\.plist', self.path)
        i = re.fullmatch(r'/([A-Za-z0-9_-]+)\.ipa', self.path)
        if m and (m.group(1) or 'modus') in names:
            name = m.group(1) or 'modus'
            bundle, version, title = ipa_info(name)
            plist = {'items': [{'assets': [{'kind': 'software-package', 'url': f'{base}/{name}.ipa'},
                                           {'kind': 'display-image', 'url': f'{base}/icon-57.png'},
                                           {'kind': 'full-size-image', 'url': f'{base}/icon-512.png'}],
                                'metadata': {'bundle-identifier': bundle, 'bundle-version': version,
                                             'kind': 'software', 'title': title}}]}
            self.send_bytes(plistlib.dumps(plist), 'application/xml')
        elif self.path in ('/icon-57.png', '/icon-512.png'):
            self.send_bytes(square_png(57 if '57' in self.path else 512), 'image/png')
        elif i and i.group(1) in names:
            path = ipa_path(i.group(1))
            size = os.path.getsize(path)
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(size))
            self.end_headers()
            if self.command != 'HEAD':
                with open(path, 'rb') as f:
                    while chunk := f.read(1 << 20):
                        self.wfile.write(chunk)
        else:
            apps = []
            for name in names:
                title = ipa_info(name)[2]
                when = time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(ipa_path(name))))
                link = f'itms-services://?action=download-manifest&url={base}/{name}.manifest.plist'
                apps.append(f'<a class=b href="{html.escape(link)}">Install {html.escape(title)}</a>'
                            f'<p class=w>build of {when}</p>')
            self.send_bytes(page(f'''<h2>Apps</h2>{"".join(apps)}
<p>Not trusted yet? <a href="http://{html.escape(self.host())}:{HTTP_PORT}/">Set up the certificate</a> first.</p>'''),
                            'text/html; charset=utf-8')

    do_HEAD = do_GET


def square_png(n):
    """A solid square, the manifest's display images (iOS asks for them while it installs)."""
    import struct, zlib
    raw = b''.join(b'\x00' + bytes((0x0a, 0x77, 0x55)) * n for _ in range(n))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # a refused handshake (logged above) or a phone that hung up mid-download: a line, not a
        # traceback; anything else is a real error, and gets the whole story
        if isinstance(sys.exc_info()[1], (ssl.SSLError, ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def main():
    ensure_ca()
    addrs = local_addresses()
    issue_server_cert(addrs)
    plain = Server(('0.0.0.0', HTTP_PORT), CertHandler)
    tls = Server(('0.0.0.0', HTTPS_PORT), InstallHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(ca_path('server.crt'), ca_path('server.key'))
    tls.socket = ctx.wrap_socket(tls.socket, server_side=True, do_handshake_on_connect=False)

    def watch():
        nonlocal addrs
        issued = time.time()
        while True:
            time.sleep(60)
            now = local_addresses()
            if now != addrs or time.time() - issued > 30 * 86400:
                addrs = now
                issue_server_cert(addrs)
                ctx.load_cert_chain(ca_path('server.crt'), ca_path('server.key'))
                issued = time.time()

    threading.Thread(target=watch, daemon=True).start()
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    host = local_hostname()
    print(f'kiln-ota: http://{host}.local:{HTTP_PORT}/ (certificate), '
          f'https://{host}.local:{HTTPS_PORT}/ (install) -- or this Mac\'s address: '
          f'{", ".join(addrs)}', flush=True)
    try:
        tls.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    sys.exit(main())
