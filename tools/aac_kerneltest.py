#!/usr/bin/env python3
"""
Run the AAC decoder inside the real UEFI kernel and check what it decodes.

    python tools/aac_kerneltest.py [--frames N] [case ...]

The native test (tests/native/run.py aac) checks src/aac.asm built as a
Linux object. This one checks the copy that is assembled into the full
kernel, where it runs as MOOS runs it: relocated by the UEFI loader, in
32-bit compatibility mode, with the firmware's SSE and x87 set-up.

How: build/moos.img is booted with UEFI in QEMU (with its gdbstub). A
breakpoint on status_tick (which the shell calls twice a second while it
waits for a key) stops the guest in MOOS's own 32-bit code. There the
registers are saved, and aac_init, aac_info and aac_decode of the kernel
are called directly: the arguments, a return address (with a breakpoint),
a stack, the context and the buffers are put into the kernel's download
buffer (PKG_BUF, unused at the shell prompt). After the last call the
saved registers are put back and MOOS carries on.

For each case (default: a few, see CASES) the first N frames (default 60)
are decoded; the 16-bit output must be identical to the native build's
(tests/native/run.py aac --dump) - same code, same arithmetic - and, like
the native test, at least 70 dB SNR against ffmpeg's decode (PNS cases:
the native and kernel output must still be identical, because the noise
generator is the same).

Needs the test data from tests/native/aac_make.py and a built image
(python build.py).
"""
import os
import socket
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tests", "native"))
import screentest as st                     # noqa: E402
import aac_make                             # noqa: E402

DATA = os.path.join(ROOT, "build", "aac")
CASES = ["music_44100_s", "speech_64k_m", "clicks_128k", "is_wide_64k", "pns_pink_64k",
         "multi_6ch", "music_44100_s_cce", "music_44100_s_pulses", "speech_64k_m_sbr5"]
PKG_BUF = 0x630000                          # (kernel.asm, FULL memory map)
# where things go, from PKG_BUF
O_CTX, O_STACK, O_RET, O_INFO, O_ASC, O_FRAME, O_OUT = (0x0, 0x30000, 0x30000, 0x30200,
                                                        0x30400, 0x31000, 0x34000)


class Gdb(st.Gdb):
    """The GDB remote protocol, enough to stop the guest, read and write
    memory and registers, and run until a breakpoint."""

    def __init__(self, port):
        super().__init__(port)                  # (leaves the guest running)
        self.running = True
        # small packets in both directions: without this, each one waits
        # about 40 ms for a delayed TCP acknowledgement
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def stop(self):
        if self.running:
            self.sock.sendall(b'\x03')
            self.read_packet()
            self.running = False

    def cont(self, timeout=20):
        """continue until the guest stops (a breakpoint); False on timeout"""
        self.send('c')
        self.running = True
        self.sock.settimeout(timeout)
        try:
            reply = self.read_packet()
        except OSError:
            return False
        finally:
            self.sock.settimeout(30)
        self.running = False
        return reply.startswith((b'T', b'S'))

    def mem_write(self, addr, data):
        for i in range(0, len(data), 1024):
            part = data[i:i + 1024]
            r = self.packet('M%x,%x:%s' % (addr + i, len(part), part.hex()))
            if r != b'OK':
                raise RuntimeError('memory write failed: %r' % r)

    def mem_read(self, addr, n):
        out = b''
        while len(out) < n:
            part = min(1024, n - len(out))
            r = self.packet('m%x,%x' % (addr + len(out), part))
            if len(r) != 2 * part:
                raise RuntimeError('memory read failed: %r' % r[:40])
            out += bytes.fromhex(r.decode())
        return out

    def regs(self):
        return bytes.fromhex(self.packet('g').decode())

    def set_reg(self, n, value, size=8):
        """write one register (number n of the 'g' layout). Not the whole
        set with 'G': in 32-bit compatibility mode QEMU 8 reads some of the
        segment and control registers in one size and writes them in
        another, so a 'G' of what 'g' gave shifts CR0 into CR4 and turns
        paging off."""
        r = self.packet('P%x=%s' % (n, (value & ((1 << (8 * size)) - 1))
                                    .to_bytes(size, 'little').hex()))
        if r != b'OK':
            raise RuntimeError('register write failed: %r' % r)

    def breakpoint(self, addr, on=True):
        r = self.packet('%s1,%x,1' % ('Z' if on else 'z', addr))
        if r != b'OK':
            raise RuntimeError('breakpoint failed: %r' % r)


