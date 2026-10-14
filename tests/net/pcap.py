#!/usr/bin/env python3
"""
Print the TCP segments in a capture made by "tests/net/run.py --pcap FILE"
(QEMU's filter-dump: every Ethernet frame between MOOS and QEMU's network).

    python3 tests/net/pcap.py FILE [--port N] [--from SECONDS] [--to SECONDS]
                                   [--summary]

One line per segment: time, direction (> from MOOS, < to MOOS), flags,
sequence and acknowledgement numbers relative to each side's SYN, payload
length, window (as sent, before scaling) and options of SYNs. --summary
prints counts per connection instead: segments, bytes, retransmissions
(a data segment that does not start past the highest sequence seen),
duplicate ACKs and the longest pause.
"""
import struct
import sys

FLAGS = 'FSRPAU'


def frames(path):
    data = open(path, 'rb').read()
    magic = struct.unpack('<I', data[:4])[0]
    endian = '<' if magic in (0xa1b2c3d4, 0xa1b23c4d) else '>'
    nano = magic in (0xa1b23c4d, 0x4d3cb2a1)
    pos = 24
    while pos + 16 <= len(data):
        sec, frac, incl, _orig = struct.unpack(endian + 'IIII', data[pos:pos + 16])
        pos += 16
        yield sec + frac / (1e9 if nano else 1e6), data[pos:pos + incl]
        pos += incl


def segments(path):
    """-> (time, src ip, sport, dst ip, dport, seq, ack, flags, win, payload len, options)"""
    for t, f in frames(path):
        if len(f) < 34 or f[12:14] != b'\x08\x00':
            continue
        ip = f[14:]
        ihl = (ip[0] & 15) * 4
        if ip[9] != 6:
            continue
        total = struct.unpack('>H', ip[2:4])[0]
        tcp = ip[ihl:total]
        if len(tcp) < 20:
            continue
        sport, dport, seq, ack, off, fl, win = struct.unpack('>HHIIBBH', tcp[:16])
        hl = (off >> 4) * 4
        yield (t, ip[12:16], sport, ip[16:20], dport, seq, ack, fl, win,
               len(tcp) - hl, tcp[20:hl])


def opts_text(o):
    out, i = [], 0
    while i < len(o):
        k = o[i]
        if k == 0:
            break
        if k == 1:
            i += 1
            continue
        if i + 1 >= len(o):
            break
        n = o[i + 1]
        if k == 2 and n == 4:
            out.append('mss=%d' % struct.unpack('>H', o[i + 2:i + 4])[0])
        elif k == 3 and n == 3:
            out.append('ws=%d' % o[i + 2])
        else:
            out.append('opt%d' % k)
        i += max(n, 2)
    return ' '.join(out)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    path = args.pop(0)
    port, t_from, t_to, summary = None, None, None, False
    while args:
        a = args.pop(0)
        if a == '--port':
            port = int(args.pop(0))
        elif a == '--from':
            t_from = float(args.pop(0))
        elif a == '--to':
            t_to = float(args.pop(0))
        elif a == '--summary':
            summary = True
    t0 = None
    base = {}            # (ip, port) -> its initial sequence number
    stats = {}
    for s in segments(path):
        t, sip, sp, dip, dp, seq, ack, fl, win, ln, opts = s
        if port and port not in (sp, dp):
            continue
        if t0 is None:
            t0 = t
        rel = t - t0
        moos = sip[3] == 15            # QEMU gives the guest 10.0.2.15
        key = (sp, dp) if moos else (dp, sp)   # (MOOS port, server port)
        me = (sip, sp)
        if fl & 2:
            base[me] = seq
        other = (dip, dp)
        rs = (seq - base.get(me, seq)) & 0xFFFFFFFF
        ra = (ack - base.get(other, ack)) & 0xFFFFFFFF if fl & 16 else 0
        st = stats.setdefault(key, {'segs': 0, 'bytes': [0, 0], 'rtx': [0, 0], 'top': [0, 0],
                                     'dup': [0, 0], 'last_ack': [None, None], 'gap': 0.0,
                                     'last_t': rel, 'first': rel})
        d = 0 if moos else 1
        st['segs'] += 1
        st['gap'] = max(st['gap'], rel - st['last_t'])
        st['last_t'] = rel
        if ln:
            st['bytes'][d] += ln
            if st['top'][d] and ((rs - st['top'][d]) & 0x80000000 or rs < st['top'][d]):
                st['rtx'][d] += 1
            end = rs + ln
            if end > st['top'][d]:
                st['top'][d] = end
        elif fl & 16 and not fl & 7:
            if st['last_ack'][d] == ra:
                st['dup'][d] += 1
            st['last_ack'][d] = ra
        if summary:
            continue
        if t_from is not None and rel < t_from:
            continue
        if t_to is not None and rel > t_to:
            break
        flags = ''.join(c for i, c in enumerate(FLAGS) if fl & (1 << i))
        print('%9.4f %s %5d %-5s seq=%-9d ack=%-9d len=%-5d win=%-5d %s' % (
            rel, '>' if moos else '<', key[0], flags, rs, ra, ln, win,
            opts_text(opts) if fl & 2 else ''))
    if summary:
        for (mp, srv), st in stats.items():
            print('MOOS port %d <-> %d: %d segments, %.2f s; data sent %d (%d resent), '
                  'received %d (%d resent); dup ACKs from MOOS %d, from the server %d; '
                  'longest pause %.2f s' % (
                      mp, srv, st['segs'], st['last_t'] - st['first'], st['bytes'][0],
                      st['rtx'][0], st['bytes'][1], st['rtx'][1], st['dup'][0], st['dup'][1],
                      st['gap']))


if __name__ == '__main__':
    main()
