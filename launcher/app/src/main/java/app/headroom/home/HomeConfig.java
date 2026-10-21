package app.headroom.home;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** The one place settings live: the app's private SharedPreferences. Defaults come from the build. */
public final class HomeConfig {
    private static final String FILE = "home";
    private static final String KEY_DOCK = "dock";
    private static final String KEY_HIDDEN = "hidden";
    private static final String KEY_SLOTS = "dock_slots";
    private static final String KEY_COLUMNS = "columns";
    private static final String KEY_CLOCK = "clock";

    private static HomeConfig instance;

    private final SharedPreferences prefs;
    private final String defaultDock;

    public static synchronized HomeConfig get(Context c) {
        if (instance == null) instance = new HomeConfig(c.getApplicationContext());
        return instance;
    }

    private HomeConfig(Context c) {
        prefs = c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
        defaultDock = c.getString(R.string.default_dock);
    }

    public List<String> dock() {
        return ConfigCodec.parseList(prefs.getString(KEY_DOCK, defaultDock));
    }

    public void setDock(List<String> dock) {
        prefs.edit().putString(KEY_DOCK, ConfigCodec.join(dock)).apply();
    }

    public Set<String> hidden() {
        return new LinkedHashSet<>(ConfigCodec.parseList(prefs.getString(KEY_HIDDEN, "")));
    }

    public void setHidden(Set<String> hidden) {
        prefs.edit().putString(KEY_HIDDEN, ConfigCodec.join(new ArrayList<>(hidden))).apply();
    }

    public int dockSlots() {
        return ConfigCodec.clamp(prefs.getInt(KEY_SLOTS, 5), 3, 6);
    }

    public void setDockSlots(int slots) {
        prefs.edit().putInt(KEY_SLOTS, ConfigCodec.clamp(slots, 3, 6)).apply();
    }

    /** 0 means auto. */
    public int columnsOverride() {
        return ConfigCodec.clamp(prefs.getInt(KEY_COLUMNS, 0), 0, 8);
    }

    public void setColumnsOverride(int columns) {
        prefs.edit().putInt(KEY_COLUMNS, ConfigCodec.clamp(columns, 0, 8)).apply();
    }

    /** "auto", "12" or "24". */
    public String clock() {
        String value = prefs.getString(KEY_CLOCK, "auto");
        return "12".equals(value) || "24".equals(value) ? value : "auto";
    }

    public void setClock(String clock) {
        prefs.edit().putString(KEY_CLOCK, clock).apply();
    }

    public void reset() {
        prefs.edit().clear().apply();
    }
}
