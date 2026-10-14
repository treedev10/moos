#!/usr/bin/env python3
"""
Test web server for MOOS's network stack (HTTP/1.1 and HTTPS).

    python3 tests/net/server.py [--port 8080] [--tls-port 8443] [--big MB]

Serves, from the QEMU guest's point of view at http://10.0.2.2:PORT/ :

    /hello                 a short text
    /file/NAME             a file from build/nettest/ (Range requests: 206 +
                           Content-Range; HEAD)
    /gen/SIZE              SIZE pseudo-random bytes (seed 1), Range too
    /chunked/SIZE          the same bytes as /gen/SIZE, chunked, in chunks of
                           random sizes (1 .. ?max=, default 3000), with chunk
                           extensions now and then and a trailer at the end
    /close/SIZE            no Content-Length: the body ends when the server
                           closes the connection
    /early/SIZE            says Content-Length SIZE, sends half, then closes
    /slow/SIZE             ?step=BYTES&ms=DELAY: sends a piece at a time
    /stall/SIZE            sends half, then nothing (the client must time out)
    /continue              an interim "100 Continue" before the real reply
    /headers               the request's head, echoed back as text
    /echo                  POST: method, Content-Type, length and SHA-256 of
                           the body, and its first 64 bytes
    /redirect?to=URL       302 to URL (&code=301/303/307/308)
    /longurl/N             a redirect to /headers?x=AAAA... (N bytes in all)
    /cookies/set           Set-Cookie: several, with attributes
    /cookies/del           deletes some of them (Max-Age=0, Expires past)
    /cookies/many          70 cookies (the jar keeps 64)
    /cookies/long          one cookie with a 3000-byte value
    /cookies/show          the Cookie header that came (also /cookies/sub/show)
    /bighead               reply headers of about 40 KB (too large for MOOS)
    /status/CODE           an empty reply with that status (204, 304, 404 ...)
    /sha/NAME              the SHA-256 of build/nettest/NAME (for checks)

The HTTPS port serves the same with a self-signed certificate made with
openssl in build/nettest/ (MOOS refuses it unless told not to check: get -k,
nettest -k). --big makes build/nettest/big.bin (default 20 MB) first.
Every request is logged (method, path, Range, Cookie) to stdout.
"""
import hashlib
import http.server
import os
import random
import socketserver
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, 'build', 'nettest')


def gen_bytes(size, seed=1):
    """SIZE pseudo-random bytes, the same every time (numpy if available)."""
    try:
        import numpy as np
        return np.random.default_rng(seed).integers(0, 256, size, dtype=np.uint8).tobytes()
    except ImportError:
        return random.Random(seed).randbytes(size)


GEN_CACHE = {}


def gen_cached(size):
    if size not in GEN_CACHE:
        if len(GEN_CACHE) > 8:
            GEN_CACHE.clear()
        GEN_CACHE[size] = gen_bytes(size)
    return GEN_CACHE[size]


