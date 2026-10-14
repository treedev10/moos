#!/usr/bin/env python3
"""
Look at a WAV file recorded from MOOS (screentest.py --audio / --ac97) and
say what is in it: the tones, how long each lasts, the silences between
them, and clicks (places where the wave jumps, as when samples are lost
or old sound is played again).

    python tools/wavcheck.py FILE [--expect 440:1,880:1] [--tol 0.05]
                                  [--max-gap 0.05] [--quiet]

--expect    the tones that should be heard, in order, as HZ:SECONDS. The
            check fails if other tones are heard (old sound played again
            sounds like a tone too), if a tone is missing, if a duration
            is off by more than --tol seconds, or if there is a click.
--max-gap   the longest silence allowed between two expected tones
            (seconds); default: no limit.
Prints one line per piece ("tone 440.0 Hz  0.000 - 1.002 s ..."), then
OK or FAIL with the reasons; the exit code is 0 for OK.

QEMU writes the WAV header only when it exits cleanly; a file whose sizes
were never filled in is read anyway (everything after the header).
"""
import struct
import sys

import numpy as np

WIN = 0.010             # analysis window, seconds
SILENT = 200.0          # RMS below this (of 32768) counts as silence


def read_wav(path):
    """-> (rate, channels, samples as float array [frames, channels])"""
    data = open(path, 'rb').read()
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        sys.exit('%s: not a WAV file' % path)
    pos, rate, chans, bits, pcm = 12, 44100, 2, 16, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b'fmt ':
            _, chans, rate, _, _, bits = struct.unpack('<HHIIHH', data[body:body + 16])
        elif cid == b'data':
            end = body + size if size else len(data)        # (unfinished file)
            pcm = data[body:end]
            break
        pos = body + size + (size & 1)
    if pcm is None or bits != 16:
        sys.exit('%s: no 16-bit PCM data' % path)
    a = np.frombuffer(pcm[:len(pcm) // (2 * chans) * 2 * chans], dtype='<i2')
    return rate, chans, a.reshape(-1, chans).astype(np.float64)


def tone_of(block, rate):
    """-> (frequency in Hz, RMS) of one window (left channel)"""
    rms = float(np.sqrt(np.mean(block ** 2)))
    if rms < SILENT:
        return 0.0, rms
    n = len(block) * 8
    spec = np.abs(np.fft.rfft(block * np.hanning(len(block)), n))
    k = int(np.argmax(spec[1:])) + 1
    if 1 <= k < len(spec) - 1:                  # parabolic peak fit
        a, b, c = spec[k - 1], spec[k], spec[k + 1]
        d = (a - c) / (2 * (a - 2 * b + c)) if (a - 2 * b + c) else 0.0
        k = k + d
    return k * rate / n, rms


def segments(x, rate):
    """Split into pieces of one tone or of silence -> [(freq, start, end, rms)]"""
    w = int(rate * WIN)
    out = []
    for i in range(0, len(x) - w + 1, w):
        f, r = tone_of(x[i:i + w, 0], rate)
        t0, t1 = i / rate, (i + w) / rate
        if out and ((f == 0 and out[-1][0] == 0) or
                    (f and out[-1][0] and abs(f - out[-1][0]) < 0.06 * out[-1][0])):
            pf, ps, _, pr = out[-1]
            out[-1] = (pf, ps, t1, max(pr, r))
        else:
            out.append((f, t0, t1, r))
    # windows that straddle a change of tone come out as short odd pieces:
    # fold pieces under 2 windows into a neighbour
    merged = []
    for s in out:
        if merged and s[2] - s[1] < 2.5 * WIN and s[0] != 0:
            pf, ps, _, pr = merged[-1]
            merged[-1] = (pf, ps, s[2], pr)
        else:
            merged.append(s)
    return merged


def refine_edges(x, rate, start, end):
    """The exact first and last sample above silence near a piece's ends"""
    lo, hi = max(0, int((start - WIN) * rate)), min(len(x), int((end + WIN) * rate))
    loud = np.nonzero(np.abs(x[lo:hi, 0]) > 64)[0]
    if len(loud) == 0:
        return start, end
    return (lo + loud[0]) / rate, (lo + loud[-1] + 1) / rate


def clicks(x, rate, start, end, fmax):
    """Places in a tone where the wave jumps more than a sine of that
    frequency and level can (by the second difference) -> list of times.
    fmax = per sample, the highest frequency playing near it."""
    a, b = int(start * rate) + 2, int(end * rate) - 2
    if b - a < 16:
        return []
    seg = x[a:b, 0]
    peak = np.max(np.abs(seg))
    w = 2 * np.pi * fmax[a + 1:b - 1] / rate
    limit = 3.0 * peak * w * w + 40          # (rounding)
    d2 = np.abs(np.diff(seg, 2))
    bad = np.nonzero(d2 > limit)[0]
    times, last = [], -1
    for i in bad:
        if i - last > rate * 0.005:
            times.append((a + i) / rate)
        last = i
    return times


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    path, expect, tol, max_gap, quiet = args.pop(0), None, 0.05, None, False
    while args:
        opt = args.pop(0)
        if opt == '--expect':
            expect = [tuple(float(v) for v in p.split(':')) for p in args.pop(0).split(',')]
        elif opt == '--tol':
            tol = float(args.pop(0))
        elif opt == '--max-gap':
            max_gap = float(args.pop(0))
        elif opt == '--quiet':
            quiet = True
        else:
            sys.exit('unknown option ' + opt)
    rate, chans, x = read_wav(path)
    print('%s: %d Hz, %d channel(s), %.3f s' % (path, rate, chans, len(x) / rate))
    if chans == 2 and np.max(np.abs(x[:, 0] - x[:, 1])) > 2:
        print('  note: left and right differ')
    tones = []
    segs = segments(x, rate)
    fmax = np.zeros(len(x))
    for f, s, e, r in segs:              # (near a change of tone, the higher)
        a, b = max(0, int((s - WIN) * rate)), min(len(x), int((e + WIN) * rate))
        fmax[a:b] = np.maximum(fmax[a:b], f)
    for i, (f, s, e, r) in enumerate(segs):
        if f:
            s2, e2 = refine_edges(x, rate, s, e)
            if i and segs[i - 1][0]:         # (next to another tone: the
                s2 = s                      # window edge is the best guess)
            if i + 1 < len(segs) and segs[i + 1][0]:
                e2 = e
            s, e = s2, e2
            ck = clicks(x, rate, s, e, fmax)
            tones.append((f, s, e, r, ck))
            if not quiet:
                print('  tone %7.1f Hz  %7.3f - %7.3f s  (%.3f s, peak level %d)%s' % (
                    f, s, e, e - s, np.max(np.abs(x[int(s * rate):int(e * rate), 0])),
                    '  clicks at ' + ', '.join('%.3f' % t for t in ck[:8]) if ck else ''))
        elif not quiet:
            print('  silence         %7.3f - %7.3f s  (%.3f s)' % (s, e, e - s))
    if expect is None:
        return 0
    fails = []
    if len(tones) != len(expect):
        fails.append('%d tone(s) heard, %d expected' % (len(tones), len(expect)))
    for i, ((ef, ed), t) in enumerate(zip(expect, tones)):
        f, s, e, r, ck = t
        if abs(f - ef) > 0.02 * ef:
            fails.append('tone %d is %.1f Hz, not %.1f' % (i + 1, f, ef))
        if abs((e - s) - ed) > tol:
            fails.append('tone %d lasts %.3f s, not %.3f' % (i + 1, e - s, ed))
        if ck:
            fails.append('tone %d has %d click(s)' % (i + 1, len(ck)))
        if max_gap is not None and i and s - tones[i - 1][2] > max_gap:
            fails.append('a gap of %.3f s before tone %d' % (s - tones[i - 1][2], i + 1))
    print('FAIL: ' + '; '.join(fails) if fails else 'OK')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
