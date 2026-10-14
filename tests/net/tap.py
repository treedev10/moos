#!/usr/bin/env python3
"""
A private Ethernet link between QEMU and this computer's own TCP/IP stack,
for testing MOOS's TCP against a real one (Linux: window scaling, SACK,
fast retransmit, timestamps ...) instead of QEMU's user networking, which
does TCP itself and simply.

    tap = Tap(n)        # a tap device "mtapN", host address 10.9.N.1/24,
                        # and a DHCP server that gives MOOS 10.9.N.2
    qemu ... -netdev tap,id=n0,ifname=mtapN,script=no,downscript=no
    tap.close()         # the device goes away

Needs root (CAP_NET_ADMIN) and /dev/net/tun. Used by run.py --tap.
"""
import fcntl
import os
import socket
import struct
import threading

TUNSETIFF = 0x400454ca
TUNSETPERSIST = 0x400454cb
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000
SIOCSIFADDR = 0x8916
SIOCSIFNETMASK = 0x891c
SIOCGIFFLAGS = 0x8913
SIOCSIFFLAGS = 0x8914
SO_BINDTODEVICE = 25


def available():
    return os.path.exists('/dev/net/tun') and os.geteuid() == 0


class Tap:
    def __init__(self, n):
        self.n = n
        self.name = 'mtap%d' % n
        self.host = '10.9.%d.1' % n
        self.guest = '10.9.%d.2' % n
        self._persist(1)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        name = self.name.encode()
        fcntl.ioctl(s, SIOCSIFADDR, self._sin(self.host))
        fcntl.ioctl(s, SIOCSIFNETMASK, self._sin('255.255.255.0'))
        flags = struct.unpack('16sH', fcntl.ioctl(s, SIOCGIFFLAGS, struct.pack('16sH', name, 0)))[1]
        fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack('16sH', name, flags | 1))     # up
        s.close()
        self.stop = False
        self.dhcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.dhcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.dhcp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.dhcp.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, name)
        self.dhcp.bind(('0.0.0.0', 67))
        self.dhcp.settimeout(0.5)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _sin(self, ip):
        return struct.pack('16sH2s4s8s', self.name.encode(), socket.AF_INET, b'\0\0',
                           socket.inet_aton(ip), b'\0' * 8)

    def _persist(self, on):
        fd = os.open('/dev/net/tun', os.O_RDWR)
        try:
            fcntl.ioctl(fd, TUNSETIFF, struct.pack('16sH', self.name.encode(), IFF_TAP | IFF_NO_PI))
            fcntl.ioctl(fd, TUNSETPERSIST, on)
        finally:
            os.close(fd)

    def qemu_netdev(self):
        return 'tap,id=n0,ifname=%s,script=no,downscript=no' % self.name

    def _serve(self):
        """Answer DISCOVER with OFFER and REQUEST with ACK (RFC 2131)."""
        while not self.stop:
            try:
                msg, _ = self.dhcp.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(msg) < 240 or msg[0] != 1 or msg[236:240] != b'\x63\x82\x53\x63':
                continue
            kind, i = None, 240
            while i < len(msg) and msg[i] != 255:
                if msg[i] == 0:
                    i += 1
                    continue
                if i + 1 >= len(msg):
                    break
                if msg[i] == 53:
                    kind = msg[i + 2]
                i += 2 + msg[i + 1]
            reply = {1: 2, 3: 5}.get(kind)          # DISCOVER -> OFFER, REQUEST -> ACK
            if not reply:
                continue
            out = bytearray(240)
            out[0], out[1], out[2] = 2, 1, 6
            out[4:8] = msg[4:8]                      # xid
            out[10:12] = msg[10:12]                  # flags
            out[16:20] = socket.inet_aton(self.guest)
            out[20:24] = socket.inet_aton(self.host)
            out[28:44] = msg[28:44]                  # client MAC
            out[236:240] = b'\x63\x82\x53\x63'
            ip = socket.inet_aton(self.host)
            out += bytes([53, 1, reply, 54, 4]) + ip
            out += bytes([1, 4]) + socket.inet_aton('255.255.255.0')
            out += bytes([3, 4]) + ip + bytes([6, 4]) + ip
            out += bytes([51, 4]) + struct.pack('>I', 86400) + bytes([255])
            try:
                self.dhcp.sendto(bytes(out), ('255.255.255.255', 68))
            except OSError:
                pass

    def close(self):
        self.stop = True
        self.thread.join(2)
        self.dhcp.close()
        try:
            self._persist(0)
        except OSError:
            pass
