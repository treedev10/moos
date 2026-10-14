#!/usr/bin/env python3
"""
Headless test driver for MOOS: boots a copy of the image in QEMU without a
window, types keys through the QEMU monitor and prints MOOS's 80x25 screen.

    python tools/screentest.py [options] STEP [STEP ...]

Options
    --image IMG     disk image to copy and start (default build/moos.img)
    --save IMG      when done, keep the test's disk as IMG (to start it
                    again with --image, e.g. to check files survive)
    --uefi          start the PC with UEFI firmware instead of a BIOS
    --drive ARGS    replace the QEMU disk arguments; {disk} stands for the
                    copied image, e.g. "-machine q35 -drive file={disk},format=raw"
    --extra ARGS    more QEMU arguments (a second disk, a USB keyboard, ...)
    --nic MODEL     the emulated network card: rtl8139 (default), e1000,
                    e1000e, virtio-net-pci, ...; "none" for no card
    --mem MB        memory size
    --audio FILE    add an Intel HD Audio card (and its output) and record
                    what MOOS plays into FILE (a .wav)
    --ac97 FILE     the same with an AC'97 card

STEP is either text to type (use \\n for Enter) or a command:
    @screen         print the screen (MOOS's own copy of it, found in memory)
    @png=FILE       save a real screenshot of the display as PNG
    @wait=SECONDS   pause
    @key=NAME       press a QEMU key name (up, down, tab, esc, ctrl-c, ...)
    @mouse=DX,DY    move the mouse (needs a mouse, e.g. --extra
                    "-device qemu-xhci -device usb-mouse")
    @click          press and release the left mouse button
    @ptr=X,Y[,B]    put MOOS's own mouse at X,Y with button B (1 = held,
                    0 = up) by writing its memory through QEMU's gdbstub.
                    QEMU's UEFI firmware has no mouse driver at all, so
                    this is how the desktop's mouse handling is tested.
                    Several in a row make a drag.
    @wheel=N        turn MOOS's mouse wheel N notches (+ = away from you)
    @mon=COMMAND    run a QEMU monitor command and print its answer
    @where          print where the CPU is in the kernel (label + offset),
                    e.g. to see where MOOS hangs
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


def kernel_symbols(names):
    """Addresses of kernel labels (as assembled at 0x10000), from a NASM map."""
    tmp = tempfile.mkdtemp(prefix='moosmap')
    try:
        wrap = os.path.join(tmp, 'wrap.asm')
        with open(wrap, 'w') as f:
            f.write('[map symbols %s]\n%%include "src/kernel.asm"\n'
                    % os.path.join(tmp, 'k.map').replace('\\', '/'))
        subprocess.run(['nasm', '-f', 'bin', '-w-error=label-redef-late', '-DFULL', wrap,
                        '-o', os.path.join(tmp, 'k.bin')], cwd=ROOT, check=True)
        found = {}
        for line in open(os.path.join(tmp, 'k.map')):
            parts = line.split()
            if len(parts) == 3 and parts[2] in names:
                try:
                    found[parts[2]] = int(parts[0], 16)
                except ValueError:      # (a heading line of the map)
                    pass
        return found
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


class Gdb:
    """Just enough of the GDB remote protocol to write guest memory."""

    def __init__(self, port):
        for _ in range(100):
            try:
                self.sock = socket.create_connection(('127.0.0.1', port), timeout=30)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError('cannot reach the QEMU gdbstub')
        self.buf = b''
        self.packet('?')                       # QEMU stopped the guest for us
        self.go()

    def read_packet(self):
        while True:
            start = self.buf.find(b'$')
            end = self.buf.find(b'#', start)
            if start >= 0 and end >= 0 and len(self.buf) >= end + 3:
                data = self.buf[start + 1:end]
                self.buf = self.buf[end + 3:]
                self.sock.sendall(b'+')
                return data
            self.buf += self.sock.recv(4096)

    def send(self, text):
        data = text.encode()
        self.sock.sendall(b'$%s#%02x' % (data, sum(data) & 0xFF))

    def packet(self, text):
        self.send(text)
        return self.read_packet()

    def go(self):
        self.send('c')

    def write(self, addr, data):
        self.sock.sendall(b'\x03')            # stop the guest
        self.read_packet()
        reply = self.packet('M%x,%x:%s' % (addr, len(data), data.hex()))
        self.go()
        if reply != b'OK':
            raise RuntimeError('gdbstub write failed: %r' % reply)


def free_port():
    """A TCP port nobody uses now (so several tests can run at once)."""
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


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
    image, drive, extra, uefi, mem, nic = IMAGE, None, '', False, None, 'rtl8139'
    audio = None
    save = None
    while args and args[0].startswith('--'):
        opt = args.pop(0)
        if opt == '--uefi':
            uefi = True
        elif opt == '--image':
            image = args.pop(0)
        elif opt == '--save':
            save = args.pop(0)
        elif opt == '--drive':
            drive = args.pop(0)
        elif opt == '--extra':
            extra = args.pop(0)
        elif opt == '--mem':
            mem = int(args.pop(0))
        elif opt == '--nic':
            nic = args.pop(0)
        elif opt in ('--audio', '--ac97'):
            audio = (opt, os.path.abspath(args.pop(0)))
        else:
            sys.exit('unknown option ' + opt)
    mem = mem or (256 if uefi else 32)
    drive = drive or '-drive file={disk},format=raw,index=0,media=disk'
    tmpdir = tempfile.mkdtemp(prefix='moostest')
    disk = os.path.join(tmpdir, 'disk' + os.path.splitext(image)[1])
    shutil.copy(image, disk)
    port = free_port()
    gdb_port = free_port()
    want_ptr = any(a.startswith(('@ptr=', '@wheel=')) for a in args)
    cmd = [qemu_path()] + drive.replace('{disk}', disk).split() + extra.split() + \
        ['-m', str(mem), '-rtc', 'base=localtime', '-display', 'none',
         '-cpu', 'max', '-monitor', 'tcp:127.0.0.1:%d,server,nowait' % port]
    if want_ptr:
        syms = kernel_symbols({'screen_magic', 'mouse_x', 'mouse_wheel'})
        cmd += ['-gdb', 'tcp:127.0.0.1:%d' % gdb_port]
    gdb = None
    if audio:
        dev = ['-device', 'intel-hda', '-device', 'hda-output,audiodev=snd0'] \
            if audio[0] == '--audio' else ['-device', 'AC97,audiodev=snd0']
        cmd += ['-audiodev', 'wav,id=snd0,path=%s' % audio[1]] + dev
    if nic == 'none':
        cmd += ['-nic', 'none']         # (else QEMU adds an e1000 by itself)
    else:
        cmd += ['-netdev', 'user,id=n0', '-device', nic + ',netdev=n0']
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
            elif step.startswith('@mouse='):
                dx, dy = step[7:].split(',')
                mon.cmd('mouse_move %d %d' % (int(dx), int(dy)))
                time.sleep(0.3)
            elif step.startswith('@mon='):
                out = mon.cmd(step[5:]).decode('utf-8', 'replace')
                out = ''.join(c for c in out if c == '\n' or c >= ' ')
                print(out.replace('(qemu) ', '').strip())
            elif step.startswith(('@ptr=', '@wheel=')):
                if gdb is None:
                    gdb = Gdb(gdb_port)
                base = screen.addr - 16 - syms['screen_magic']   # where MOOS is
                if step.startswith('@wheel='):
                    gdb.write(base + syms['mouse_wheel'],
                              int(step[7:]).to_bytes(4, 'little', signed=True))
                else:
                    v = [int(x) for x in step[5:].split(',')] + [0]
                    gdb.write(base + syms['mouse_x'],
                              b''.join(int(x).to_bytes(4, 'little') for x in v[:3]))
                time.sleep(0.15)
            elif step == '@where':
                class Every:
                    def __contains__(self, name):
                        return True
                if 'all' not in globals():
                    globals()['all_syms'] = kernel_symbols(Every())
                allsyms = globals()['all_syms']
                out = mon.cmd('info registers').decode('utf-8', 'replace')
                eip = int(out.split('EIP=')[1][:8], 16)
                base = screen.addr - 16 - allsyms['screen_magic']
                rel = eip - base
                best = max(((a, n) for n, a in allsyms.items() if a <= rel),
                           default=(0, '?'))
                print('EIP %#x = %s+%#x' % (eip, best[1], rel - best[0]))
            elif step == '@click':
                mon.cmd('mouse_button 1')
                time.sleep(0.2)
                mon.cmd('mouse_button 0')
                time.sleep(0.3)
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
        if save:
            shutil.copy(disk, save)
            print('disk saved:', save)
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    main()
