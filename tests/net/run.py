#!/usr/bin/env python3
"""
Network tests for MOOS: boots build/moos.img in QEMU (user networking),
starts tests/net/server.py on free ports, types commands and checks what
MOOS prints (and what the server saw).

    python3 tests/net/run.py [--uefi] [--nic MODEL] [--native] [--keep]
                             [--pcap FILE] [--tap] [--list] [TEST ...]

With no TEST names every test runs. --native makes "net up native" (under
--uefi the firmware's own driver is used otherwise). --list shows the tests.
--pcap FILE records every frame (look at it with tests/net/pcap.py).
--tap connects QEMU to this computer's own TCP/IP stack through a tap
device (tap.py; needs root) instead of QEMU's user networking, so MOOS's
TCP is tested against Linux's (window scaling, SACK, fast retransmit).
Each test prints PASS or FAIL; on a failure the screen is shown.
Results of the speed tests are printed as "SPEED ...".
"""
import hashlib
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
sys.path.insert(0, ROOT)
import screentest  # noqa: E402
from build import IMAGE, qemu_path, ovmf_paths  # noqa: E402

DATA = os.path.join(ROOT, 'build', 'nettest')
sys.path.insert(0, HERE)
from server import gen_bytes  # noqa: E402


def pattern(n):
    """The bytes "nettest -p N" sends."""
    return bytes(((i * 2654435761) & 0xFFFFFFFF) >> 24 for i in range(n))


def unwrap(rows):
    """The screen's rows as text; a row that fills all 80 columns runs on
    into the next one (MOOS wrapped a long line there)."""
    out = ''
    for r in rows:
        out += r if len(r) >= 80 else r + '\n'
    return out


class Moos:
    def __init__(self, uefi, nic, image, pcap=None, netdev='user,id=n0'):
        self.tmp = tempfile.mkdtemp(prefix='moosnet')
        disk = os.path.join(self.tmp, 'disk.img')
        shutil.copy(image, disk)
        port = screentest.free_port()
        mem = 256 if uefi else 32
        cmd = [qemu_path(), '-drive', 'file=%s,format=raw,index=0,media=disk' % disk,
               '-m', str(mem), '-rtc', 'base=utc', '-display', 'none', '-cpu', 'max',
               '-monitor', 'tcp:127.0.0.1:%d,server,nowait' % port,
               '-netdev', netdev, '-device', nic + ',netdev=n0']
        if pcap:            # every frame MOOS sends and gets (tests/net/pcap.py)
            cmd += ['-object', 'filter-dump,id=f0,netdev=n0,file=' + pcap]
        if uefi:
            code, vars_file = ovmf_paths()
            vars_copy = os.path.join(self.tmp, 'vars.fd')
            shutil.copy(vars_file, vars_copy)
            cmd += ['-drive', 'if=pflash,format=raw,readonly=on,file=%s' % code,
                    '-drive', 'if=pflash,format=raw,file=%s' % vars_copy]
        self.proc = subprocess.Popen(cmd)
        self.mon = screentest.Monitor(port)
        self.screen = screentest.Screen(self.mon, self.tmp, mem)
        self.screen.find(timeout=90)
        time.sleep(1.5)

    def type(self, text):
        for ch in text:
            self.mon.cmd('sendkey ' + screentest.key_for(ch))
            time.sleep(0.03)

    def key(self, name):
        self.mon.cmd('sendkey ' + name)

    def lines(self):
        return self.screen.text()[:24]

    def run(self, command, timeout=60):
        """Clear the screen, type the command, wait for the next prompt.
        -> the text on the screen (without the status bar)."""
        self.type('clear\n')
        time.sleep(0.6)
        self.type(command + '\n')
        end = time.time() + timeout
        while time.time() < end:
            time.sleep(0.5)
            rows = self.lines()
            text = [r for r in rows if r.strip()]
            if len(text) >= 2 and text[-1].rstrip() == 'moos>':
                return unwrap(rows)
            if any('-- more --' in r for r in rows):
                self.key('q')          # the pager: leave it
                time.sleep(0.5)
        return '\n'.join(self.lines()) + '\n[TIMEOUT]'

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