# x86-64 'g' layout (QEMU): rax rbx rcx rdx rsi rdi rbp rsp r8-r15 rip
# (8 bytes each), eflags, cs, ... (4 bytes each). Register numbers for 'P':
# 0-7 rax..rsp, 16 rip, 17 eflags.
R_RAX, R_RSP, R_RIP = 0, 7 * 8, 16 * 8
N_RSP, N_RIP, N_EFLAGS = 7, 16, 17


def restore(gdb, saved):
    """put back the eight 32-bit registers, EIP and EFLAGS saved from 'g'
    (the decoder changes nothing else: segments, control registers and the
    FPU control words are as they were)"""
    for n in range(8):
        gdb.set_reg(n, struct.unpack_from('<Q', saved, n * 8)[0])
    gdb.set_reg(N_RIP, struct.unpack_from('<Q', saved, R_RIP)[0])
    gdb.set_reg(N_EFLAGS, struct.unpack_from('<I', saved, 17 * 8)[0], 4)


class Kernel:
    """calls into the kernel's copy of the decoder"""

    def __init__(self, gdb, base, syms, saved):
        self.gdb, self.base, self.syms, self.saved = gdb, base, syms, saved
        self.buf = base + PKG_BUF
        gdb.mem_write(self.buf + O_RET, b'\xF4' * 16)         # (never run)
        gdb.breakpoint(self.buf + O_RET)

    def call(self, name, *args):
        """C call: the arguments and the return address on our stack"""
        sp = self.buf + O_STACK - 64
        self.gdb.mem_write(sp, struct.pack('<%dI' % (len(args) + 1), self.buf + O_RET, *args))
        self.gdb.set_reg(N_RSP, sp)
        self.gdb.set_reg(N_RIP, self.base + self.syms[name])
        if not self.gdb.cont():
            raise RuntimeError('%s did not return (crash or hang in the kernel)' % name)
        regs = self.gdb.regs()
        rip = struct.unpack_from('<Q', regs, R_RIP)[0]
        if rip != self.buf + O_RET:
            raise RuntimeError('%s stopped at %#x' % (name, rip))
        if struct.unpack_from('<Q', regs, R_RSP)[0] != sp + 4:
            raise RuntimeError('%s returned with a different stack' % name)
        for n, reg in ((1, 'EBX'), (4, 'ESI'), (5, 'EDI'), (6, 'EBP')):
            if regs[n * 8:n * 8 + 4] != self.saved[n * 8:n * 8 + 4]:
                raise RuntimeError('%s did not keep %s' % (name, reg))
        return struct.unpack_from('<i', regs, R_RAX)[0]


def native_pcm(case):
    out = os.path.join(ROOT, "build", "native", case + ".pcm")
    subprocess.run([sys.executable, os.path.join(ROOT, "tests", "native", "run.py"), "aac",
                    "--dump", case, out], check=True, capture_output=True)
    return open(out, "rb").read()


def snr(a, ref):
    import numpy as np
    a = np.frombuffer(a, "<i2").astype(float)
    ref = np.frombuffer(ref, "<i2").astype(float)[:len(a)]
    e = ((a - ref) ** 2).sum()
    return 99.0 if e == 0 else 10 * np.log10((ref ** 2).sum() / e)


