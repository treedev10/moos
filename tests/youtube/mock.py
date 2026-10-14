#!/usr/bin/env python3
"""A stand-in for YouTube, to test the MOOS browser's YouTube pages and video
player without the internet.

    python tests/youtube/mock.py [--port 8090] [--host-ip 10.0.2.2]

It answers what MOOS asks YouTube (see src/youtube.asm):

  POST /youtubei/v1/player?...   the innertube "player" answer for a video id:
                                 playabilityStatus, videoDetails and
                                 streamingData.formats with an itag 18 stream
                                 whose address points back here
  POST /youtubei/v1/search?...   a "search" answer shaped like YouTube's
                                 (videoRenderer objects deep inside)
  GET  /vi/<id>/<name>.jpg       a thumbnail
  GET  /videoplayback?id=<id>    the video file, with Range requests (206)
  GET  /test/embed               a page with a YouTube <iframe>
  GET  /test/video               a page with a <video> and two <source>s

Videos (made with ffmpeg into build/ytmock/ the first time):
  clip001     10 s, 640x360 H.264 Baseline + AAC 44.1 kHz stereo (as itag 18)
  long0002    60 s, the same kind
  nosound3    5 s, video only
  blocked4    "playabilityStatus": LOGIN_REQUIRED for every client
  cipher05    only a signatureCipher stream (no plain address)
  vronly06    playable only for the ANDROID_VR client (others: UNPLAYABLE),
              to test the client fallback the other way round
  iosonly7    playable only for the IOS client (ANDROID_VR: UNPLAYABLE)

Point MOOS at it with a file yt.cfg containing
    api http://10.0.2.2:8090
    images http://10.0.2.2:8090
Each request is logged to stderr with the client name and version headers.
--throttle KBPS slows the video down; --drop N closes a video connection
after N bytes once (to test the player picking up where it broke off).
"""
import argparse
import http.server
import json
import os
import re
import subprocess
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, 'build', 'ytmock')

VIDEOS = {
    'clip001': dict(title='Test clip: colour bars & a 440 Hz tone', author='MOOS Test Channel',
                    seconds=10, views=1234567, audio=True),
    'long0002': dict(title='A longer test video (one minute)', author='MOOS Test Channel',
                     seconds=60, views=987, audio=True),
    'nosound3': dict(title='Silent clip "no audio"', author='Quiet <Channel>', seconds=5,
                     views=5, audio=False),
    'blocked4': dict(title='Blocked video', author='Nobody', seconds=5, views=1, audio=True,
                     status='LOGIN_REQUIRED', reason='Sign in to confirm your age'),
    'cipher05': dict(title='Ciphered stream', author='Nobody', seconds=5, views=1, audio=True,
                     cipher=True),
    'vronly06': dict(title='Only for the VR app', author='Nobody', seconds=5, views=1,
                     audio=True, only='ANDROID_VR'),
    'iosonly7': dict(title='Only for the iOS app', author='Nobody', seconds=5, views=1,
                     audio=True, only='IOS'),
}
ARGS = None
DROPPED = set()


def make_media():
    """The video files and thumbnails, made once with ffmpeg."""
    os.makedirs(DATA, exist_ok=True)
    for vid, v in VIDEOS.items():
        out = os.path.join(DATA, vid + '.mp4')
        if not os.path.exists(out):
            cmd = ['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
                   'testsrc2=size=640x360:rate=30:duration=%d' % v['seconds']]
            if v['audio']:
                cmd += ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=%d'
                        % v['seconds'], '-ac', '2']
            cmd += ['-c:v', 'libx264', '-profile:v', 'baseline', '-level', '3.0',
                    '-pix_fmt', 'yuv420p', '-g', '60', '-b:v', '500k']
            if v['audio']:
                cmd += ['-c:a', 'aac', '-b:a', '96k', '-ar', '44100']
            cmd += ['-movflags', '+faststart', out]
            subprocess.run(cmd, check=True)
        for name, size in (('mqdefault', '320x180'), ('hqdefault', '480x360')):
            jpg = os.path.join(DATA, '%s_%s.jpg' % (vid, name))
            if not os.path.exists(jpg):
                subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '1', '-i', out, '-frames:v',
                                '1', '-s', size, jpg], check=True)


def text(s):
    return {'runs': [{'text': s}]}


