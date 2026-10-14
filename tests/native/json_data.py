#!/usr/bin/env python3
"""
json_data.py - make the test documents for json_test.c and their references.

    python3 tests/native/json_data.py       # writes build/json/
    python3 tests/native/run.py json        # checks src/json.asm against them

The reference is Python's json module (an independent parser): every
document is read with json.loads, keeping what MOOS keeps - the raw text
of numbers (parse_int / parse_float hooks), the order and duplicates of
object members (object_pairs_hook) - and NaN / Infinity refused (they are
not JSON). From that, the expected token list is written in json_parse's
order (a value, then its children; a key, then its value), with each
token's type, its "next" index, and its content: the decoded string
(UTF-8, a lone surrogate as U+FFFD, the way MOOS gives it) or the text of
a primitive, plus what json_int must say about it.

What is made (build/json/):
  cases.bin       many small documents, each with its reference:
                    - random documents (every kind of value, escapes,
                      \\uXXXX, surrogate pairs and lone surrogates, odd
                      numbers, duplicate keys, random whitespace)
                    - every prefix of some of them (a cut-off text must
                      give -3, "ends early", unless it is itself complete)
                    - random edits of them (Python decides valid or not)
                    - hand-written edge cases with the exact error code,
                      and nesting 1000 deep (accepted) / 1001 (refused)
  big.json        5+ MB, 300k+ tokens (records of mixed values)
  strings.json    long strings with escapes (the SSE string scan)
  player*.json    the shape of a YouTube innertube /player response
                  (playabilityStatus, videoDetails, streamingData.formats
                  with itag, url, mimeType, width, height, contentLength,
                  signatureCipher ...), pretty-printed and compact
  search*.json    the shape of a /search response (videoRenderer items)
  X.ref           the token reference of X.json
  X.exp           (player, search) lookups by path, the way the player
                  will do them: json_key / json_index down the path, then
                  json_int / json_str / json_eq on what is there
  list.txt        the big files to check

Reference file format (text):
  OK <tokens>                     or   ERR <code>  (code: any, -1, -3, -4)
  o <next> <members>              object
  a <next> <elements>             array
  s <next> <hex|-> <ires> <ival>  string: decoded bytes in hex, json_int
  p <next> <text> <ires> <ival>   primitive: its text, json_int
cases.bin: records of  u32 doc length, doc, u32 ref length, ref.
"""
import json
import os
import random
import re
import struct
import sys
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "json")
INT_RE = re.compile(r"-?[0-9]+(\.[0-9]+)?\Z")


# ------------------------------------------------------------ the reference
def py_parse(text):
    """Python's json.loads, keeping raw numbers and every object member."""
    def no_const(s):
        raise ValueError("not JSON: " + s)
    return json.loads(text, parse_int=lambda s: ("N", s), parse_float=lambda s: ("N", s),
                      parse_constant=no_const, object_pairs_hook=lambda pairs: ("O", pairs))


def py_valid(data):
    """data (bytes) -> the parsed value, or None if Python refuses it."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    try:
        return (py_parse(text),)
    except (ValueError, RecursionError):
        return None


def enc(s):
    """A decoded JSON string as MOOS gives it: UTF-8, lone surrogates as U+FFFD."""
    return "".join("�" if 0xD800 <= ord(c) <= 0xDFFF else c for c in s).encode("utf-8")


def int_expect(text):
    """What json_int must return for a token whose text is `text`."""
    if not INT_RE.match(text):
        return (-1, 0)
    v = int(Decimal(text))              # (drops the fraction, toward zero)
    if v > 2**31 - 1:
        return (-2, 2**31 - 1)
    if v < -2**31:
        return (-2, -2**31)
    return (0, v)


def tokens_of(v):
    """The expected token list: [kind, next, content] in json_parse's order."""
    toks = []
    stack = [("v", v)]
    # iterative pre-order walk (documents may be 1000 deep)
    while stack:
        what, x = stack.pop()
        if what == "end":               # x = token index whose subtree ends here
            toks[x][1] = len(toks)
            continue
        if what == "key":
            k, val = x
            i = len(toks)
            toks.append(["s", 0, enc(k)])
            stack.append(("end", i))
            stack.append(("v", val))
            continue
        i = len(toks)
        if isinstance(x, tuple) and x[0] == "O":
            toks.append(["o", 0, len(x[1])])
            stack.append(("end", i))
            for pair in reversed(x[1]):
                stack.append(("key", pair))
        elif isinstance(x, list):
            toks.append(["a", 0, len(x)])
            stack.append(("end", i))
            for e in reversed(x):
                stack.append(("v", e))
        elif isinstance(x, str):
            toks.append(["s", i + 1, enc(x)])
        elif isinstance(x, tuple) and x[0] == "N":
            toks.append(["p", i + 1, x[1].encode()])
        elif x is True:
            toks.append(["p", i + 1, b"true"])
        elif x is False:
            toks.append(["p", i + 1, b"false"])
        elif x is None:
            toks.append(["p", i + 1, b"null"])
        else:
            raise TypeError(x)
    return toks


def ref_ok(v):
    toks = tokens_of(v)
    out = ["OK %d" % len(toks)]
    for kind, nxt, c in toks:
        if kind in "oa":
            out.append("%s %d %d" % (kind, nxt, c))
        else:
            text = c.decode("utf-8", "replace")
            ires, ival = int_expect(text) if c.isascii() else (-1, 0)
            show = c.hex() if kind == "s" else c.decode()
            out.append("%s %d %s %d %d" % (kind, nxt, show or "-", ires, ival))
    return "\n".join(out) + "\n"


