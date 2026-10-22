package app.headroom.home;

import android.annotation.SuppressLint;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.LruCache;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The launchable activities, refreshed only when the package list actually changes. */
public final class AppCatalog {

    private static final String TAG = "headroom";

    public interface Listener {
        void onAppsChanged();
    }

    private final Context app;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Listener> listeners = new ArrayList<>();
    private final LruCache<String, Bitmap> icons;
    private volatile List<App> apps = Collections.emptyList();
    private static AppCatalog instance;

    public static synchronized AppCatalog get(Context c) {
        if (instance == null) instance = new AppCatalog(c);
        return instance;
    }

    private final BroadcastReceiver changes = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            reload();
        }
    };

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    private AppCatalog(Context c) {
        app = c.getApplicationContext();
        int maxKb = (int) (Runtime.getRuntime().maxMemory() / 1024 / 16); // 1/16 of the heap
        icons = new LruCache<String, Bitmap>(maxKb) {
            @Override
            protected int sizeOf(String key, Bitmap bitmap) {
                return Math.max(1, bitmap.getByteCount() / 1024);
            }
        };
        // Registered once for the life of the process. It wakes only when a package changes, so it
        // costs nothing while you drive, and HOME presses never trigger a re-scan.
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_PACKAGE_ADDED);
        filter.addAction(Intent.ACTION_PACKAGE_REMOVED);
        filter.addAction(Intent.ACTION_PACKAGE_CHANGED); // fires when debloat disables/enables an app
        filter.addDataScheme("package");
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(
                changes,
                filter,
                Context.RECEIVER_NOT_EXPORTED
            );
        } else {
            app.registerReceiver(changes, filter); // protected system broadcasts only
        }
        reload();
    }

    /** Called from onStart of each screen. Does not re-scan: the receiver keeps the list current. */
    public void addListener(Listener listener) {
        listeners.add(listener);
    }

    public void removeListener(Listener listener) {
        listeners.remove(listener);
    }

    public void reload() {
        // Silent unless someone runs: adb shell setprop log.tag.headroom DEBUG
        if (Log.isLoggable(TAG, Log.DEBUG)) Log.d(TAG, "catalog reload");
        io.execute(() -> {
            PackageManager pm = app.getPackageManager();
            Intent intent = new Intent(Intent.ACTION_MAIN).addCategory(
                Intent.CATEGORY_LAUNCHER
            );
            List<App> list = new ArrayList<>();
            for (ResolveInfo info : pm.queryIntentActivities(intent, 0)) {
                list.add(
                    new App(
                        info.activityInfo.packageName,
                        info.activityInfo.name,
                        String.valueOf(info.loadLabel(pm))
                    )
                );
            }
            main.post(() -> {
                apps = list;
                icons.evictAll();
                for (Listener listener : new ArrayList<>(listeners))
                    listener.onAppsChanged();
            });
        });
    }

    /** The first activity of each package, in the order the system returned them. */
    public Map<String, App> byPackage() {
        Map<String, App> out = new LinkedHashMap<>();
        for (App a : apps) {
            if (!out.containsKey(a.pkg)) out.put(a.pkg, a);
        }
        return out;
    }

    public List<App> all() {
        return apps;
    }

    /** Cache hit, or draw the activity icon into a px by px bitmap. Null when the icon is gone. */
    public Bitmap icon(App a, int px) {
        int size = Math.max(1, px);
        String key = a.key() + "@" + size;
        Bitmap cached = icons.get(key);
        if (cached != null) return cached;
        try {
            Drawable drawable = app
                .getPackageManager()
                .getActivityIcon(new ComponentName(a.pkg, a.activity));
            Bitmap bitmap = Bitmap.createBitmap(
                size,
                size,
                Bitmap.Config.ARGB_8888
            );
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, size, size);
            drawable.draw(canvas);
            icons.put(key, bitmap);
            return bitmap;
        } catch (PackageManager.NameNotFoundException e) {
            return null;
        }
    }

    public void trimIcons() {
        icons.evictAll();
    }
}