def player_answer(body, client):
    vid = body.get('videoId', '')
    v = VIDEOS.get(vid)
    if not v:
        return {'playabilityStatus': {'status': 'ERROR', 'reason': 'Video unavailable'}}
    status = v.get('status', 'OK')
    reason = v.get('reason')
    if v.get('only') and client != v['only']:
        status, reason = 'UNPLAYABLE', 'This video is not available in this app'
    ans = {
        'responseContext': {'visitorData': 'Cgt4eXo', 'serviceTrackingParams': [{'service': 'GFEEDBACK', 'params': [{'key': 'e', 'value': '1,2,3'}]}]},
        'playabilityStatus': {'status': status, 'playableInEmbed': True},
        'videoDetails': {
            'videoId': vid, 'title': v['title'], 'lengthSeconds': str(v['seconds']),
            'keywords': ['test', 'moos'], 'channelId': 'UCmoos', 'isOwnerViewing': False,
            'shortDescription': 'This is a stand-in video for testing MOOS.\nSecond line & more: <b>not bold</b>\nété ☃',
            'isCrawlable': True, 'thumbnail': {'thumbnails': [{'url': 'x', 'width': 1, 'height': 1}]},
            'allowRatings': True, 'viewCount': str(v['views']), 'author': v['author'],
            'isPrivate': False, 'isUnpluggedCorpus': False, 'isLiveContent': False,
        },
    }
    if reason:
        ans['playabilityStatus']['reason'] = reason
    if status != 'OK':
        return ans
    path = os.path.join(DATA, vid + '.mp4')
    size = os.path.getsize(path)
    url = 'http://%s:%d/videoplayback?id=%s&itag=18&source=youtube&expire=1999999999&mime=video%%2Fmp4&clen=%d' % (
        ARGS.host_ip, ARGS.port, vid, size)
    fmt18 = {'itag': 18, 'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
             'bitrate': 600000, 'width': 640, 'height': 360, 'lastModified': '1700000000000000',
             'contentLength': str(size), 'quality': 'medium', 'fps': 30, 'qualityLabel': '360p',
             'projectionType': 'RECTANGULAR', 'averageBitrate': 590000,
             'audioQuality': 'AUDIO_QUALITY_LOW', 'approxDurationMs': str(v['seconds'] * 1000),
             'audioSampleRate': '44100', 'audioChannels': 2}
    if not v['audio']:
        fmt18['mimeType'] = 'video/mp4; codecs="avc1.42001E"'
    if v.get('cipher'):
        fmt18['signatureCipher'] = 's=ABCDEF&sp=sig&url=' + urllib.parse.quote(url, safe='')
    else:
        fmt18['url'] = url
    # a format MOOS must not pick first: Main profile video only
    fmt_main = {'itag': 134, 'url': url + '&bad=main', 'mimeType': 'video/mp4; codecs="avc1.4d401e"',
                'width': 640, 'height': 360}
    ans['streamingData'] = {'expiresInSeconds': '21540', 'formats': [fmt18],
                            'adaptiveFormats': [fmt_main,
                                                {'itag': 140, 'url': url + '&bad=audio',
                                                 'mimeType': 'audio/mp4; codecs="mp4a.40.2"'}]}
    if v.get('cipher'):
        ans['streamingData']['formats'] = [fmt18]
    return ans


def renderer(vid):
    v = VIDEOS[vid]
    m, s = divmod(v['seconds'], 60)
    return {'videoRenderer': {
        'videoId': vid,
        'thumbnail': {'thumbnails': [{'url': 'https://i.ytimg.com/vi/%s/hq720.jpg' % vid, 'width': 360, 'height': 202}]},
        'title': text(v['title']),
        'longBylineText': text(v['author']),
        'publishedTimeText': {'simpleText': '3 days ago'},
        'lengthText': {'accessibility': {'accessibilityData': {'label': '%d seconds' % v['seconds']}},
                       'simpleText': '%d:%02d' % (m, s)},
        'viewCountText': {'simpleText': '{:,} views'.format(v['views'])},
        'ownerText': text(v['author']),
        'shortBylineText': text(v['author']),
    }}