def ref_for(data, code=None):
    """The reference of a document: Python decides; `code` = the error MOOS
    must give if it is invalid (None: any error)."""
    r = py_valid(data)
    if r is not None:
        return ref_ok(r[0])
    return "ERR %s\n" % (code if code is not None else "any")


# ------------------------------------------------------- random documents
PRINT = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.,:;!?()[]{}#@$%^&*+=<>|~`'"
SPECIAL = ['"', "\\", "/", "\x7f", "é", "ß", "ÿ", " ", "中", "日",
           "Ж", "€", " ", " ", "﻿", "￿", "�", "ࠀ",
           "߿", "\u0080", "\U0001F600", "\U00010000", "\U0010FFFF", "\U0001F3B5"]
LONE = ["\\ud800", "\\udbff", "\\udc00", "\\udfff", "\\uD83D", "\\uDE00\\uD83D",
        "\\ud83d\\ud83d\\ude00", "\\ud83dx", "\\ud83d\\u0041", "\\ud83d\\n"]
WS = ["", "", "", "", " ", "\n", "\t", "\r\n", "  ", "\n    ", " \t "]


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)

    def ws(self):
        return self.r.choice(WS) if self.r.random() < 0.5 else ""

    def char_text(self, c):
        """One character in JSON source form (randomly escaped or not)."""
        r = self.r
        o = ord(c)
        short = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r",
                 "\t": "\\t", "/": "\\/"}
        if o < 0x20 or c in '"\\':
            if c in short and r.random() < 0.7:
                return short[c]
            return ("\\u%04x" if r.random() < 0.5 else "\\u%04X") % o
        if c == "/" and r.random() < 0.3:
            return "\\/"
        if r.random() < 0.12:
            if o >= 0x10000:            # a surrogate pair
                v = o - 0x10000
                hi, lo = 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)
                f = "\\u%04x" if r.random() < 0.5 else "\\u%04X"
                return f % hi + f % lo
            return ("\\u%04x" if r.random() < 0.5 else "\\u%04X") % o
        return c

    def string(self, maxlen=24):
        r = self.r
        n = r.choice([0, 1, 2, 3, 5, 8, 12, maxlen, r.randint(0, maxlen)])
        parts = []
        for _ in range(n):
            x = r.random()
            if x < 0.65:
                parts.append(self.char_text(r.choice(PRINT)))
            elif x < 0.85:
                parts.append(self.char_text(r.choice(SPECIAL)))
            elif x < 0.97:
                parts.append(self.char_text(chr(r.randint(0, 0x1F))))
            else:
                parts.append(r.choice(LONE))
        return '"' + "".join(parts) + '"'

    def number(self):
        r = self.r
        edge = ["0", "-0", "2147483647", "-2147483648", "2147483648", "-2147483649", "4294967295",
                "4294967296", "99999999999999999999999", "0.0", "-0.0", "1e5", "1E-5", "0e0",
                "123.456e+789", "0.000001", "-6.83", "12.5", "-1.99", "214748364.9", "3.14159",
                "1E+2", "-0.5", "214748365", "-214748365"]
        if r.random() < 0.25:
            return r.choice(edge)
        s = "-" if r.random() < 0.3 else ""
        if r.random() < 0.2:
            s += "0"
        else:
            s += str(r.randint(1, 9)) + "".join(r.choice("0123456789")
                                                 for _ in range(r.choice([0, 0, 1, 2, 4, 8, 9, 10, 12, 20])))
        if r.random() < 0.3:
            s += "." + "".join(r.choice("0123456789") for _ in range(r.randint(1, 12)))
        if r.random() < 0.15:
            s += r.choice("eE") + r.choice(["", "+", "-"]) + str(r.randint(0, 400))
        return s

    def value(self, depth, budget):
        r = self.r
        x = r.random()
        if depth <= 0 or budget[0] <= 0:
            x = 0.5 + x * 0.5             # only scalars
        budget[0] -= 1
        if x < 0.22:
            return self.obj(depth - 1, budget)
        if x < 0.4:
            return self.arr(depth - 1, budget)
        if x < 0.7:
            return self.string()
        if x < 0.9:
            return self.number()
        return r.choice(["true", "false", "null"])

    def obj(self, depth, budget):
        r = self.r
        n = r.choice([0, 1, 2, 3, 4, 6, 10])
        keys = []
        items = []
        for _ in range(n):
            if keys and r.random() < 0.1:
                k = r.choice(keys)        # a duplicate key: the last one counts
            else:
                k = self.string(10)
                keys.append(k)
            items.append(self.ws() + k + self.ws() + ":" + self.ws() + self.value(depth, budget) + self.ws())
        if not items:
            return "{" + self.ws() + "}"
        return "{" + ",".join(items) + "}"

    def arr(self, depth, budget):
        r = self.r
        n = r.choice([0, 1, 2, 3, 5, 8, 16])
        items = [self.ws() + self.value(depth, budget) + self.ws() for _ in range(n)]
        if not items:
            return "[" + self.ws() + "]"
        return "[" + ",".join(items) + "]"

    def doc(self):
        r = self.r
        depth = r.choice([0, 1, 2, 3, 4, 6, 8, 12, 30])
        budget = [r.choice([1, 5, 20, 60, 200, 1000])]
        if r.random() < 0.8 and depth > 0:
            v = self.obj(depth, budget) if r.random() < 0.6 else self.arr(depth, budget)
        else:
            v = self.value(depth, budget)
        return self.ws() + v + self.ws()


# --------------------------------------------------------------- mutation
MUT_CHARS = list('{}[],:"\\0123456789-+.eEtrufalsn \n\t') + ["\x01", "\x00", "é", "中",
                                                              "\U0001F600", "/", "u", "x"]