class Server:
    def __init__(self):
        self.port = screentest.free_port()
        self.tls_port = screentest.free_port()
        self.log = os.path.join(DATA, 'server-%d.log' % self.port)
        self.proc = subprocess.Popen(
            [sys.executable, os.path.join(HERE, 'server.py'), '--port', str(self.port),
             '--tls-port', str(self.tls_port), '--big', '20'],
            stdout=open(self.log, 'w'), stderr=subprocess.STDOUT)
        for _ in range(200):
            if 'HTTPS on port' in open(self.log).read():
                break
            time.sleep(0.2)

    def text(self):
        return open(self.log).read()

    def close(self):
        self.proc.kill()
        self.proc.wait()


def sha(data):
    return hashlib.sha256(data).hexdigest()


# ------------------------------------------------------------------- tests
# Each test: (name, function(moos, server, H, S) -> (ok, detail)); H is
# "http://10.0.2.2:PORT", S the https one.
TESTS = []


def test(fn):
    TESTS.append((fn.__name__[2:], fn))
    return fn


def expect(out, *needles):
    missing = [n for n in needles if n not in out]
    return (not missing, 'missing: %r' % missing if missing else '')


def nettest_ok(out, data):
    want = sha(data)
    if 'Done: %d bytes' % len(data) not in out:
        return False, 'size wrong (want %d)' % len(data)
    if want not in out:
        return False, 'SHA-256 wrong (want %s)' % want
    return True, ''


@test
def t_hello(m, s, H, S):
    return expect(m.run('get %s/hello' % H), 'HTTP 200, 33 bytes', 'Hello from the MOOS test server.')


@test
def t_headers(m, s, H, S):
    out = m.run('get %s/headers' % H)
    port = H.rsplit(':', 1)[1]
    return expect(out, 'GET /headers HTTP/1.1', 'Host: %s' % H.split('//')[1], 'User-Agent: MOOS/1.2',
                  'Accept: */*', 'Connection: close')


@test
def t_chunked(m, s, H, S):
    out = m.run('get -i %s/chunked/4000 c.bin' % H)
    ok, why = expect(out, 'HTTP 200, 4000 bytes', 'Transfer-Encoding: chunked', 'Saved to c.bin')
    if not ok:
        return ok, why
    out = m.run('nettest %s/chunked/300000?max=700' % H, timeout=120)
    return nettest_ok(out, gen_bytes(300000))


@test
def t_chunked_tls(m, s, H, S):
    out = m.run('nettest -k %s/chunked/400000?max=20000' % S, timeout=120)
    return nettest_ok(out, gen_bytes(400000))


@test
def t_range(m, s, H, S):
    out = m.run('get -i -r 100-199 %s/gen/10000 r.bin' % H)
    ok, why = expect(out, 'HTTP 206, 100 bytes', 'Content-Range total: 10000')
    if not ok:
        return ok, why
    out = m.run('nettest -r 1000- %s/gen/100000' % H)
    ok, why = nettest_ok(out, gen_bytes(100000)[1000:])
    if not ok:
        return ok, why
    return expect(out, 'HTTP 206', 'total 100000')


@test
def t_post(m, s, H, S):
    out = m.run('get -d hello=world %s/echo' % H)
    return expect(out, 'method=POST', 'ctype=application/x-www-form-urlencoded', 'len=11',
                  'sha256=' + sha(b'hello=world'))


@test
def t_post_big(m, s, H, S):
    n = 300000
    m.run('nettest -p %d %s/echo' % (n, H), timeout=120)
    log = s.text()
    want = 'POST body %d bytes, sha256 %s' % (n, sha(pattern(n)))
    return (want in log, '' if want in log else 'server did not get the right body')