def search_answer(body):
    q = body.get('query', '')
    items = [renderer(vid) for vid in VIDEOS]
    if q == 'nothing':
        items = []
    # a channel and a shelf in between, as YouTube mixes them in
    items.insert(1, {'channelRenderer': {'channelId': 'UCx', 'title': {'simpleText': 'A channel'}}})
    items.insert(3, {'shelfRenderer': {'title': {'simpleText': 'People also watched'},
                                       'content': {'verticalListRenderer': {'items': [renderer('clip001')]}}}})
    return {'responseContext': {}, 'estimatedResults': '7',
            'contents': {'twoColumnSearchResultsRenderer': {'primaryContents': {
                'sectionListRenderer': {'contents': [
                    {'itemSectionRenderer': {'contents': items}},
                    {'continuationItemRenderer': {'trigger': 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN'}}]}}}},
            'refinements': [q + ' more']}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *a):
        sys.stderr.write('[ytmock] ' + (fmt % a) + '\n')

    def send(self, code, body, ctype, extra=()):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0'))
        raw = self.rfile.read(n)
        client = self.headers.get('X-YouTube-Client-Name', '?')
        sys.stderr.write('[ytmock] POST %s client=%s version=%s type=%s ua=%s\n' % (
            self.path, client, self.headers.get('X-YouTube-Client-Version'),
            self.headers.get('Content-Type'), self.headers.get('User-Agent')))
        sys.stderr.write('[ytmock]   body: %s\n' % raw[:400].decode('utf-8', 'replace'))
        try:
            body = json.loads(raw)
        except ValueError:
            return self.send(400, b'{"error":"bad json"}', 'application/json')
        name = body.get('context', {}).get('client', {}).get('clientName', '')
        if self.path.startswith('/youtubei/v1/player'):
            ans = player_answer(body, name)
        elif self.path.startswith('/youtubei/v1/search'):
            ans = search_answer(body)
        else:
            return self.send(404, b'{}', 'application/json')
        self.send(200, json.dumps(ans, ensure_ascii=ARGS.ascii).encode(), 'application/json; charset=UTF-8')

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        m = re.match(r'^/vi/([\w-]+)/(\w+)\.jpg$', u.path)
        if m:
            path = os.path.join(DATA, '%s_%s.jpg' % (m.group(1), m.group(2)))
            if m.group(2) not in ('mqdefault', 'hqdefault') or not os.path.exists(path):
                return self.send(404, b'no', 'text/plain')
            return self.send(200, open(path, 'rb').read(), 'image/jpeg')
        if u.path == '/test/embed':
            page = ('<title>Embed test</title><h1>An embedded video</h1>'
                    '<iframe width="560" height="315" src="https://www.youtube.com/embed/clip001?si=xyz" '
                    'frameborder="0" allowfullscreen></iframe><p>Text after the video.</p>')
            return self.send(200, page.encode(), 'text/html; charset=utf-8')
        if u.path == '/test/video':
            page = ('<title>Video test</title><h1>A plain video element</h1>'
                    '<video controls width="480" poster="/vi/clip001/hqdefault.jpg">'
                    '<source src="/nothing.webm" type="video/webm">'
                    '<source src="/videoplayback?id=clip001&amp;itag=18" type="video/mp4">'
                    'Your browser cannot play this.</video><p>Text after the video.</p>')
            return self.send(200, page.encode(), 'text/html; charset=utf-8')
        if u.path == '/videoplayback':
            q = urllib.parse.parse_qs(u.query)
            vid = q.get('id', [''])[0]
            if 'bad' in q or vid not in VIDEOS:
                return self.send(403, b'wrong stream', 'text/plain')
            data = open(os.path.join(DATA, vid + '.mp4'), 'rb').read()
            rng = self.headers.get('Range')
            sys.stderr.write('[ytmock] video %s Range: %s\n' % (vid, rng))
            start, end = 0, len(data) - 1
            code = 200
            if rng:
                m = re.match(r'bytes=(\d+)-(\d*)$', rng)
                if not m:
                    return self.send(416, b'', 'text/plain')
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), len(data) - 1)
                if start >= len(data):
                    return self.send(416, b'', 'text/plain', [('Content-Range', 'bytes */%d' % len(data))])
                code = 206
            part = data[start:end + 1]
            self.send_response(code)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(len(part)))
            if code == 206:
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, len(data)))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Connection', 'close')
            self.end_headers()
            limit = len(part)
            if ARGS.drop and (vid, start) not in DROPPED and len(part) > ARGS.drop:
                DROPPED.add((vid, start))
                limit = ARGS.drop
            step = 16384
            import time
            for i in range(0, limit, step):
                try:
                    self.wfile.write(part[i:min(i + step, limit)])
                except (BrokenPipeError, ConnectionResetError):
                    return
                if ARGS.throttle:
                    time.sleep(step / (ARGS.throttle * 1024.0))
            self.close_connection = True
            return
        self.send(404, b'not here', 'text/plain')


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8090)
    ap.add_argument('--host-ip', default='10.0.2.2')
    ap.add_argument('--throttle', type=float, default=0, help='KB/s for the video')
    ap.add_argument('--drop', type=int, default=0, help='break a video connection after N bytes (once per range)')
    ap.add_argument('--ascii', action='store_true', help='escape non-ASCII as \\uXXXX in JSON')
    ARGS = ap.parse_args()
    make_media()
    srv = http.server.ThreadingHTTPServer(('0.0.0.0', ARGS.port), H)
    sys.stderr.write('[ytmock] serving on port %d\n' % ARGS.port)
    srv.serve_forever()


if __name__ == '__main__':
    main()