def mutate(text, r):
    t = list(text)
    for _ in range(r.choice([1, 1, 1, 2, 3])):
        if not t:
            t.append(r.choice(MUT_CHARS))
            continue
        i = r.randrange(len(t) + 1)
        k = r.random()
        if k < 0.3 and i < len(t):
            del t[i]
        elif k < 0.6:
            t.insert(i, r.choice(MUT_CHARS))
        elif k < 0.85 and i < len(t):
            t[i] = r.choice(MUT_CHARS)
        else:                            # repeat or cut out a span
            j = min(len(t), i + r.randint(1, 8))
            if r.random() < 0.5:
                t[i:i] = t[i:j]
            else:
                del t[i:j]
    return "".join(t)


# ------------------------------------------------------------ edge cases
def edge_cases():
    """(document bytes, expected code or None for valid)."""
    E = []

    def add(s, code=None):
        E.append((s.encode("utf-8") if isinstance(s, str) else s, code))
    for s in ["0", "-0", "1", "-1", "123", "1.5", "-0.0e-0", "1E400", '""', '"x"', "true", "false",
              "null", "[]", "{}", " [ ] ", "\t{\r\n}\n", "[[]]", "[{}]", '{"":""}', '{"a":1,"a":2}',
              '[1,2,3]', '{"a":[1,{"b":null}],"c":"d"}', '"\\u0000"', '"\\ud83d\\ude00"',
              '"\\uD83D\\uDE00"', '"\\ud800"', '"\\udc00\\ud800"', '"\\/\\b\\f\\n\\r\\t\\"\\\\"',
              '"é中\U0001F600"', '"\x7f"', "[" + ",".join(["1"] * 1000) + "]",
              '"' + "a" * 100000 + '"', '"' + "\\n" * 5000 + '"', "[" + "0," * 9999 + "0]",
              "-2147483648", "2147483648", "123456789012345678901234567890", "1.0e+00"]:
        add(s)
    for s in ["[1,]", "{,}", '{"a" 1}', "[1 2]", "01", "1.e3", ".5", "+1", "NaN", "Infinity",
              "-Infinity", "tru e", '"\\x"', '"\\u12g4"', '"a\tb"', '"a\nb"', '"\x01"', "[1]]",
              "{}}", "1 2", '{"a":1,"a"}', "'a'", "[\x00]", "﻿{}", "[-]", "[1e]", '["a":1]',
              "{1:2}", '{"a":1 "b":2}', "[01]", "[.1]", "[1.]x", "-01", "--1", "1e+-1", "truex",
              "nulll", "[true false]", "{]", "[}", '{"a":}', '{"a"}', '{"a",1}', "[,1]",
              "[1,,2]", "]", "}", ":", ",", "[\x0b1]", "\x0c[]", "[1]\x00", '"\\U0041"', '"\\u"x',
              "0x10", "1_000", "[1;2]", "/*c*/1", "1//c"]:
        add(s, "-1")
    # every control byte inside a string is refused, wherever it is: in the
    # 16-byte SSE scan (early in a long string) and in the byte-by-byte tail;
    # space, DEL and the bytes around 0x1F / 0x20 are fine
    for c in range(0x20):
        ch = chr(c)
        for s in ['"' + ch + "a" * 40 + '"', '"' + "a" * 7 + ch + "a" * 30 + '"',
                  '"' + "a" * 15 + ch + "a" * 30 + '"', '"ab' + ch + '"', '"' + ch + '"',
                  '["' + "a" * 20 + ch + 'b"]', '{"k' + ch + '":1}']:
            add(s, "-1")
    for s in ['"' + " " * 40 + '"', '"' + "\x7f" * 40 + '"', '"' + "!\x7f ~" * 10 + '"', '" \x7f"']:
        add(s)
    for s in ["", " ", "\n\t\r ", "[", "{", '{"a"', '{"a":', '{"a":1', '{"a":1,', '{"a":1,"b"',
              "[1", "[1,", '"', '"abc', '"\\', '"\\u', '"\\u00', '"\\u004', "-", "1e", "1e+", "1.",
              "-0.", "t", "tr", "tru", "n", "nu", "nul", "f", "fa", "fal", "fals", "[" * 1000,
              '[{"a":[{"b":' + "[" * 50]:
        add(s, "-3")
    # nesting: 1000 deep is accepted, 1001 refused
    add("[" * 1000 + "]" * 1000)
    add("[" * 1001 + "]" * 1001, "-4")
    add("[" * 5000 + "]" * 5000, "-4")
    add("[" * 1001, "-4")
    add('{"a":' * 999 + "[1]" + "}" * 999)
    add('{"a":' * 1000 + "[1]" + "}" * 1000, "-4")
    add('{"k":[' * 500 + '"x"' + "]}" * 500)
    add('{"k":[' * 500 + '[0]' + "]}" * 500, "-4")
    add(" [" * 1000 + "0" + "] " * 1000)
    return E


def deep_ref(data):
    """The reference of a nesting test (Python's json may not go that deep)."""
    lim = sys.getrecursionlimit()
    sys.setrecursionlimit(100000)
    try:
        return ref_for(data)
    finally:
        sys.setrecursionlimit(lim)