def run_case(k, case, nframes):
    frames = aac_make.adts_frames(open(os.path.join(DATA, case + ".adts"), "rb").read())
    frames = [raw for _, raw in frames][:nframes]
    asc = open(os.path.join(DATA, case + ".asc"), "rb").read()
    g, buf = k.gdb, k.buf
    g.mem_write(buf + O_ASC, asc)
    r = k.call("aac_init", buf + O_CTX, buf + O_ASC, len(asc))
    if r < 0:
        return "FAIL %-24s kernel aac_init returned %d" % (case, r)
    k.call("aac_info", buf + O_CTX, buf + O_INFO, buf + O_INFO + 4)
    rate, ch = struct.unpack('<II', g.mem_read(buf + O_INFO, 8))
    pcm = b''
    t0 = time.time()
    for i, raw in enumerate(frames):
        g.mem_write(buf + O_FRAME, raw)
        r = k.call("aac_decode", buf + O_CTX, buf + O_FRAME, len(raw), buf + O_OUT)
        if r != 1024:
            return "FAIL %-24s frame %d: kernel aac_decode returned %d" % (case, i, r)
        pcm += g.mem_read(buf + O_OUT, 1024 * ch * 2)
    # damaged frames (empty, cut short, too long): an error code each, and
    # the next good frame still decodes
    errors = []
    for b in (b'', frames[1][:len(frames[1]) // 3], b'\0' * 9000):
        g.mem_write(buf + O_FRAME, b)
        errors.append(k.call("aac_decode", buf + O_CTX, buf + O_FRAME, len(b), buf + O_OUT))
    g.mem_write(buf + O_FRAME, frames[3])
    after = k.call("aac_decode", buf + O_CTX, buf + O_FRAME, len(frames[3]), buf + O_OUT)
    nat = native_pcm(case)[:len(pcm)]
    refname = case
    for line in open(os.path.join(DATA, "manifest.txt")):
        f = line.split()
        if f and f[0] == case and len(f) > 2 and f[1] == "same":
            refname = f[2]
    ref = open(os.path.join(DATA, refname + ".ref"), "rb").read()
    same = pcm == nat
    s = snr(pcm, ref)
    pns = "pns" in case
    ok = same and (pns or s >= 70) and all(e < 0 for e in errors) and after == 1024
    return "%s %-24s %u Hz %u ch, %d frames: %s native build, SNR %.2f dB vs ffmpeg%s; " \
           "bad frames -> %s, next good frame -> %d  (%.1f s)" % (
               "ok  " if ok else "FAIL", case, rate, ch, len(frames),
               "identical to" if same else "DIFFERENT from", s, " (PNS)" if pns else "",
               errors, after, time.time() - t0)


def main():
    args = sys.argv[1:]
    nframes = 60
    if args[:1] == ["--frames"]:
        nframes = int(args[1])
        args = args[2:]
    cases = args or CASES
    syms = st.kernel_symbols({"screen_magic", "status_tick", "aac_init", "aac_info",
                              "aac_decode"})
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="aackt")
    disk = os.path.join(tmp, "disk.img")
    shutil.copy(st.IMAGE, disk)
    code, vars_file = st.ovmf_paths()
    shutil.copy(vars_file, os.path.join(tmp, "vars.fd"))
    mport, gport = st.free_port(), st.free_port()
    cmd = [st.qemu_path(), "-drive", "file=%s,format=raw,index=0,media=disk" % disk,
           "-m", "256", "-display", "none", "-cpu", "max", "-nic", "none",
           "-monitor", "tcp:127.0.0.1:%d,server,nowait" % mport,
           "-gdb", "tcp:127.0.0.1:%d" % gport,
           "-drive", "if=pflash,format=raw,readonly=on,file=%s" % code,
           "-drive", "if=pflash,format=raw,file=%s" % os.path.join(tmp, "vars.fd")]
    proc = subprocess.Popen(cmd)
    failures = 0
    try:
        mon = st.Monitor(mport)
        screen = st.Screen(mon, tmp, 256)
        screen.find()
        time.sleep(1)
        base = screen.addr - 16 - syms["screen_magic"]      # where MOOS was put
        gdb = Gdb(gport)
        gdb.stop()
        gdb.breakpoint(base + syms["status_tick"])
        if not gdb.cont(10):
            sys.exit("the shell never called status_tick")
        gdb.breakpoint(base + syms["status_tick"], False)
        saved = gdb.regs()
        print("stopped in MOOS at %#x (kernel moved by %#x)"
              % (struct.unpack_from('<Q', saved, R_RIP)[0], base))
        k = Kernel(gdb, base, syms, saved)
        for case in cases:
            line = run_case(k, case, nframes)
            print(line)
            failures += not line.startswith("ok")
        gdb.breakpoint(k.buf + O_RET, False)
        restore(gdb, saved)                                  # MOOS carries on
        gdb.send('c')
        time.sleep(1)
        # MOOS must still work: type a command and look for its output
        for ch in "echo aac kernel test done\n":
            mon.cmd('sendkey ' + st.key_for(ch))
        time.sleep(2)
        rows = screen.text()
        alive = "aac kernel test done" in rows
        print("%s MOOS still runs after the calls (a typed echo command printed its text)"
              % ("ok  " if alive else "FAIL"))
        failures += not alive
    finally:
        proc.kill()
        proc.wait()
        shutil.rmtree(tmp, ignore_errors=True)
    print("all kernel checks passed" if not failures else "%d case(s) failed" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
