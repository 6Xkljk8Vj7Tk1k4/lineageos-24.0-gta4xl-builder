#!/usr/bin/env python3
"""media_check.py photo|screen|video FILE: looks into what the tablet produced, for tools/tablet-test.sh.

photo, screen  decodes the image (PIL): prints "ok=1 size=WxH mean=<0-255> std=<spread>"
video          container and streams (ffprobe), then decodes the sound to PCM (ffmpeg) and
               measures it: prints "ok=1 video=<codec> WxH <seconds>s audio=<codec>
               rms_dbfs=<level> peak_dbfs=<level>"
ok=0 and "error=..." when the file cannot be decoded. A dead microphone path gives digital
silence (below -85 dBFS); a quiet room is around -60. Nothing is judged here beyond "decodes":
the thresholds are in tools/tablet-test.sh.
"""
import json
import subprocess
import sys


def image(path):
    from PIL import Image, ImageStat
    im = Image.open(path)
    im.load()
    st = ImageStat.Stat(im.convert('L'))
    print('ok=1 size=%dx%d mean=%.1f std=%.1f' % (im.size[0], im.size[1], st.mean[0], st.stddev[0]))


def video(path):
    import numpy as np
    p = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    info = json.loads(p.stdout or '{}')
    v = [s for s in info.get('streams', []) if s.get('codec_type') == 'video']
    a = [s for s in info.get('streams', []) if s.get('codec_type') == 'audio']
    if not v:
        print('ok=0 error=no-video-stream %s' % p.stderr.strip().replace(' ', '_')[:80])
        return
    out = 'ok=1 video=%s %sx%s %.1fs' % (v[0].get('codec_name'), v[0].get('width'), v[0].get('height'),
                                         float(info.get('format', {}).get('duration', 0)))
    if not a:
        print(out + ' audio=none')
        return
    pcm = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', path, '-vn', '-ac', '1', '-ar', '16000',
                          '-f', 's16le', '-'], capture_output=True).stdout
    x = np.frombuffer(pcm, dtype='<i2').astype(np.float64)
    if x.size == 0:
        print(out + ' audio=%s rms_dbfs=-inf peak_dbfs=-inf' % a[0].get('codec_name'))
        return
    x = x[x.size // 10:]                      # the first tenth holds the start click of the recorder
    rms = np.sqrt(np.mean(x * x))
    peak = np.max(np.abs(x))
    db = lambda val: -120.0 if val <= 0 else 20 * np.log10(val / 32768.0)
    print(out + ' audio=%s rms_dbfs=%.1f peak_dbfs=%.1f' % (a[0].get('codec_name'), db(rms), db(peak)))


try:
    kind, path = sys.argv[1], sys.argv[2]
    video(path) if kind == 'video' else image(path)
except Exception as e:  # one line for the caller, whatever went wrong
    print('ok=0 error=%s' % repr(e).replace(' ', '_')[:120])
