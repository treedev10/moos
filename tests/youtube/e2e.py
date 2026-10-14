#!/usr/bin/env python3
"""End-to-end test of the MOOS browser's YouTube pages and video player,
against the stand-in server (tests/youtube/mock.py), in QEMU with UEFI and an
Intel HD Audio card whose output is recorded.

    python tests/youtube/e2e.py [--keep DIR] [--ac97] [test ...]

Tests (all by default):
    watch     open youtube.com/watch?v=clip001 (autoplay): the picture must
              show the test pattern, the sound must be the 440 Hz tone
    search    youtube.com/results?search_query=test: titles and thumbnails
    blocked   a video every client is refused: the reason is shown
    fallback  a video only the IOS client may play: it still plays
    embed     a page with a YouTube <iframe>: a picture linking to the video
    video     a page with <video><source ...>: click it, it plays

Screenshots and the recorded sound go to --keep DIR (default build/e2e).
Needs a built image (python build.py), ffmpeg, Pillow and numpy.
"""
import os
import socket
import subprocess
import sys
import time
import wave

import numpy
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PY = sys.executable


def free_port():
    s = socket.socket()
    s.bind(('', 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start_mock(port, log):
    p = subprocess.Popen([PY, os.path.join(HERE, 'mock.py'), '--port', str(port)],
                         stdout=log, stderr=log)
    for _ in range(600):                    # (the first start makes the videos)
        try:
            socket.create_connection(('127.0.0.1', port), 0.5).close()
            return p
        except OSError:
            time.sleep(0.5)
    p.kill()
    raise SystemExit('mock server did not start')


def seed(out, port):
    cfg = 'api http://10.0.2.2:%d\\nimages http://10.0.2.2:%d\\n' % (port, port)
    subprocess.run([PY, os.path.join(ROOT, 'tools', 'seedfs.py'), os.path.join(ROOT, 'build', 'moos.img'),
                    out, 'desktop.inst=@1', 'yt.cfg=@' + cfg], check=True, stdout=subprocess.DEVNULL)


def qemu(image, steps, wav=None, ac97=False):
    cmd = [PY, os.path.join(ROOT, 'tools', 'screentest.py'), '--uefi', '--mem', '1024', '--image', image]
    if wav:
        cmd += ['--ac97' if ac97 else '--audio', wav]
    r = subprocess.run(cmd + steps, capture_output=True, text=True, timeout=1800)
    return r.stdout + r.stderr


def tone(wavfile):
    """-> (seconds of sound above silence, its main frequency)"""
    w = wave.open(wavfile)
    n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
    a = numpy.frombuffer(w.readframes(n), dtype=numpy.int16).astype(float)
    if ch > 1:
        a = a.reshape(-1, ch)[:, 0]
    loud = numpy.abs(a) > 1000
    secs = loud.sum() / float(rate)
    if loud.sum() < rate // 10:
        return secs, 0.0
    idx = numpy.nonzero(loud)[0]
    seg = a[idx[0]:idx[0] + rate]
    spec = numpy.abs(numpy.fft.rfft(seg * numpy.hanning(len(seg))))
    freq = numpy.argmax(spec) * rate / float(len(seg))
    return secs, freq


def colourful(png, box):
    """-> how many distinct colours (coarse) are in that part of a screenshot"""
    im = Image.open(png).convert('RGB').crop(box)
    small = im.resize((64, 36))
    return len(set((r >> 5, g >> 5, b >> 5) for r, g, b in small.getdata()))


def main():
    keep = os.path.join(ROOT, 'build', 'e2e')
    args = sys.argv[1:]
    ac97 = False
    if '--keep' in args:
        i = args.index('--keep')
        keep = args[i + 1]
        del args[i:i + 2]
    if '--ac97' in args:
        args.remove('--ac97')
        ac97 = True
    tests = args or ['watch', 'search', 'blocked', 'fallback', 'embed', 'video']
    os.makedirs(keep, exist_ok=True)
    port = free_port()
    log = open(os.path.join(keep, 'mock.log'), 'w')
    mock = start_mock(port, log)
    image = os.path.join(keep, 'moos.img')
    seed(image, port)
    fails = 0
    try:
        for t in tests:
            png = os.path.join(keep, t + '.png')
            ok, why = False, ''
            if t == 'watch':
                wav = os.path.join(keep, 'watch.wav')
                out = qemu(image, ['@wait=4', 'net up\\n', '@wait=4',
                                   'gui browser youtube.com/watch?v=clip001\\n', '@wait=40',
                                   '@png=' + png], wav, ac97)
                secs, freq = tone(wav)
                colours = colourful(png, (160, 260, 800, 620))
                ok = secs >= 3 and abs(freq - 440) < 10 and colours >= 8
                why = 'sound %.1f s at %.0f Hz, %d colours in the player' % (secs, freq, colours)
            elif t == 'search':
                out = qemu(image, ['@wait=4', 'net up\\n', '@wait=4',
                                   'gui browser youtube.com/results?search_query=test\\n', '@wait=40',
                                   '@png=' + png])
                colours = colourful(png, (160, 300, 420, 700))
                ok = colours >= 8
                why = '%d colours where the thumbnails are' % colours
            elif t == 'blocked':
                out = qemu(image, ['@wait=4', 'net up\\n', '@wait=4',
                                   'gui browser youtube.com/watch?v=blocked4\\n', '@wait=25',
                                   '@png=' + png])
                ok = True
                why = 'see the screenshot: "Sign in to confirm your age"'
            elif t == 'fallback':
                wav = os.path.join(keep, 'fallback.wav')
                out = qemu(image, ['@wait=4', 'net up\\n', '@wait=4',
                                   'gui browser youtu.be/iosonly7\\n', '@wait=40', '@png=' + png], wav, ac97)
                secs, freq = tone(wav)
                ok = secs >= 2 and abs(freq - 440) < 10
                why = 'sound %.1f s at %.0f Hz' % (secs, freq)
            elif t == 'embed':
                out = qemu(image, ['@wait=4', 'net up\\n', '@wait=4',
                                   'gui browser 10.0.2.2:%d/test/embed\\n' % port, '@wait=25',
                                   '@png=' + png])
                colours = colourful(png, (160, 260, 480, 440))
                ok = colours >= 8
                why = '%d colours where the video picture is' % colours
            elif t == 'video':
                wav = os.path.join(keep, 'video.wav')
                out = qemu(image, ['@wait=4', 'net up\\n', '@wait=4',
                                   'gui browser 10.0.2.2:%d/test/video\\n' % port, '@wait=15',
                                   '@ptr=400,400,0', '@ptr=400,400,1', '@ptr=400,400,0', '@wait=30',
                                   '@png=' + png], wav, ac97)
                secs, freq = tone(wav)
                ok = secs >= 3 and abs(freq - 440) < 10
                why = 'sound %.1f s at %.0f Hz' % (secs, freq)
            print('%-9s %s  %s' % (t, 'ok  ' if ok else 'FAIL', why))
            if not ok:
                fails += 1
                with open(os.path.join(keep, t + '.out'), 'w') as f:
                    f.write(out)
    finally:
        mock.kill()
    print('mock server log: %s' % os.path.join(keep, 'mock.log'))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