# ------------------------------------------------------ YouTube's shapes
def yt_id(r, n=11):
    return "".join(r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") for _ in range(n))


def b64(r, n):
    return "".join(r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/") for _ in range(n))


def gv_url(r, itag, vid, clen, dur, mime):
    q = [("expire", "1760000000"), ("ei", b64(r, 20)), ("ip", "203.0.113.%d" % r.randint(1, 254)),
         ("id", "o-" + b64(r, 43)), ("itag", str(itag)), ("source", "youtube"), ("requiressl", "yes"),
         ("xpc", b64(r, 16)), ("mh", "Ab"), ("mm", "31,29"), ("mn", "sn-4g5ednsl,sn-4g5lznlz"),
         ("ms", "au,rdu"), ("mv", "m"), ("mvi", "3"), ("pl", "24"), ("initcwndbps", "1513750"),
         ("vprv", "1"), ("svpuc", "1"), ("mime", mime.split(";")[0].replace("/", "%2F")),
         ("rqh", "1"), ("gir", "yes"), ("clen", str(clen)), ("ratebypass", "yes"), ("dur", "%.3f" % dur),
         ("lmt", "1700000000000000"), ("mt", "1759970000"), ("fvip", "5"), ("fexp", "51331020"),
         ("c", "WEB"), ("txp", "5538434"), ("n", b64(r, 16)), ("sparams", "expire,ei,ip,id,itag,source"),
         ("sig", b64(r, 70)), ("lsparams", "met,mh,mm,mn,ms,mv,mvi,pl,initcwndbps"), ("lsig", b64(r, 60))]
    return "https://rr%d---sn-4g5ednsl.googlevideo.com/videoplayback?" % r.randint(1, 5) + "&".join(
        k + "=" + v for k, v in q)


def player_response(seed):
    r = random.Random(seed)
    vid = yt_id(r)
    dur = 212.091
    title = "Never Gonna Give You Up — Officiel Vidéo (4K Remaster) \U0001F3B5 日本語"
    formats = []
    fmt18_len = 13171538
    formats.append({"itag": 18, "url": gv_url(r, 18, vid, fmt18_len, dur, "video/mp4"),
                    "mimeType": 'video/mp4; codecs="avc1.42001E, mp4a.40.2"', "bitrate": 503514,
                    "width": 640, "height": 360, "lastModified": "1700000000000000",
                    "contentLength": str(fmt18_len), "quality": "medium", "fps": 25,
                    "qualityLabel": "360p", "projectionType": "RECTANGULAR", "averageBitrate": 496828,
                    "audioQuality": "AUDIO_QUALITY_LOW", "approxDurationMs": "212091",
                    "audioSampleRate": "44100", "audioChannels": 2})
    adaptive = []
    vids = [(137, "video/mp4", 'avc1.640028', 1920, 1080, 81234567), (136, "video/mp4", "avc1.4d401f", 1280, 720, 41234567),
            (135, "video/mp4", "avc1.4d401e", 854, 480, 21234567), (134, "video/mp4", "avc1.4d401e", 640, 360, 11234567),
            (133, "video/mp4", "avc1.4d4015", 426, 240, 5234567), (160, "video/mp4", "avc1.4d400c", 256, 144, 2234567),
            (313, "video/webm", "vp9", 3840, 2160, 3456789012), (248, "video/webm", "vp9", 1920, 1080, 98765432),
            (399, "video/mp4", "av01.0.08M.08", 1920, 1080, 61234567)]
    for i, (itag, mt, codec, w, h, clen) in enumerate(vids):
        f = {"itag": itag, "mimeType": '%s; codecs="%s"' % (mt, codec), "bitrate": r.randint(100000, 9000000),
             "width": w, "height": h, "initRange": {"start": "0", "end": str(r.randint(600, 800))},
             "indexRange": {"start": str(r.randint(700, 900)), "end": str(r.randint(1200, 2000))},
             "lastModified": "1700000000000000", "contentLength": str(clen), "quality": "hd1080",
             "fps": 25, "qualityLabel": "%dp" % h, "projectionType": "RECTANGULAR",
             "averageBitrate": r.randint(100000, 9000000), "approxDurationMs": "212040"}
        if i % 3 == 2:                   # a cipher instead of a url
            f["signatureCipher"] = "s=" + b64(r, 100).replace("+", "%2B").replace("/", "%2F") + \
                "&sp=sig&url=" + gv_url(r, itag, vid, clen, dur, mt).replace("&", "%26").replace("=", "%3D")
        else:
            f["url"] = gv_url(r, itag, vid, clen, dur, mt)
        if mt == "video/webm":
            f["colorInfo"] = {"primaries": "COLOR_PRIMARIES_BT709", "transferCharacteristics":
                              "COLOR_TRANSFER_CHARACTERISTICS_BT709", "matrixCoefficients":
                              "COLOR_MATRIX_COEFFICIENTS_BT709"}
        adaptive.append(f)
    for itag, mt, codec, rate, ch in [(140, "audio/mp4", "mp4a.40.2", "44100", 2), (251, "audio/webm", "opus", "48000", 2),
                                      (250, "audio/webm", "opus", "48000", 2), (249, "audio/webm", "opus", "48000", 2)]:
        adaptive.append({"itag": itag, "url": gv_url(r, itag, vid, 3433514, dur, mt),
                         "mimeType": '%s; codecs="%s"' % (mt, codec), "bitrate": 130000,
                         "initRange": {"start": "0", "end": "631"}, "indexRange": {"start": "632", "end": "923"},
                         "lastModified": "1700000000000000", "contentLength": "3433514", "quality": "tiny",
                         "projectionType": "RECTANGULAR", "averageBitrate": 129482, "highReplication": True,
                         "audioQuality": "AUDIO_QUALITY_MEDIUM", "approxDurationMs": "212091",
                         "audioSampleRate": rate, "audioChannels": ch, "loudnessDb": -7.4600000381469727})
    thumbs = [{"url": "https://i.ytimg.com/vi/%s/%s.jpg?sqp=-oaymwEcCNACELwBSFXyq4qpAw4IARUAAIhCGAFwAcABBg==&rs=AOn4CLD%s" % (vid, n, b64(r, 20)),
               "width": w, "height": h} for n, w, h in [("default", 120, 90), ("mqdefault", 320, 180),
                                                         ("hqdefault", 480, 360), ("sddefault", 640, 480),
                                                         ("maxresdefault", 1920, 1080)]]
    desc = ("The official video for “Never Gonna Give You Up”.\n\nListen: https://example.lnk.to/x?a=1&b=2\n"
            "#music #80s \U0001F3B6\n\n" + "Lyrics:\nWe're no strangers to love\nYou know the rules and so do I\n" * 8 +
            "Tabs:\there\tand \"quotes\" and back\\slashes and <tags>\r\n")
    resp = {
        "responseContext": {
            "visitorData": b64(r, 40),
            "serviceTrackingParams": [
                {"service": "GFEEDBACK", "params": [{"key": "is_viewed_live", "value": "False"},
                                                    {"key": "logged_in", "value": "0"},
                                                    {"key": "e", "value": ",".join(str(r.randint(23800000, 51400000)) for _ in range(60))}]},
                {"service": "CSI", "params": [{"key": "c", "value": "WEB"}, {"key": "cver", "value": "2.20251010.00.00"},
                                              {"key": "yt_li", "value": "0"}, {"key": "GetPlayer_rid", "value": "0x" + b64(r, 16)}]},
                {"service": "ECATCHER", "params": [{"key": "client.version", "value": "2.20251010"},
                                                   {"key": "client.name", "value": "WEB"}]}],
            "maxAgeSeconds": 0,
            "mainAppWebResponseContext": {"loggedOut": True, "trackingParam": b64(r, 120)},
            "webResponseContextExtensionData": {"hasDecorated": True}},
        "playabilityStatus": {"status": "OK", "playableInEmbed": True,
                              "miniplayer": {"miniplayerRenderer": {"playbackMode": "PLAYBACK_MODE_ALLOW"}},
                              "contextParams": "Q0FFU0FnZ0I="},
        "streamingData": {"expiresInSeconds": "21540", "formats": formats, "adaptiveFormats": adaptive,
                          "serverAbrStreamingUrl": "https://rr3---sn-4g5ednsl.googlevideo.com/videoplayback?expire=1760000000&ei=" + b64(r, 20)},
        "playbackTracking": {k: {"baseUrl": "https://s.youtube.com/api/stats/%s?cl=%d&docid=%s&ei=%s&fexp=&ns=yt&plid=%s&el=detailpage&len=213&of=%s&vm=%s" %
                                 (k, r.randint(1, 10**9), vid, b64(r, 20), b64(r, 16), b64(r, 22), b64(r, 60)),
                                 "elapsedMediaTimeSeconds": 0}
                             for k in ["videostatsPlaybackUrl", "videostatsDelayplayUrl", "videostatsWatchtimeUrl",
                                       "ptrackingUrl", "qoeUrl", "atrUrl"]},
        "captions": {"playerCaptionsTracklistRenderer": {
            "captionTracks": [{"baseUrl": "https://www.youtube.com/api/timedtext?v=%s&ei=%s&caps=asr&opi=112496729&xoaf=5&hl=en&ip=0.0.0.0&ipbits=0&expire=1760000000&sparams=ip,ipbits,expire,v,ei,caps,opi,xoaf&signature=%s&key=yt8&lang=%s" % (vid, b64(r, 20), b64(r, 40), lang),
                               "name": {"simpleText": name}, "vssId": "." + lang, "languageCode": lang,
                               "isTranslatable": True, "trackName": ""}
                              for lang, name in [("en", "English"), ("de-DE", "Deutsch (Deutschland)"),
                                                 ("ja", "日本語"), ("pt-BR", "Português (Brasil)")]],
            "audioTracks": [{"captionTrackIndices": [0, 1, 2, 3], "audioTrackId": None}],
            "translationLanguages": [{"languageCode": c, "languageName": {"simpleText": n}}
                                     for c, n in [("af", "Afrikaans"), ("ak", "Akan"), ("sq", "Albanian"),
                                                  ("am", "አማርኛ"), ("ar", "العربية")] * 20],
            "defaultAudioTrackIndex": 0}},
        "videoDetails": {"videoId": vid, "title": title, "lengthSeconds": "212",
                         "keywords": ["rick astley", "Never Gonna Give You Up", "nggyu", "never gonna give you up lyrics",
                                      "rick rolled", "Rick Roll", "été 80", "\U0001F3B5"],
                         "channelId": "UC" + yt_id(r, 22), "isOwnerViewing": False, "shortDescription": desc,
                         "isCrawlable": True, "thumbnail": {"thumbnails": thumbs}, "allowRatings": True,
                         "viewCount": "1696215341", "author": "Rick Astley", "isPrivate": False,
                         "isUnpluggedCorpus": False, "isLiveContent": False},
        "annotations": [{"playerAnnotationsExpandedRenderer": {"featuredChannel": {
            "startTimeMs": "0", "endTimeMs": "212091", "watermark": {"thumbnails": thumbs[:1]},
            "trackingParams": b64(r, 40), "navigationEndpoint": {"clickTrackingParams": b64(r, 40),
                                                                  "commandMetadata": {"webCommandMetadata": {"url": "/channel/UC" + yt_id(r, 22), "webPageType": "WEB_PAGE_TYPE_CHANNEL", "rootVe": 3611, "apiUrl": "/youtubei/v1/browse"}},
                                                                  "browseEndpoint": {"browseId": "UC" + yt_id(r, 22)}},
            "channelName": "Rick Astley", "subscribeButton": {"subscribeButtonRenderer": {"buttonText": {"runs": [{"text": "Subscribe"}]}, "subscribed": False, "enabled": True, "type": "FREE", "channelId": "UC" + yt_id(r, 22)}}}}}],
        "storyboards": {"playerStoryboardSpecRenderer": {"spec": "https://i.ytimg.com/sb/%s/storyboard3_L$L/$N.jpg?sqp=%s|48#27#100#10#10#0#default#rs$%s|80#45#108#10#10#2000#M$M#rs$%s" % (vid, b64(r, 40), b64(r, 30), b64(r, 30)),
                                                         "recommendedLevel": 2, "highResolutionRecommendedLevel": 3}},
        "microformat": {"playerMicroformatRenderer": {
            "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/vi/%s/maxresdefault.jpg" % vid, "width": 1280, "height": 720}]},
            "embed": {"iframeUrl": "https://www.youtube.com/embed/" + vid, "width": 1280, "height": 720},
            "title": {"simpleText": title}, "description": {"simpleText": desc}, "lengthSeconds": "212",
            "ownerProfileUrl": "http://www.youtube.com/@RickAstleyYT", "externalChannelId": "UC" + yt_id(r, 22),
            "isFamilySafe": True, "availableCountries": ["AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR"] * 25,
            "isUnlisted": False, "hasYpcMetadata": False, "viewCount": "1696215341", "category": "Music",
            "publishDate": "2009-10-24T23:57:33-07:00", "ownerChannelName": "Rick Astley",
            "uploadDate": "2009-10-24T23:57:33-07:00", "isShortsEligible": False}},
        "trackingParams": b64(r, 60),
        "attestation": {"playerAttestationRenderer": {"challenge": "a=6&a2=10&b=" + b64(r, 30) + "&c=1760000000&d=1&t=7200&c1a=1&c6a=1&c6b=1&hh=" + b64(r, 40),
                                                      "botguardData": {"program": b64(r, 3000), "interpreterSafeUrl": {"privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": "//www.google.com/js/th/" + b64(r, 40) + ".js"}, "serverEnvironment": 1}}},
        "adPlacements": [{"adPlacementRenderer": {"config": {"adPlacementConfig": {"kind": "AD_PLACEMENT_KIND_START", "adTimeOffset": {"offsetStartMilliseconds": "0", "offsetEndMilliseconds": "-1"}, "hideCueRangeMarker": True}}, "renderer": {"clientForecastingAdRenderer": {}}, "adSlotLoggingData": {"serializedSlotAdServingDataEntry": b64(r, 200)}}}],
        "frameworkUpdates": {"entityBatchUpdate": {"mutations": [{"entityKey": b64(r, 40), "type": "ENTITY_MUTATION_TYPE_REPLACE", "payload": {"offlineabilityEntity": {"key": b64(r, 40), "addToOfflineButtonState": "ADD_TO_OFFLINE_BUTTON_STATE_UNKNOWN"}}}], "timestamp": {"seconds": "1759970000", "nanos": 123456789}}},
    }
    return resp


