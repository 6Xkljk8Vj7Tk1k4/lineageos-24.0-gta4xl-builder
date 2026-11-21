// Hardware video encoder test for the tablet, without an app: feeds synthetic frames to one
// MediaCodec encoder and writes the bitstream to a file (Annex B for AVC/HEVC, IVF for VP8/VP9).
//
//   tools/tablet-enctest/build.sh                      # -> build_output/tablet-enctest/enctest.dex
//   adb push build_output/tablet-enctest/enctest.dex /data/local/tmp/
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex app_process /system/bin EncTest list
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex app_process /system/bin EncTest \
//       video/hevc OMX.Exynos.HEVC.Encoder 1280 720 60 /data/local/tmp/t.hevc
//
// The last line printed is "RESULT ok=<0|1> ..."; check the file on the host with ffprobe.
// "-" as the encoder name picks the first hardware encoder for the MIME type.

import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;

import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public class EncTest {
    static void list() {
        for (MediaCodecInfo ci : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (!ci.isEncoder()) continue;
            for (String t : ci.getSupportedTypes()) {
                if (!t.startsWith("video/")) continue;
                System.out.println((ci.isHardwareAccelerated() ? "hw " : "sw ") + t + " " + ci.getName());
            }
        }
    }

    static String pick(String mime) {
        for (MediaCodecInfo ci : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (!ci.isEncoder() || !ci.isHardwareAccelerated()) continue;
            for (String t : ci.getSupportedTypes())
                if (t.equalsIgnoreCase(mime)) return ci.getName();
        }
        return null;
    }

    // A moving diagonal gradient with a moving block: enough motion for P frames.
    static void fill(Image img, int n) {
        Image.Plane[] p = img.getPlanes();
        int w = img.getWidth(), h = img.getHeight();
        ByteBuffer y = p[0].getBuffer();
        int ys = p[0].getRowStride();
        byte[] row = new byte[w];
        for (int j = 0; j < h; j++) {
            for (int i = 0; i < w; i++) {
                int v = ((i + j + 4 * n) >> 2) & 0xff;
                if (i >= 8 * n % (w - 64) && i < 8 * n % (w - 64) + 64 && j >= 100 && j < 164) v = 235;
                row[i] = (byte) v;
            }
            y.position(j * ys);
            y.put(row, 0, w);
        }
        for (int c = 1; c <= 2; c++) {
            ByteBuffer b = p[c].getBuffer();
            int rs = p[c].getRowStride(), ps = p[c].getPixelStride();
            for (int j = 0; j < h / 2; j++)
                for (int i = 0; i < w / 2; i++)
                    b.put(j * rs + i * ps, (byte) (c == 1 ? 96 + (j * 64 / h) : 160 - (i * 64 / w)));
        }
    }

    static void le(OutputStream o, long v, int bytes) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        b.putLong(v);
        o.write(b.array(), 0, bytes);
    }

    public static void main(String[] a) throws Exception {
        if (a.length < 1 || a[0].equals("list")) { list(); return; }
        String mime = a[0];
        String name = a.length > 1 && !a[1].equals("-") ? a[1] : pick(mime);
        int w = a.length > 2 ? Integer.parseInt(a[2]) : 1280;
        int h = a.length > 3 ? Integer.parseInt(a[3]) : 720;
        int frames = a.length > 4 ? Integer.parseInt(a[4]) : 60;
        String out = a.length > 5 ? a[5] : null;
        boolean ivf = mime.contains("vp8") || mime.contains("vp9");
        if (name == null) { System.out.println("RESULT ok=0 error=no-hardware-encoder mime=" + mime); return; }

        int inFrames = 0, outBufs = 0, keys = 0, cfg = 0;
        long bytes = 0, t0 = System.currentTimeMillis();
        String err = "";
        MediaCodec c = null;
        OutputStream os = out != null ? new FileOutputStream(out) : null;
        try {
            c = MediaCodec.createByCodecName(name);
            MediaFormat f = MediaFormat.createVideoFormat(mime, w, h);
            f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
            f.setInteger(MediaFormat.KEY_BIT_RATE, 4000000);
            f.setInteger(MediaFormat.KEY_FRAME_RATE, 30);
            f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            c.start();
            if (ivf && os != null) {
                os.write(new byte[] {'D', 'K', 'I', 'F'});
                le(os, 0, 2); le(os, 32, 2);
                os.write((mime.contains("vp9") ? "VP90" : "VP80").getBytes());
                le(os, w, 2); le(os, h, 2); le(os, 30, 4); le(os, 1, 4); le(os, frames, 4); le(os, 0, 4);
            }
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean eosIn = false, eosOut = false;
            long deadline = System.currentTimeMillis() + 30000 + frames * 200L;
            while (!eosOut && System.currentTimeMillis() < deadline) {
                if (!eosIn) {
                    int i = c.dequeueInputBuffer(10000);
                    if (i >= 0) {
                        if (inFrames < frames) {
                            Image img = c.getInputImage(i);
                            fill(img, inFrames);
                            c.queueInputBuffer(i, 0, w * h * 3 / 2, inFrames * 1000000L / 30, 0);
                            inFrames++;
                        } else {
                            c.queueInputBuffer(i, 0, 0, inFrames * 1000000L / 30, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            eosIn = true;
                        }
                    }
                }
                int o = c.dequeueOutputBuffer(info, 10000);
                if (o >= 0) {
                    if (info.size > 0) {
                        ByteBuffer b = c.getOutputBuffer(o);
                        byte[] d = new byte[info.size];
                        b.position(info.offset);
                        b.get(d);
                        boolean isCfg = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                        if (isCfg) cfg++; else outBufs++;
                        if ((info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0) keys++;
                        bytes += info.size;
                        if (os != null && !(ivf && isCfg)) {
                            if (ivf) { le(os, info.size, 4); le(os, info.presentationTimeUs * 30 / 1000000, 8); }
                            os.write(d);
                        }
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eosOut = true;
                    c.releaseOutputBuffer(o, false);
                }
            }
            if (!eosOut) err = "timeout";
            c.stop();
        } catch (Throwable t) {
            err = t.toString().replace(' ', '_');
        } finally {
            if (c != null) try { c.release(); } catch (Throwable t) { }
            if (os != null) os.close();
        }
        boolean ok = err.isEmpty() && outBufs >= frames;
        System.out.println("RESULT ok=" + (ok ? 1 : 0) + " codec=" + name + " mime=" + mime + " size=" + w + "x" + h
                + " frames_in=" + inFrames + " out_buffers=" + outBufs + " config=" + cfg + " keyframes=" + keys
                + " bytes=" + bytes + " ms=" + (System.currentTimeMillis() - t0) + (err.isEmpty() ? "" : " error=" + err));
        System.exit(ok ? 0 : 1);
    }
}