@test
def t_cookies(m, s, H, S):
    m.run('net cookies clear')
    m.run('get %s/cookies/set' % H)
    out = m.run('get %s/cookies/show' % H)
    ok, why = expect(out, 'Cookie: plain=1; domain=3; session=abc def; maxage=5; expires=6')
    if not ok:
        return ok, why
    if 'secure=4' in out or 'gone=' in out or 'other=' in out or 'withpath' in out:
        return False, 'a cookie that should not be sent was sent'
    out = m.run('get %s/cookies/sub/show' % H)
    ok, why = expect(out, 'Cookie: withpath=2; plain=1; domain=3; session=abc def; maxage=5; expires=6')
    if not ok:
        return ok, why
    out = m.run('net cookies')
    ok, why = expect(out, '6 cookie(s)')
    if not ok:
        return ok, why
    m.run('get %s/cookies/del' % H)
    out = m.run('get %s/cookies/sub/show' % H)
    ok, why = expect(out, 'Cookie: domain=3; session=abc def; expires=6')
    if not ok:
        return ok, why
    m.run('get %s/cookies/many' % H)
    out = m.run('net cookies')
    ok, why = expect(out, '64 cookie(s)')
    if not ok:
        return ok, why
    m.run('net cookies clear')
    m.run('get %s/cookies/long' % H)
    out = m.run('get %s/cookies/show' % H)
    ok, why = expect(out, 'Cookie: long=LLLL')
    if not ok:
        return ok, why
    if 'Cookie(%d)=long=LLL' % (5 + 1071) not in s.text():
        return False, 'the long value was not cut to 1071 characters'
    m.run('net cookies clear')
    out = m.run('net cookies')
    return expect(out, '(no cookies)')


@test
def t_cookies_tls(m, s, H, S):
    m.run('net cookies clear')
    m.run('get -k %s/cookies/set' % S)
    out = m.run('get -k %s/cookies/show' % S)
    ok, why = expect(out, 'secure=4', 'plain=1')
    if not ok:
        return ok, why
    out = m.run('get %s/cookies/show' % H)       # Secure: not over plain HTTP
    m.run('net cookies clear')
    if 'secure=4' in out:
        return False, 'a Secure cookie went over plain HTTP'
    return expect(out, 'plain=1')


@test
def t_slow(m, s, H, S):
    out = m.run('nettest %s/slow/60000?step=4000&ms=300' % H, timeout=60)
    return nettest_ok(out, gen_bytes(60000))


@test
def t_close(m, s, H, S):
    out = m.run('nettest %s/close/200000' % H, timeout=60)
    ok, why = nettest_ok(out, gen_bytes(200000))
    if not ok:
        return ok, why
    out = m.run('get %s/close/3000 cl.bin' % H)
    return expect(out, 'HTTP 200, 3000 bytes')


@test
def t_early(m, s, H, S):
    out = m.run('get %s/early/100000' % H)
    ok, why = expect(out, 'closed the connection before the whole reply came')
    if not ok:
        return ok, why
    out = m.run('nettest %s/early/100000' % H)
    return expect(out, 'closed the connection before the whole reply came', 'after 50000 bytes')


@test
def t_stall(m, s, H, S):
    out = m.run('nettest %s/stall/100000?s=45' % H, timeout=80)
    return expect(out, 'stalled', 'after 50000 bytes')


@test
def t_continue(m, s, H, S):
    return expect(m.run('get %s/continue' % H), 'HTTP 200', 'after the interim reply')


@test
def t_bighead(m, s, H, S):
    return expect(m.run('get %s/bighead' % H), 'headers are too large')