def search_response(seed, n=20):
    r = random.Random(seed)
    items = []
    titles = ["Rick Astley - Never Gonna Give You Up (Official Music Video)", "Café à Paris — vlog \U0001F950",
              "東京の夜 — Tokyo at night 4K", "How to write an OS in assembly (part 1/10) \"from scratch\"",
              "Big Buck Bunny 60fps 4K - Official Blender Foundation", "Москва 2025"]
    for i in range(n):
        vid = yt_id(r)
        title = titles[i % len(titles)] + (" #%d" % i)
        secs = r.randint(5, 4000)
        length = "%d:%02d" % (secs // 60, secs % 60) if secs < 3600 else "%d:%02d:%02d" % (secs // 3600, secs // 60 % 60, secs % 60)
        views = r.randint(0, 2000000000)
        vr = {"videoId": vid,
              "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/vi/%s/hq720.jpg?sqp=-oaymwEcCOgCEMoBSFXyq4qpAw4IARUAAIhCGAFwAcABBg==&rs=AOn4CLC%s" % (vid, b64(r, 22)), "width": 360, "height": 202},
                                           {"url": "https://i.ytimg.com/vi/%s/hq720.jpg?sqp=-oaymwEcCNAFEJQDSFXyq4qpAw4IARUAAIhCGAFwAcABBg==&rs=AOn4CLD%s" % (vid, b64(r, 22)), "width": 720, "height": 404}]},
              "title": {"runs": [{"text": title}], "accessibility": {"accessibilityData": {"label": title + " by Someone %d views %d minutes" % (views, secs // 60)}}},
              "longBylineText": {"runs": [{"text": "Channel %d" % i, "navigationEndpoint": {"clickTrackingParams": b64(r, 40), "commandMetadata": {"webCommandMetadata": {"url": "/@channel%d" % i, "webPageType": "WEB_PAGE_TYPE_CHANNEL", "rootVe": 3611, "apiUrl": "/youtubei/v1/browse"}}, "browseEndpoint": {"browseId": "UC" + yt_id(r, 22), "canonicalBaseUrl": "/@channel%d" % i}}}]},
              "publishedTimeText": {"simpleText": "%d years ago" % r.randint(1, 15)},
              "lengthText": {"accessibility": {"accessibilityData": {"label": "%d minutes, %d seconds" % (secs // 60, secs % 60)}}, "simpleText": length},
              "viewCountText": {"simpleText": "{:,} views".format(views)},
              "navigationEndpoint": {"clickTrackingParams": b64(r, 40), "commandMetadata": {"webCommandMetadata": {"url": "/watch?v=" + vid, "webPageType": "WEB_PAGE_TYPE_WATCH", "rootVe": 3832}},
                                     "watchEndpoint": {"videoId": vid, "params": "qgcJCLxW_" + b64(r, 10), "playerParams": "8AEB", "watchEndpointSupportedOnesieConfig": {"html5PlaybackOnesieConfig": {"commonConfig": {"url": "https://rr4---sn-4g5ednsl.googlevideo.com/initplayback?source=youtube&oeis=1&c=WEB&oad=3200&ovd=3200&oaad=11000&oavd=11000&ocs=700&oewis=1&oputc=1&ofpcc=1&msp=1&odepv=1&id=" + b64(r, 16) + "&ip=0.0.0.0&initcwndbps=1000000&mt=1759970000&oweuc="}}}}},
              "ownerText": {"runs": [{"text": "Channel %d" % i}]}, "shortBylineText": {"runs": [{"text": "Channel %d" % i}]},
              "trackingParams": b64(r, 40), "showActionMenu": False,
              "shortViewCountText": {"accessibility": {"accessibilityData": {"label": "%dM views" % (views // 1000000)}}, "simpleText": "%dM views" % (views // 1000000)},
              "menu": {"menuRenderer": {"items": [{"menuServiceItemRenderer": {"text": {"runs": [{"text": t}]}, "icon": {"iconType": ic}, "trackingParams": b64(r, 40)}} for t, ic in [("Add to queue", "ADD_TO_QUEUE_TAIL"), ("Save to Watch Later", "WATCH_LATER"), ("Share", "SHARE")]],
                                        "trackingParams": b64(r, 40), "accessibility": {"accessibilityData": {"label": "Action menu"}}}},
              "channelThumbnailSupportedRenderers": {"channelThumbnailWithLinkRenderer": {"thumbnail": {"thumbnails": [{"url": "https://yt3.ggpht.com/" + b64(r, 60) + "=s68-c-k-c0x00ffffff-no-rj", "width": 68, "height": 68}]}}},
              "thumbnailOverlays": [{"thumbnailOverlayTimeStatusRenderer": {"text": {"accessibility": {"accessibilityData": {"label": length}}, "simpleText": length}, "style": "DEFAULT"}},
                                    {"thumbnailOverlayToggleButtonRenderer": {"isToggled": False, "untoggledIcon": {"iconType": "WATCH_LATER"}, "toggledIcon": {"iconType": "CHECK"}}}],
              "detailedMetadataSnippets": [{"snippetText": {"runs": [{"text": "A description with "}, {"text": "bold", "bold": True}, {"text": " parts & <html> \"quoted\"…"}]}}]}
        if i % 7 == 3:
            vr["badges"] = [{"metadataBadgeRenderer": {"style": "BADGE_STYLE_TYPE_SIMPLE", "label": "4K", "trackingParams": b64(r, 40)}}]
        if i % 5 == 4:                    # a live stream has no lengthText
            del vr["lengthText"]
            vr["viewCountText"] = {"runs": [{"text": "1,234"}, {"text": " watching"}]}
        items.append({"videoRenderer": vr})
        if i == 5:
            items.append({"shelfRenderer": {"title": {"simpleText": "People also watched"}, "content": {"verticalListRenderer": {"items": [{"videoRenderer": {"videoId": yt_id(r), "title": {"runs": [{"text": "Shelf video"}]}}}], "collapsedItemCount": 2}}}})
        if i == 9:
            items.append({"adSlotRenderer": {"adSlotMetadata": {"slotId": "0:%d:0" % r.randint(1, 10**12), "slotType": "SLOT_TYPE_IN_FEED", "slotPhysicalPosition": 1}, "fulfillmentContent": {"fulfilledLayout": {"inFeedAdLayoutRenderer": {"adLayoutMetadata": {"layoutId": b64(r, 30), "layoutType": "LAYOUT_TYPE_DISPLAY_TOP_LANDSCAPE_IMAGE"}}}}}})
        if i == 12:
            items.append({"channelRenderer": {"channelId": "UC" + yt_id(r, 22), "title": {"simpleText": "A channel"}, "videoCountText": {"runs": [{"text": "1,024"}, {"text": " videos"}]}}})
    resp = {"responseContext": {"visitorData": b64(r, 40), "serviceTrackingParams": [{"service": "GFEEDBACK", "params": [{"key": "has_unlimited_entitlement", "value": "False"}]}], "mainAppWebResponseContext": {"loggedOut": True}},
            "estimatedResults": "%d" % r.randint(10**5, 10**8),
            "contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {
                "contents": [{"itemSectionRenderer": {"contents": items, "trackingParams": b64(r, 40)}},
                             {"continuationItemRenderer": {"trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN", "continuationEndpoint": {"clickTrackingParams": b64(r, 40), "commandMetadata": {"webCommandMetadata": {"sendPost": True, "apiUrl": "/youtubei/v1/search"}}, "continuationCommand": {"token": b64(r, 300), "request": "CONTINUATION_REQUEST_TYPE_SEARCH"}}}}],
                "trackingParams": b64(r, 40), "subMenu": {"searchSubMenuRenderer": {"trackingParams": b64(r, 40)}}, "hideBottomSeparator": True, "targetId": "search-feed"}}}},
            "trackingParams": b64(r, 40),
            "topbar": {"desktopTopbarRenderer": {"logo": {"topbarLogoRenderer": {"iconImage": {"iconType": "YOUTUBE_LOGO"}, "tooltipText": {"runs": [{"text": "YouTube Home"}]}}}, "searchbox": {"fusionSearchboxRenderer": {"placeholderText": {"runs": [{"text": "Search"}]}, "config": {"webSearchboxConfig": {"requestLanguage": "en", "requestDomain": "us", "hasOnscreenKeyboard": False, "focusSearchbox": True}}}}}},
            "refinements": ["rick astley never gonna give you up", "rick roll", "never gonna give you up lyrics"],
            "onResponseReceivedCommands": [{"clickTrackingParams": b64(r, 40), "adsControlFlowOpportunityReceivedCommand": {"opportunityType": "OPPORTUNITY_TYPE_ORGANIC_BROWSE_RESPONSE_RECEIVED", "isInitialLoad": True, "enablePacfLoggingWeb": False}}],
            "targetId": "search-page"}
    return resp


def yt_dump(obj, pretty):
    """JSON text the way YouTube's servers write it: UTF-8, & < > = as
    \\u escapes, 2-space indentation (or compact)."""
    if pretty:
        s = json.dumps(obj, ensure_ascii=False, indent=2, separators=(",", ": "))
    else:
        s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return s.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e").replace("=", "\\u003d")


def path_checks(obj):
    """Lookups to do on a document: one line per value, by path."""
    out = []

    def walk(x, path):
        p = "/".join(path) if path else "."
        if isinstance(x, dict):
            out.append("%s len %d" % (p, len(x)))
            for k, v in x.items():
                walk(v, path + [k])
            out.append("%s/noSuchKey none" % p)
        elif isinstance(x, list):
            out.append("%s len %d" % (p, len(x)))
            for i, v in enumerate(x):
                walk(v, path + ["#%d" % i])
            out.append("%s/#%d none" % (p, len(x)))
        elif isinstance(x, str):
            b = enc(x)
            ires, ival = int_expect(x) if b.isascii() else (-1, 0)
            out.append("%s str %s %d %d" % (p, b.hex() or "-", ires, ival))
        elif x is True or x is False or x is None:
            out.append("%s prim %s -1 0" % (p, {True: "true", False: "false", None: "null"}[x]))
        else:
            t = json.dumps(x)
            ires, ival = int_expect(t)
            out.append("%s prim %s %d %d" % (p, t, ires, ival))
    walk(obj, [])
    return "\n".join(out) + "\n"


# ------------------------------------------------------------------ big
def big_doc(seed, target=5_300_000):
    r = random.Random(seed)
    g = Gen(seed + 1)
    recs = []
    size = 2
    while size < target:
        rec = '{"id":%d,"name":%s,"score":%s,"tags":[%s],"ok":%s,"pos":{"x":%s,"y":%s},"n":null}' % (
            len(recs), g.string(16), g.number(), ",".join(g.string(6) for _ in range(r.randint(0, 3))),
            r.choice(["true", "false"]), g.number(), g.number())
        recs.append(rec)
        size += len(rec) + 2
    return ("[\n" + ",\n".join(recs) + "\n]\n").encode("utf-8")


def strings_doc(seed, target=5_000_000):
    r = random.Random(seed)
    parts = []
    size = 0
    while size < target:
        n = r.randint(200, 5000)
        body = "".join(r.choice("abcdefghijklmnopqrstuvwxyz0123456789/?=%._-") for _ in range(n))
        body = body.replace("?", "\\u0026", 3).replace("%", "\\\"", 1)
        parts.append('"' + body + '"')
        size += n + 4
    return ("[" + ",".join(parts) + "]").encode()


def write(name, data):
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(1950)
    cases = []

    def case(data, ref):
        cases.append((data, ref))

    # random documents, their prefixes and edits
    stats = {"valid": 0, "prefix": 0, "mut_ok": 0, "mut_bad": 0, "edge": 0}
    g = Gen(2026)
    docs = []
    for i in range(2500):
        text = g.doc()
        data = text.encode("utf-8")
        ref = ref_for(data)
        assert ref.startswith("OK"), (text, ref)
        case(data, ref)
        docs.append(text)
        stats["valid"] += 1
    for text in docs[:250]:
        data = text.encode("utf-8")
        if len(data) <= 400:
            cuts = range(len(data))
        else:
            cuts = sorted(rng.sample(range(len(data)), 40))
        for k in cuts:
            case(data[:k], ref_for(data[:k], "-3"))
            stats["prefix"] += 1
    for i in range(12000):
        text = mutate(rng.choice(docs), rng)
        data = text.encode("utf-8")
        ref = ref_for(data)
        stats["mut_ok" if ref.startswith("OK") else "mut_bad"] += 1
        case(data, ref)
    for data, code in edge_cases():
        if code == "-4":                # (valid JSON, but deeper than MOOS takes)
            case(data, "ERR -4\n")
            stats["edge"] += 1
            continue
        ref = deep_ref(data) if data.count(b"[") + data.count(b"{") > 500 else ref_for(data)
        if code is None:
            assert ref.startswith("OK"), (data[:40], ref[:40])
        else:
            assert ref.startswith("ERR"), (data[:40], ref[:40])
            ref = "ERR %s\n" % code
        case(data, ref)
        stats["edge"] += 1
    with open(os.path.join(OUT, "cases.bin"), "wb") as f:
        for data, ref in cases:
            rb = ref.encode()
            f.write(struct.pack("<I", len(data)) + data + struct.pack("<I", len(rb)) + rb)
    print("cases.bin: %d documents (%s)" % (len(cases), ", ".join("%s %d" % kv for kv in stats.items())))

    files = []
    for name, data, exp in [
            ("player.json", yt_dump(player_response(1), True).encode(), True),
            ("player_compact.json", yt_dump(player_response(2), False).encode(), True),
            ("search.json", yt_dump(search_response(3), False).encode(), True),
            ("search_pretty.json", yt_dump(search_response(4, 40), True).encode(), True),
            ("big.json", big_doc(5), False),
            ("strings.json", strings_doc(6), False)]:
        write(name, data)
        v = py_valid(data)
        assert v is not None, name
        ref = ref_ok(v[0])
        write(name[:-5] + ".ref", ref.encode())
        if exp:
            write(name[:-5] + ".exp", path_checks(json.loads(data)).encode())
        files.append(name)
        print("%-20s %9d bytes %7d tokens" % (name, len(data), int(ref.split("\n", 1)[0].split()[1])))
    write("list.txt", ("\n".join(files) + "\n").encode())


if __name__ == "__main__":
    main()
