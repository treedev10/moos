#!/usr/bin/env python3
"""
Run MOOS's sound tests in QEMU and check what was played.

    python tools/soundtest.py [NAME ...] [--jobs N] [--keep]

Each test boots the full (UEFI) kernel with a sound card, types a "sound
test ..." command, records the card's output into build/sound/NAME.wav
(screentest.py --audio / --ac97) and checks the recording with
tools/wavcheck.py: which tones, how long, no clicks, no old sound played
again, no long gaps. It also checks the numbers MOOS prints (frames
played, seconds taken). Without names, every test runs; NAME may also be
a prefix ("hda", "ac97").

Build first (python build.py). Tests run side by side (--jobs, default 4).
"""
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'build', 'sound')

CARDS = {
    'hda':   ['--audio'],
    'ich9':  ['--audio', '--hda', 'ich9-intel-hda', '--extra', '-machine q35'],
    'duplex': ['--audio', '--codec', 'hda-duplex'],
    'ac97':  ['--ac97'],
}
TONES = '440:1,880:1'

# name: (card, command, wait seconds, wavcheck arguments, screen checks)
# screen checks: regular expressions that must be found on the screen
TESTS = {}
for card in ('hda', 'ac97', 'ich9'):
    TESTS[card + '-44100'] = (card, 'sound test', 4, ['--expect', TONES, '--max-gap', '0.02'],
                              [r'Done: 88[2-9]\d\d frames played \(88200 written\) in [12]\.\d\d s'])
for card in ('hda', 'ac97'):
    for rate in (48000, 22050, 8000, 96000, 32000):
        TESTS['%s-%d' % (card, rate)] = (
            card, 'sound test %d' % rate, 4, ['--expect', TONES, '--max-gap', '0.02'],
            [r'Done: \d+ frames played \(%d written\)' % (2 * rate)])
    TESTS[card + '-gap'] = (card, 'sound test gap', 12, ['--expect', '440:0.5,880:0.5'],
                            [r'Before the gap \d+ frames played, after it \d+'])
    TESTS[card + '-pause'] = (card, 'sound test pause', 6, ['--expect', TONES, '--tol', '0.06'],
                              [r'Paused at (\d+) frames; a second later \1\.'])
    TESTS[card + '-reopen'] = (card, 'sound test reopen', 6,
                               ['--expect', ','.join('%d:0.125' % (440 + 110 * i)
                                                     for i in range(8)),
                                '--tol', '0.04', '--clicks-ok'],
                               [r'Stream 7: 1210 Hz, closed after \d+ frames'])
TESTS['duplex-44100'] = ('duplex', 'sound test', 4, ['--expect', TONES, '--max-gap', '0.02'],
                         [r'Done: 88[2-9]\d\d frames played'])


def run(name):
    card, command, wait, check, screen_res = TESTS[name]
    wav = os.path.join(OUT, name + '.wav')
    if os.path.exists(wav):
        os.remove(wav)
    opts = list(CARDS[card])
    opts.insert(1, wav)
    cmd = [sys.executable, os.path.join(ROOT, 'tools', 'screentest.py'), '--uefi'] + opts + \
        ['sound\n', command + '\n', '@wait=%d' % wait, '@screen']
    screen = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT).stdout
    rows = [l[1:81].rstrip() for l in screen.splitlines() if l.startswith('|')]
    text = '\n'.join(rows)
    fails = [r for r in screen_res if not re.search(r, text)]
    res = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'wavcheck.py'), wav] +
                         check, capture_output=True, text=True, cwd=ROOT)
    ok = res.returncode == 0 and not fails
    report = ['== %s: %s' % (name, 'OK' if ok else 'FAIL')]
    report += ['   ' + l for l in rows if l.strip() and not l.startswith(('  __', '  |', ' |'))
               and 'MOOS 1.' not in l][-14:]
    report += ['   ' + l for l in res.stdout.splitlines()]
    report += ['   missing on screen: ' + r for r in fails]
    return ok, '\n'.join(report)


def main():
    args = sys.argv[1:]
    jobs = 4
    names = []
    while args:
        a = args.pop(0)
        if a == '--jobs':
            jobs = int(args.pop(0))
        else:
            names += [n for n in TESTS if n == a or n.startswith(a)]
    names = names or list(TESTS)
    os.makedirs(OUT, exist_ok=True)
    with ThreadPoolExecutor(jobs) as pool:
        results = list(pool.map(run, names))
    for ok, report in results:
        print(report)
    bad = [n for n, (ok, _) in zip(names, results) if not ok]
    print('\n%d of %d tests passed%s' % (len(names) - len(bad), len(names),
                                        (': failed ' + ', '.join(bad)) if bad else ''))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