@test
def t_status(m, s, H, S):
    ok, why = expect(m.run('get %s/status/204' % H), 'HTTP 204, 0 bytes')
    if not ok:
        return ok, why
    ok, why = expect(m.run('get %s/status/304' % H), 'HTTP 304, 0 bytes')
    if not ok:
        return ok, why
    return expect(m.run('get %s/nothing' % H), 'HTTP 404')


@test
def t_redirect(m, s, H, S):
    out = m.run('nettest %s/redirect?to=/gen/1000' % H)
    ok, why = nettest_ok(out, gen_bytes(1000))
    if not ok:
        return ok, why
    out = m.run('get -i %s/redirect?to=/gen/1000' % H)     # get does not follow
    return expect(out, 'HTTP 302', 'Location: /gen/1000')


@test
def t_longurl(m, s, H, S):
    out = m.run('get %s/longurl/3500' % H)       # (get shows the redirect)
    ok, why = expect(out, 'HTTP 302')
    if not ok:
        return ok, why
    out = m.run('nettest %s/longurl/4000' % H)   # (nettest follows it)
    ok, why = expect(out, 'HTTP 200', 'Done:')
    if not ok:
        return ok, why
    log = s.text()
    if not re.search(r'GET /headers\?x=A{100}', log):
        return False, 'the server did not see the long URL'
    out = m.run('get @long.url')                 # from a file
    m_ = re.search(r'path-length=(\d+)', out)
    want = 3900 - len(H)
    if not m_ or int(m_.group(1)) != want:
        return False, 'long URL from a file not sent whole: %s (want %d)' % (
            m_.group(0) if m_ else '?', want)
    out = m.run('nettest %s/longurl/5000' % H)   # longer than MOOS takes
    return expect(out, 'cannot follow')


@test
def t_https_refused(m, s, H, S):
    out = m.run('get %s/hello' % S)
    if 'HTTP 200' in out:
        return False, 'a self-signed certificate was accepted'
    return expect(out, 'error:')


@test
def t_https(m, s, H, S):
    out = m.run('get -k %s/hello' % S)
    ok, why = expect(out, 'HTTP 200, 33 bytes', 'Hello from the MOOS test server.')
    if not ok:
        return ok, why
    out = m.run('nettest -k %s/gen/1000000' % S, timeout=120)
    return nettest_ok(out, gen_bytes(1000000))


@test
def t_big(m, s, H, S):
    data = open(os.path.join(DATA, 'big.bin'), 'rb').read()
    out = m.run('nettest -n %s/file/big.bin' % H, timeout=300)
    sp = re.search(r'Done: (\d+) bytes in ([\d.]+) s = ([\d.]+) MB/s', out)
    print('SPEED http 20 MB (no hash):', sp.group(0) if sp else out[-300:])
    if not sp or int(sp.group(1)) != len(data):
        return False, 'size wrong'
    out = m.run('nettest %s/file/big.bin' % H, timeout=300)
    sp = re.search(r'Done: (\d+) bytes in ([\d.]+) s = ([\d.]+) MB/s', out)
    print('SPEED http 20 MB (with SHA-256):', sp.group(0) if sp else '?')
    return nettest_ok(out, data)


@test
def t_big_tls(m, s, H, S):
    data = open(os.path.join(DATA, 'big.bin'), 'rb').read()
    out = m.run('nettest -k -n %s/file/big.bin' % S, timeout=400)
    sp = re.search(r'Done: (\d+) bytes in ([\d.]+) s = ([\d.]+) MB/s', out)
    print('SPEED https 20 MB (no hash):', sp.group(0) if sp else out[-300:])
    return (bool(sp) and int(sp.group(1)) == len(data), '' if sp else 'failed')


@test
def t_fetch_big(m, s, H, S):
    out = m.run('get -i %s/gen/600000' % H, timeout=120)
    return expect(out, 'HTTP 200', 'The reply was cut')


