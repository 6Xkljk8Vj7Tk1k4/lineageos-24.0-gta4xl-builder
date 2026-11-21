// GNSS test for the tablet, without an app: asks the location service for GPS positions the way
// an app does and reports what the receiver delivers in that time.
//
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex app_process /system/bin GnssTest [SECONDS]
//
// The last line printed is "RESULT ok=<0|1> started=<0|1> reports=<satellite status reports>
// satellites=<most seen at once> used=<most used in a fix> cn0_max=<strongest signal, dB-Hz>
// fix=<0|1> ttff_ms=<time to the first fix, -1 without one>". No position is printed. ok means
// that the request was accepted and the receiver started; indoors it will see few satellites
// or none, which is for the caller to judge. Location has to be switched on.
//
// The location service accepts a caller only under a package name that belongs to its uid, and
// uid 0 has none: the process becomes the system uid before its first call.

import android.content.Context;
import android.location.GnssStatus;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.system.Os;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;

public class GnssTest {
    static int started, reports, sats, used, fix;
    static float cn0;
    static long ttff = -1;

    public static void main(String[] a) throws Exception {
        final int secs = a.length > 0 ? Integer.parseInt(a[0]) : 20;
        try {
            Os.setgid(1000);
            Os.setuid(1000);
            Looper.prepareMainLooper();
            Class<?> at = Class.forName("android.app.ActivityThread");
            Constructor<?> ctor = at.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object thread = ctor.newInstance();
            Field cur = at.getDeclaredField("sCurrentActivityThread");
            cur.setAccessible(true);
            cur.set(null, thread);
            Context ctx = (Context) at.getDeclaredMethod("getSystemContext").invoke(thread);
            final LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
            if (!lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) throw new RuntimeException("gps provider disabled");
            final Handler h = new Handler(Looper.getMainLooper());
            final long t0 = System.currentTimeMillis();
            final GnssStatus.Callback cb = new GnssStatus.Callback() {
                public void onStarted() { started = 1; }
                public void onFirstFix(int ms) { ttff = ms; }
                public void onSatelliteStatusChanged(GnssStatus s) {
                    reports++;
                    int n = 0, u = 0;
                    for (int i = 0; i < s.getSatelliteCount(); i++) {
                        if (s.getCn0DbHz(i) > 0) n++;
                        if (s.usedInFix(i)) u++;
                        cn0 = Math.max(cn0, s.getCn0DbHz(i));
                    }
                    sats = Math.max(sats, n);
                    used = Math.max(used, u);
                }
            };
            final LocationListener ll = new LocationListener() {
                public void onLocationChanged(Location l) { if (fix == 0 && ttff < 0) ttff = System.currentTimeMillis() - t0; fix = 1; }
                public void onProviderEnabled(String p) { }
                public void onProviderDisabled(String p) { }
                public void onStatusChanged(String p, int s, Bundle b) { }
            };
            lm.registerGnssStatusCallback(cb, h);
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0, ll, Looper.getMainLooper());
            h.postDelayed(new Runnable() {
                public void run() {
                    lm.removeUpdates(ll);
                    lm.unregisterGnssStatusCallback(cb);
                    finish("");
                }
            }, secs * 1000L);
            Looper.loop();
        } catch (Throwable e) {
            finish(e.toString().replace(' ', '_'));
        }
    }

    static void finish(String err) {
        boolean ok = err.isEmpty() && started == 1;
        System.out.println(String.format(java.util.Locale.US,
                "RESULT ok=%d started=%d reports=%d satellites=%d used=%d cn0_max=%.1f fix=%d ttff_ms=%d%s",
                ok ? 1 : 0, started, reports, sats, used, cn0, fix, ttff, err.isEmpty() ? "" : " error=" + err));
        System.exit(ok ? 0 : 1);
    }
}
