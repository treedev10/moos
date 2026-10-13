#!/usr/bin/env python3
"""
Headless test driver for MOOS: boots a copy of the image in QEMU without a
window, types keys through the QEMU monitor and prints MOOS's 80x25 screen.

    python tools/screentest.py [options] STEP [STEP ...]

Options
    --image IMG     disk image to copy and start (default build/moos.img)
    --uefi          start the PC with UEFI firmware instead of a BIOS
    --drive ARGS    replace the QEMU disk arguments; {disk} stands for the
                    copied image, e.g. "-machine q35 -drive file={disk},format=raw"
    --extra ARGS    more QEMU arguments (a second disk, a USB keyboard, ...)
    --mem MB        memory size

STEP is either text to type (use \\n for Enter) or a command:
    @screen         print the screen (MOOS's own copy of it, found in memory)
    @png=FILE       save a real screenshot of the display as PNG
    @wait=SECONDS   pause
    @key=NAME       press a QEMU key name (up, down, tab, esc, ctrl-c, ...)
    @exit           check that QEMU has exited (after "shutdown")

The image is copied first, so tests never touch your real disk image.
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from build import qemu_path, ovmf_paths, IMAGE  # noqa: E402

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
           '*': '8', '(': '9', ')': '0', '_': 'minus', '+': 'equal',
           ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot',
           '?': 'slash', '{': 'bracket_left', '}': 'bracket_right',
           '|': 'backslash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '\n': 'ret', '.': 'dot', ',': 'comma', '/': 'slash',
         '-': 'minus', '=': 'equal', ';': 'semicolon', "'": 'apostrophe',
         '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
         '`': 'grave_accent', '\t': 'tab'}
MAGIC = b'MOOSSCRN'


def key_for(ch):
    if ch.isalpha() and ch.isascii():
        return ('shift-' + ch.lower()) if ch.isupper() else ch
    if ch.isdigit():
        return ch
    if ch in PLAIN:
        return PLAIN[ch]
    if ch in SHIFTED:
        return 'shift-' + SHIFTED[ch]
    raise ValueError('no key for %r' % ch)


class Monitor:
    def __init__(self, port):
        for _ in range(100):
            try:
                self.sock = socket.create_connection(('127.0.0.1', port), timeout=30)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError('cannot reach the QEMU monitor')
        self.read_prompt()

    def read_prompt(self):
        data = b''
        while not data.endswith(b'(qemu) '):
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    def cmd(self, text):
        self.sock.sendall(text.encode() + b'\n')
        return self.read_prompt()


class Screen:
    """Finds MOOS's copy of the screen in guest memory by its marker."""

    def __init__(self, mon, tmpdir, mem_mb):
        self.mon, self.tmpdir, self.mem = mon, tmpdir, mem_mb << 20
        self.addr = None

    def dump(self, addr, size):
        path = os.path.join(self.tmpdir, 'mem.bin').replace('\\', '/')
        self.mon.cmd('pmemsave %#x %d "%s"' % (addr, size, path))
        for _ in range(50):
            if os.path.exists(path) and os.path.getsize(path) == size:
                break
            time.sleep(0.05)
        data = open(path, 'rb').read()
        os.remove(path)
        return data

    def find(self, timeout=40):
        end = time.time() + timeout
        while time.time() < end:
            chunk = 16 << 20
            for base in range(0, self.mem, chunk):
                data = self.dump(base, chunk)
                at = data.find(MAGIC)
                while at >= 0 and at % 16:
                    at = data.find(MAGIC, at + 1)
                if at >= 0:
                    self.addr = base + at + 16
                    return
            time.sleep(1)
        raise RuntimeError('MOOS screen not found in memory (did it start?)')

    def text(self):
        if self.addr is not None:
            if self.dump(self.addr - 16, 8) != MAGIC:
                self.addr = None                  # restarted: look again
        if self.addr is None:
            self.find()
        data = self.dump(self.addr, 4000)
        rows = []
        for r in range(25):
            line = bytes(data[(r * 80 + c) * 2] for c in range(80))
            rows.append(line.decode('cp437').rstrip())
        return rows


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    args = sys.argv[1:]
    image, drive, extra, uefi, mem = IMAGE, None, '', False, None
    while args and args[0].startswith('--'):
        opt = args.pop(0)
        if opt == '--uefi':
            uefi = True
        elif opt == '--image':
            image = args.pop(0)
        elif opt == '--drive':
            drive = args.pop(0)
        elif opt == '--extra':
            extra = args.pop(0)
        elif opt == '--mem':
            mem = int(args.pop(0))
        else:
            sys.exit('unknown option ' + opt)
    mem = mem or (256 if uefi else 32)
    drive = drive or '-drive file={disk},format=raw,index=0,media=disk'
    tmpdir = tempfile.mkdtemp(prefix='moostest')
    disk = os.path.join(tmpdir, 'disk' + os.path.splitext(image)[1])
    shutil.copy(image, disk)
    port = 45454
    cmd = [qemu_path()] + drive.replace('{disk}', disk).split() + extra.split() + \
        ['-m', str(mem), '-rtc', 'base=localtime', '-display', 'none',
         '-netdev', 'user,id=n0', '-device', 'rtl8139,netdev=n0',
         '-monitor', 'tcp:127.0.0.1:%d,server,nowait' % port]
    if uefi:
        code, vars_file = ovmf_paths()
        vars_copy = os.path.join(tmpdir, 'vars.fd')
        shutil.copy(vars_file, vars_copy)
        cmd += ['-drive', 'if=pflash,format=raw,readonly=on,file=%s' % code,
                '-drive', 'if=pflash,format=raw,file=%s' % vars_copy]
    proc = subprocess.Popen(cmd)
    try:
        mon = Monitor(port)
        screen = Screen(mon, tmpdir, mem)
        screen.find()                             # wait until MOOS is up
        time.sleep(1.0)
        for step in args:
            if step == '@screen':
                print('+' + '-' * 80 + '+')
                for line in screen.text():
                    print('|' + line.ljust(80) + '|')
                print('+' + '-' * 80 + '+')
            elif step.startswith('@png='):
                ppm = os.path.join(tmpdir, 'shot.ppm').replace('\\', '/')
                mon.cmd('screendump "%s"' % ppm)
                time.sleep(0.5)
                from PIL import Image
                Image.open(ppm).save(step[5:])
                print('screenshot saved:', step[5:])
            elif step.startswith('@wait='):
                time.sleep(float(step[6:]))
            elif step.startswith('@key='):
                mon.cmd('sendkey ' + step[5:])
                time.sleep(0.2)
            elif step == '@exit':
                try:
                    proc.wait(timeout=10)
                    print('QEMU exited with code', proc.returncode)
                except subprocess.TimeoutExpired:
                    print('QEMU is still running')
            else:
                for ch in step.encode().decode('unicode_escape'):
                    mon.cmd('sendkey ' + key_for(ch))
                    time.sleep(0.04)
                time.sleep(0.5)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    main()