@test
def t_loss(m, s, H, S):
    # QEMU's user networking does TCP itself, simply: it resends only after
    # a timeout (1.5 s, doubling), so heavy loss makes it crawl. Through
    # --tap the server is Linux (fast retransmit, SACK) and takes more.
    pct, down, up, tls = (10, 1500000, 200000, 800000) if TAP else (3, 400000, 100000, 200000)
    m.run('net loss %d' % pct)
    try:
        t0 = time.time()
        out = m.run('nettest %s/gen/%d' % (H, down), timeout=300)
        ok, why = nettest_ok(out, gen_bytes(down))
        print('   %d%% loss: %d bytes in %.1f s' % (pct, down, time.time() - t0))
        if not ok:
            return ok, 'download: ' + why
        m.run('nettest -p %d %s/echo' % (up, H), timeout=300)
        want = 'POST body %d bytes, sha256 %s' % (up, sha(pattern(up)))
        if want not in s.text():
            return False, 'upload under loss: the server did not get the right body'
        out = m.run('nettest -k %s/gen/%d' % (S, tls), timeout=300)
        ok, why = nettest_ok(out, gen_bytes(tls))
        if not ok:
            return ok, 'https: ' + why
        out = m.run('get %s/chunked/100000 lc.bin' % H, timeout=200)
        return expect(out, 'HTTP 200, 100000 bytes')
    finally:
        m.run('net loss 0')


TAP = False


def main():
    args = sys.argv[1:]
    uefi, nic, native, keep, image, pcap = False, 'rtl8139', False, False, IMAGE, None
    use_tap = False
    while args and args[0].startswith('--'):
        a = args.pop(0)
        if a == '--uefi':
            uefi = True
        elif a == '--nic':
            nic = args.pop(0)
        elif a == '--native':
            native = True
        elif a == '--keep':
            keep = True
        elif a == '--list':
            print(' '.join(n for n, _ in TESTS))
            return
        elif a == '--image':
            image = args.pop(0)
        elif a == '--pcap':
            pcap = args.pop(0)
        elif a == '--tap':
            use_tap = True
    names = args or [n for n, _ in TESTS]
    os.makedirs(DATA, exist_ok=True)
    srv = Server()
    tap, netdev, host = None, 'user,id=n0', '10.0.2.2'
    if use_tap:             # MOOS <-> this computer's own TCP (tap.py)
        global TAP
        TAP = True
        import tap as tapmod
        tap = tapmod.Tap(srv.port % 200 + 20)
        netdev, host = tap.qemu_netdev(), tap.host
    H = 'http://%s:%d' % (host, srv.port)
    S = 'https://%s:%d' % (host, srv.tls_port)
    # files for the long-URL test, put into a copy of the image
    img = os.path.join(DATA, 'seeded-%d.img' % srv.port)
    long_url = '%s/headers?x=' % H
    long_url += 'B' * (3900 - len(long_url))
    subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'seedfs.py'), image, img,
                    'long.url=@' + long_url], check=True)
    failed = []
    m = None
    try:
        m = Moos(uefi, nic, img, pcap, netdev)
        out = m.run('net up native' if native else 'net up', timeout=60)
        print(out.split('\n')[1:6] if 'Connected' not in out else 'network up')
        if 'Connected' not in out:
            print(out)
            sys.exit('net up failed')
        for name in names:
            fn = dict(TESTS)[name]
            t0 = time.time()
            try:
                ok, why = fn(m, srv, H, S)
            except Exception as e:      # noqa: BLE001
                ok, why = False, 'exception %r' % e
            print('%s %-14s %5.1fs %s' % ('PASS' if ok else 'FAIL', name, time.time() - t0, why),
                  flush=True)
            if not ok:
                failed.append(name)
                print('\n'.join(m.lines()))
    finally:
        if m:
            m.close()
        srv.close()
        if tap:
            tap.close()
        if not keep:
            os.remove(img)
    print('%d passed, %d failed %s' % (len(names) - len(failed), len(failed), ' '.join(failed)))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
