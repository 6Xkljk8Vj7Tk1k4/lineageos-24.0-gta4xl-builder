// Hardware video decoder test for the tablet, without an app: decodes the first video track of
// a file (MP4, 3GP, WebM) with one MediaCodec decoder into byte buffers and counts the frames.
//
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex app_process /system/bin DecTest \
//       /data/local/tmp/t.mp4 OMX.Exynos.hevc.dec
//
// "-" as the decoder name picks the first hardware decoder for the track's MIME type. The last
// line printed is "RESULT ok=<0|1> ..."; ok means: no error, end of stream reached, and at least
// as many frames out as the third argument asks for (default 1).
// tools/tablet-test.sh feeds it what EncTest produced, put into a container by ffmpeg on the host.

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaExtractor;
import android.media.MediaFormat;

import java.nio.ByteBuffer;

public class DecTest {
    static String pick(String mime) {
        for (MediaCodecInfo ci : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (ci.isEncoder() || !ci.isHardwareAccelerated()) continue;
            for (String t : ci.getSupportedTypes())
                if (t.equalsIgnoreCase(mime)) return ci.getName();
        }
        return null;
    }

    public static void main(String[] a) throws Exception {
        if (a.length < 1) { System.out.println("usage: DecTest FILE [DECODER|-] [MIN_FRAMES]"); return; }
        int want = a.length > 2 ? Integer.parseInt(a[2]) : 1;
        String err = "", mime = "?", name = "?";
        int in = 0, out = 0, w = 0, h = 0;
        long t0 = System.currentTimeMillis();
        MediaExtractor ex = new MediaExtractor();
        MediaCodec c = null;
        boolean eosOut = false;
        try {
            ex.setDataSource(a[0]);
            MediaFormat f = null;
            for (int i = 0; i < ex.getTrackCount(); i++) {
                MediaFormat t = ex.getTrackFormat(i);
                if (t.getString(MediaFormat.KEY_MIME).startsWith("video/")) { f = t; ex.selectTrack(i); break; }
            }
            if (f == null) throw new RuntimeException("no video track");
            mime = f.getString(MediaFormat.KEY_MIME);
            name = a.length > 1 && !a[1].equals("-") ? a[1] : pick(mime);
            if (name == null) throw new RuntimeException("no hardware decoder");
            c = MediaCodec.createByCodecName(name);
            c.configure(f, null, null, 0);
            c.start();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean eosIn = false;
            long deadline = System.currentTimeMillis() + 30000;
            while (!eosOut && System.currentTimeMillis() < deadline) {
                if (!eosIn) {
                    int i = c.dequeueInputBuffer(10000);
                    if (i >= 0) {
                        ByteBuffer b = c.getInputBuffer(i);
                        int n = ex.readSampleData(b, 0);
                        if (n < 0) {
                            c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            eosIn = true;
                        } else {
                            c.queueInputBuffer(i, 0, n, ex.getSampleTime(), 0);
                            ex.advance();
                            in++;
                        }
                    }
                }
                int o = c.dequeueOutputBuffer(info, 10000);
                if (o >= 0) {
                    if (info.size > 0) out++;
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eosOut = true;
                    c.releaseOutputBuffer(o, false);
                } else if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat of = c.getOutputFormat();
                    w = of.getInteger(MediaFormat.KEY_WIDTH);
                    h = of.getInteger(MediaFormat.KEY_HEIGHT);
                }
            }
            if (!eosOut) err = "timeout";
            c.stop();
        } catch (Throwable t) {
            err = t.toString().replace(' ', '_');
        } finally {
            if (c != null) try { c.release(); } catch (Throwable t) { }
            ex.release();
        }
        boolean ok = err.isEmpty() && out >= want;
        System.out.println("RESULT ok=" + (ok ? 1 : 0) + " codec=" + name + " mime=" + mime + " size=" + w + "x" + h
                + " samples_in=" + in + " frames_out=" + out + " ms=" + (System.currentTimeMillis() - t0)
                + (err.isEmpty() ? "" : " error=" + err));
        System.exit(ok ? 0 : 1);
    }
}
