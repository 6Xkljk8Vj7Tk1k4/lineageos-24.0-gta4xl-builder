// Speaker and microphone test for the tablet, without an app and without a person listening:
// plays a sine tone on the media stream and records the microphone at the same time, then
// measures how much of that tone is in the recording, before and while it plays.
//
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex app_process /system/bin AudioLoop [HZ] [MS]
//
// The last line printed is "RESULT ok=<0|1> freq=<Hz> tone_before_dbfs=<level of that frequency
// in the 0.3 s before the tone> tone_during_dbfs=<its level while the tone plays> gain_db=<the
// difference> rms_during_dbfs=<all sound while it plays> clipped=<samples at full scale>".
// ok means that playback and recording ran; whether the tone arrived is the caller's decision
// (tools/tablet-test.sh asks for 20 dB). The media volume is the caller's business too: this tool
// plays at whatever is set. Defaults: 1000 Hz for 1500 ms.

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;

public class AudioLoop {
    static final int RATE = 48000;

    // Level of one frequency in x[from..to), as dB relative to a full-scale sine (Goertzel).
    static double tone(short[] x, int from, int to, double hz) {
        int n = to - from;
        if (n <= 0) return -120;
        double w = 2 * Math.PI * hz / RATE, c = 2 * Math.cos(w), s1 = 0, s2 = 0;
        for (int i = from; i < to; i++) {
            double s = x[i] / 32768.0 + c * s1 - s2;
            s2 = s1;
            s1 = s;
        }
        double power = s1 * s1 + s2 * s2 - c * s1 * s2;          // |X(k)|^2
        double amp = 2 * Math.sqrt(Math.max(power, 0)) / n;      // amplitude of that component
        return amp <= 1e-6 ? -120 : 20 * Math.log10(amp);
    }

    static double rms(short[] x, int from, int to) {
        double s = 0;
        for (int i = from; i < to; i++) s += (x[i] / 32768.0) * (x[i] / 32768.0);
        double r = to > from ? Math.sqrt(s / (to - from)) : 0;
        return r <= 1e-6 ? -120 : 20 * Math.log10(r);
    }

    public static void main(String[] a) {
        double hz = a.length > 0 ? Double.parseDouble(a[0]) : 1000;
        int ms = a.length > 1 ? Integer.parseInt(a[1]) : 1500;
        int before = RATE * 3 / 10, during = RATE / 1000 * ms, total = before + during + RATE / 5;
        short[] rec = new short[total];
        String err = "";
        int got = 0;
        AudioRecord r = null;
        AudioTrack t = null;
        try {
            int min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            r = new AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, Math.max(min, RATE));
            if (r.getState() != AudioRecord.STATE_INITIALIZED) throw new RuntimeException("AudioRecord not initialised");
            short[] sine = new short[during];
            int fade = RATE / 50;                                 // 20 ms in and out: no click
            for (int i = 0; i < during; i++) {
                double g = Math.min(1.0, Math.min(i, during - 1 - i) / (double) fade);
                sine[i] = (short) (0.5 * g * 32767 * Math.sin(2 * Math.PI * hz * i / RATE));
            }
            t = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                    .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(during * 2).build();
            t.write(sine, 0, during);
            r.startRecording();
            boolean playing = false;
            while (got < total) {
                int n = r.read(rec, got, Math.min(RATE / 50, total - got));
                if (n <= 0) throw new RuntimeException("AudioRecord.read returned " + n);
                got += n;
                if (!playing && got >= before) { t.play(); playing = true; }
            }
        } catch (Throwable e) {
            err = e.toString().replace(' ', '_');
        } finally {
            if (t != null) try { t.stop(); t.release(); } catch (Throwable e) { }
            if (r != null) try { r.stop(); r.release(); } catch (Throwable e) { }
        }
        // Before: the first 0.3 s without its first 50 ms. During: from 0.4 s after play() was
        // called (output latency) until 0.1 s before the tone ends.
        int b0 = RATE / 20, b1 = before, d0 = before + RATE * 4 / 10, d1 = before + during - RATE / 10;
        int clipped = 0;
        for (int i = 0; i < got; i++) if (rec[i] >= 32760 || rec[i] <= -32760) clipped++;
        boolean ok = err.isEmpty() && got == total && d1 > d0;
        double tb = tone(rec, b0, b1, hz), td = ok ? tone(rec, d0, d1, hz) : -120;
        System.out.println(String.format(java.util.Locale.US,
                "RESULT ok=%d freq=%.0f tone_before_dbfs=%.1f tone_during_dbfs=%.1f gain_db=%.1f rms_during_dbfs=%.1f clipped=%d%s",
                ok ? 1 : 0, hz, tb, td, td - tb, ok ? rms(rec, d0, d1) : -120, clipped, err.isEmpty() ? "" : " error=" + err));
        System.exit(ok ? 0 : 1);
    }
}
