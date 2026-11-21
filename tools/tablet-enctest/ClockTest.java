// Cost of a clock read as apps see it (System.nanoTime() -> clock_gettime() through the vDSO).
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex taskset 40 app_process /system/bin ClockTest
// Prints "clock_read_lower <ns> ns" (best of five rounds of two million calls).
public class ClockTest {
    public static void main(String[] a) {
        long best = Long.MAX_VALUE, sink = 0;
        for (int r = 0; r < 5; r++) {
            long t0 = System.nanoTime();
            for (int i = 0; i < 2000000; i++) sink += System.nanoTime() & 1;
            long t = (System.nanoTime() - t0) / 2000000;
            if (t < best) best = t;
        }
        System.out.println("clock_read_lower " + best + " ns" + (sink == -1 ? "!" : ""));
    }
}
