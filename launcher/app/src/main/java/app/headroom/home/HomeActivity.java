package app.headroom.home;

import android.app.Activity;
import android.content.ComponentCallbacks2;
import android.content.Intent;
import android.content.res.Configuration;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.format.DateFormat;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextClock;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** The home screen: clock, date, two chips, and the dock. Nothing scrolls. */
public final class HomeActivity extends Activity implements AppCatalog.Listener {
    private static final long DATE_TICK_MS = 60_000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable dateTick = new Runnable() {
        @Override public void run() {
            date.setText(DateFormat.format("EEE d MMM", System.currentTimeMillis()));
            handler.postDelayed(this, DATE_TICK_MS);
        }
    };

    private HomeConfig cfg;
    private AppCatalog catalog;
    private LinearLayout dock;
    private TextClock clock;
    private TextView date;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_home);
        cfg = HomeConfig.get(this);
        catalog = AppCatalog.get(this);
        dock = findViewById(R.id.dock);
        clock = findViewById(R.id.clock);
        date = findViewById(R.id.date);

        View settings = findViewById(R.id.settings);
        settings.setOnClickListener(v -> Launch.systemSettings(this));
        View options = findViewById(R.id.options);
        options.setOnClickListener(v -> startActivity(new Intent(this, OptionsActivity.class)));
    }

    @Override protected void onStart() {
        super.onStart();
        catalog.addListener(this);
        applyClock();
        dateTick.run();
        renderDock();
    }

    @Override protected void onStop() {
        handler.removeCallbacks(dateTick);
        catalog.removeListener(this);
        super.onStop();
    }

    @Override public void onAppsChanged() {
        renderDock();
    }

    @SuppressWarnings("deprecation")
    @Override public void onBackPressed() {
        // A home screen has nothing to go back to.
    }

    @Override public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) catalog.trimIcons();
    }

    @Override public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config); // configChanges keeps us alive, so lay out again
        renderDock();
    }

    private void applyClock() {
        String format = cfg.clock();
        clock.setFormat12Hour("24".equals(format) ? "HH:mm" : "h:mm");
        clock.setFormat24Hour("12".equals(format) ? "h:mm" : "HH:mm");
    }

    /** R.id.dock is a vertical LinearLayout holding one row per line of tiles. */
    private void renderDock() {
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        List<App> apps = DockModel.resolve(cfg.dock(), catalog.byPackage(), cfg.dockSlots());
        int count = apps.size() + 1; // + "All apps"
        int perRow = GridMath.perRow(metrics.widthPixels, metrics.density, count, 88, 16, 40);
        int rows = (count + perRow - 1) / perRow;
        int gap = Math.round(8 * metrics.density); // 16 dp between tiles
        int px = GridMath.tilePx(metrics.widthPixels, metrics.density, perRow, 16, 40);
        px = Math.min(px, metrics.heightPixels / 2 / rows - 2 * gap); // dock uses <= half the height
        px = Math.max(px, Math.round(GridMath.MIN_TOUCH_DP * metrics.density)); // ...but never below 76 dp

        List<View> tiles = new ArrayList<>();
        for (App app : apps) {
            TileView tile = new TileView(this);
            tile.bind(catalog.icon(app, px * 3 / 5), app.label);
            tile.setOnClickListener(v -> Launch.app(this, app));
            tile.setOnLongClickListener(v -> {
                TileMenu.show(this, v, app, this::renderDock);
                return true;
            });
            tiles.add(tile);
        }
        TileView all = new TileView(this);
        all.bindRes(R.drawable.ic_apps, getString(R.string.all_apps));
        all.setOnClickListener(v -> startActivity(new Intent(this, AppsActivity.class)));
        tiles.add(all);

        dock.removeAllViews();
        LinearLayout row = null;
        for (int i = 0; i < tiles.size(); i++) {
            if (i % perRow == 0) {
                row = new LinearLayout(this);
                row.setGravity(Gravity.CENTER_HORIZONTAL);
                dock.addView(row);
            }
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(px, px);
            params.setMargins(gap, gap, gap, gap);
            row.addView(tiles.get(i), params);
        }
    }
}