def make_cert():
    """A self-signed certificate for 10.0.2.2 / localhost (made once)."""
    os.makedirs(DATA, exist_ok=True)
    crt, key = os.path.join(DATA, 'test.crt'), os.path.join(DATA, 'test.key')
    if not os.path.exists(crt):
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', key, '-out', crt, '-days', '30', '-subj', '/CN=10.0.2.2',
                        '-addext', 'subjectAltName=IP:10.0.2.2,DNS:localhost'],
                       check=True, capture_output=True)
    return crt, key


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'MOOSTest/1.0'

    def log_message(self, fmt, *args):
        pass

    def log(self, extra=''):
        rng = self.headers.get('Range')
        ck = self.headers.get('Cookie')
        line = '%s %s %s' % (self.command, self.path[:120] + ('...' if len(self.path) > 120 else ''),
                             'tls' if getattr(self.server, 'tls', False) else '')
        if rng:
            line += ' Range=' + rng
        if ck:
            line += ' Cookie(%d)=%s' % (len(ck), ck[:100])
        print(time.strftime('%H:%M:%S'), line, extra, flush=True)

    # --------------------------------------------------------------- helpers
    def send_body(self, body, ctype='text/plain', status=200, extra=()):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def send_ranged(self, data, ctype='application/octet-stream'):
        """data with Range support (one range, bytes=a-b / a- / -n)."""
        rng = self.headers.get('Range')
        total = len(data)
        if rng and rng.startswith('bytes='):
            spec = rng[6:].split(',')[0].strip()
            a, _, b = spec.partition('-')
            try:
                if a == '':
                    start, end = max(0, total - int(b)), total - 1
                else:
                    start = int(a)
                    end = int(b) if b else total - 1
                end = min(end, total - 1)
                if start >= total or start > end:
                    raise ValueError
            except ValueError:
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */%d' % total)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            part = data[start:end + 1]
            self.send_response(206)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, total))
            self.send_header('Content-Length', str(len(part)))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()
            if self.command != 'HEAD':
                self.write_all(part)
            return
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(total))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        if self.command != 'HEAD':
            self.write_all(data)

    def write_all(self, data):
        view = memoryview(data)
        for i in range(0, len(view), 1 << 20):
            self.wfile.write(view[i:i + (1 << 20)])

    def query(self):
        return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))

    def route(self):
        return urllib.parse.urlsplit(self.path).path

    # --------------------------------------------------------------- methods
    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self.log()
        n = int(self.headers.get('Content-Length', '0'))
        body = b''
        while len(body) < n:
            chunk = self.rfile.read(n - len(body))
            if not chunk:
                break
            body += chunk
        out = ('method=POST\nctype=%s\nlen=%d\nsha256=%s\nstart=%r\n' % (
            self.headers.get('Content-Type'), len(body), hashlib.sha256(body).hexdigest(),
            body[:64])).encode()
        print('   POST body', len(body), 'bytes, sha256', hashlib.sha256(body).hexdigest(), flush=True)
        if self.route().startswith('/redirect'):
            self.send_response(int(self.query().get('code', '303')))
            self.send_header('Location', self.query().get('to', '/hello'))
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_body(out)

    def do_GET(self):
        self.log()
        path = self.route()
        q = self.query()
        parts = path.strip('/').split('/')
        try:
            name = 'r_' + parts[0]
            if hasattr(self, name):
                getattr(self, name)(parts[1:], q)
            else:
                self.send_body(b'not found\n', status=404)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError) as e:
            print('   (client went away: %s)' % e.__class__.__name__, flush=True)

    # ---------------------------------------------------------------- routes
    def r_hello(self, parts, q):
        self.send_body(b'Hello from the MOOS test server.\n')

    def r_file(self, parts, q):
        p = os.path.join(DATA, os.path.basename(parts[0]) if parts else '')
        if not os.path.isfile(p):
            self.send_body(b'no such file\n', status=404)
            return
        self.send_ranged(open(p, 'rb').read())

    def r_sha(self, parts, q):
        p = os.path.join(DATA, os.path.basename(parts[0]) if parts else '')
        if not os.path.isfile(p):
            self.send_body(b'no such file\n', status=404)
            return
        self.send_body(hashlib.sha256(open(p, 'rb').read()).hexdigest().encode() + b'\n')

    def r_gen(self, parts, q):
        self.send_ranged(gen_cached(int(parts[0])))

    def r_chunked(self, parts, q):
        data = gen_cached(int(parts[0]))
        rnd = random.Random(int(q.get('seed', '7')))
        mx = int(q.get('max', '3000'))
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        if self.command == 'HEAD':
            return
        i, n = 0, 0
        while i < len(data):
            k = min(len(data) - i, rnd.randint(1, mx))
            ext = ';name=value' if n % 7 == 3 else ''
            hexsize = ('%x' if n % 2 else '%X') % k
            self.wfile.write(('%s%s\r\n' % (hexsize, ext)).encode() + data[i:i + k] + b'\r\n')
            i += k
            n += 1
            if n % 50 == 0:
                self.wfile.flush()
        self.wfile.write(b'0\r\nX-Trailer: done\r\n\r\n')
        print('   sent %d chunks' % n, flush=True)

    def r_close(self, parts, q):
        data = gen_cached(int(parts[0]))
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.write_all(data)
        self.close_connection = True

    def r_early(self, parts, q):
        n = int(parts[0])
        data = gen_cached(n)
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(n))
        self.end_headers()
        self.write_all(data[:n // 2])
        self.wfile.flush()
        self.close_connection = True

    def r_stall(self, parts, q):
        n = int(parts[0])
        data = gen_cached(n)
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(n))
        self.end_headers()
        self.write_all(data[:n // 2])
        self.wfile.flush()
        time.sleep(float(q.get('s', '60')))
        self.close_connection = True

    def r_slow(self, parts, q):
        n = int(parts[0])
        data = gen_cached(n)
        step = int(q.get('step', '1000'))
        delay = int(q.get('ms', '100')) / 1000.0
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(n))
        self.end_headers()
        for i in range(0, n, step):
            self.wfile.write(data[i:i + step])
            self.wfile.flush()
            time.sleep(delay)

    def r_continue(self, parts, q):
        self.wfile.write(b'HTTP/1.1 100 Continue\r\n\r\n')
        self.send_body(b'after the interim reply\n')

    def r_headers(self, parts, q):
        head = 'path-length=%d\n' % len(self.path)
        head += '%s %s %s\n' % (self.command, self.path, self.request_version)
        head += ''.join('%s: %s\n' % (k, v) for k, v in self.headers.items())
        self.send_body(head.encode(), extra=[('X-Path-Length', str(len(self.path)))])

    def r_redirect(self, parts, q):
        self.send_response(int(q.get('code', '302')))
        self.send_header('Location', q.get('to', '/hello'))
        self.send_header('Content-Length', '0')
        self.end_headers()

    def r_longurl(self, parts, q):
        n = int(parts[0])
        base = 'http://10.0.2.2:%d/headers?x=' % self.server.server_port
        if getattr(self.server, 'tls', False):
            base = 'https://10.0.2.2:%d/headers?x=' % self.server.server_port
        loc = base + 'A' * max(0, n - len(base))
        self.send_response(302)
        self.send_header('Location', loc)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def r_cookies(self, parts, q):
        what = parts[0] if parts else ''
        if what == 'set':
            hdrs = [('Set-Cookie', 'plain=1'),
                    ('Set-Cookie', 'withpath=2; Path=/cookies/sub'),
                    ('Set-Cookie', 'domain=3; Domain=10.0.2.2'),
                    ('Set-Cookie', 'session=abc def; HttpOnly'),
                    ('Set-Cookie', 'secure=4; Secure'),
                    ('Set-Cookie', 'maxage=5; Max-Age=3600'),
                    ('Set-Cookie', 'expires=6; Expires=Wed, 01 Jan 2031 00:00:00 GMT'),
                    ('Set-Cookie', 'gone=7; Expires=Thu, 01 Jan 1970 00:00:01 GMT'),
                    ('Set-Cookie', 'other=8; Domain=example.com'),
                    ('Set-Cookie', 'noequals')]
            self.send_body(b'cookies set\n', extra=hdrs)
        elif what == 'del':
            hdrs = [('Set-Cookie', 'plain=; Max-Age=0'),
                    ('Set-Cookie', 'maxage=x; Expires=Mon, 01-Jan-01 00:00:00 GMT'),
                    ('Set-Cookie', 'withpath=; Path=/cookies/sub; Max-Age=-1')]
            self.send_body(b'cookies deleted\n', extra=hdrs)
        elif what == 'many':
            hdrs = [('Set-Cookie', 'c%02d=%d' % (i, i)) for i in range(70)]
            self.send_body(b'70 cookies set\n', extra=hdrs)
        elif what == 'long':
            hdrs = [('Set-Cookie', 'long=' + 'L' * 3000)]
            self.send_body(b'long cookie set\n', extra=hdrs)
        else:   # show (also /cookies/sub/show)
            self.send_body(('Cookie: %s\n' % self.headers.get('Cookie')).encode())

    def r_bighead(self, parts, q):
        hdrs = [('X-Filler-%d' % i, 'F' * 200) for i in range(200)]
        self.send_body(b'big head\n', extra=hdrs)

    def r_status(self, parts, q):
        code = int(parts[0])
        self.send_response(code)
        if code not in (204, 304):
            self.send_header('Content-Length', '0')
        self.end_headers()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    args = sys.argv[1:]
    port, tls_port, big = 8080, 8443, None
    while args:
        a = args.pop(0)
        if a == '--port':
            port = int(args.pop(0))
        elif a == '--tls-port':
            tls_port = int(args.pop(0))
        elif a == '--big':
            big = int(args.pop(0))
    os.makedirs(DATA, exist_ok=True)
    if big:
        p = os.path.join(DATA, 'big.bin')
        if not os.path.exists(p) or os.path.getsize(p) != big << 20:
            open(p, 'wb').write(gen_bytes(big << 20, seed=5))
        print('big.bin', big, 'MB, sha256', hashlib.sha256(open(p, 'rb').read()).hexdigest(), flush=True)
    httpd = Server(('0.0.0.0', port), Handler)
    httpd.tls = False
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print('HTTP on port', port, flush=True)
    if tls_port:
        crt, key = make_cert()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(crt, key)
        if os.environ.get('SSLKEYLOGFILE'):
            ctx.keylog_filename = os.environ['SSLKEYLOGFILE']
        httpsd = Server(('0.0.0.0', tls_port), Handler)
        httpsd.socket = ctx.wrap_socket(httpsd.socket, server_side=True)
        httpsd.tls = True
        threading.Thread(target=httpsd.serve_forever, daemon=True).start()
        print('HTTPS on port', tls_port, flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
