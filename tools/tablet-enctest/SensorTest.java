// Sensor delivery test for the tablet, without an app: registers for the default sensor of every
// type the tablet has, as an app would through SensorManager, and prints what arrived.
//
//   adb shell CLASSPATH=/data/local/tmp/enctest.dex app_process /system/bin SensorTest [MS]
//
// One line per sensor: "SENSOR type=<n> name=<name> events=<count> last=<v0>,<v1>,<v2>", then
// "RESULT sensors=<n>". On-change sensors (light) report once on registration and then only
// when the value changes. The process has no application behind it, so it builds the system
// context the way other shell tools do; nothing is installed.

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Handler;
import android.os.Looper;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class SensorTest {
    static final int[] TYPES = {
        Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_LIGHT, Sensor.TYPE_MAGNETIC_FIELD,
        Sensor.TYPE_PROXIMITY, Sensor.TYPE_PRESSURE, Sensor.TYPE_GRAVITY, Sensor.TYPE_ROTATION_VECTOR,
    };

    public static void main(String[] a) throws Exception {
        final int ms = a.length > 0 ? Integer.parseInt(a[0]) : 2000;
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Constructor<?> ctor = at.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object thread = ctor.newInstance();
        Field cur = at.getDeclaredField("sCurrentActivityThread");
        cur.setAccessible(true);
        cur.set(null, thread);
        Context ctx = (Context) at.getDeclaredMethod("getSystemContext").invoke(thread);
        final SensorManager sm = (SensorManager) ctx.getSystemService(Context.SENSOR_SERVICE);

        final Map<Sensor, int[]> count = new LinkedHashMap<>();
        final Map<Sensor, float[]> last = new LinkedHashMap<>();
        final SensorEventListener l = new SensorEventListener() {
            public void onSensorChanged(SensorEvent e) {
                count.get(e.sensor)[0]++;
                last.put(e.sensor, e.values.clone());
            }
            public void onAccuracyChanged(Sensor s, int accuracy) { }
        };
        final Handler h = new Handler(Looper.getMainLooper());
        final List<Sensor> used = new ArrayList<>();
        for (int t : TYPES) {
            Sensor s = sm.getDefaultSensor(t);
            if (s == null) continue;
            count.put(s, new int[1]);
            if (sm.registerListener(l, s, SensorManager.SENSOR_DELAY_GAME, h)) used.add(s);
            else System.out.println("SENSOR type=" + t + " name=" + s.getName().replace(' ', '_') + " error=registerListener");
        }
        h.postDelayed(new Runnable() {
            public void run() {
                sm.unregisterListener(l);
                for (Sensor s : used) {
                    float[] v = last.get(s);
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; v != null && i < Math.min(3, v.length); i++) sb.append(i > 0 ? "," : "").append(v[i]);
                    System.out.println("SENSOR type=" + s.getType() + " name=" + s.getName().replace(' ', '_')
                            + " events=" + count.get(s)[0] + " last=" + (v == null ? "-" : sb.toString()));
                }
                System.out.println("RESULT sensors=" + used.size());
                System.exit(0);
            }
        }, ms);
        Looper.loop();
    }
}
