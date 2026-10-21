package app.headroom.home;

import android.app.Activity;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.GridView;

import java.util.ArrayList;
import java.util.List;

/** The full app grid. Meant for when the unit is parked; a tap launches and closes it. */
public final class AppsActivity extends Activity implements AppCatalog.Listener {
    private final List<App> shown = new ArrayList<>();

    private HomeConfig cfg;
    private AppCatalog catalog;
    private GridView grid;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_apps);
        cfg = HomeConfig.get(this);
        catalog = AppCatalog.get(this);
        grid = findViewById(R.id.grid);
    }

    @Override protected void onStart() {
        super.onStart();
        catalog.addListener(this);
        render();
    }

    @Override protected void onStop() {
        catalog.removeListener(this);
        super.onStop();
    }

    @Override public void onAppsChanged() {
        render();
    }

    private void render() {
        shown.clear();
        shown.addAll(AppOrder.sorted(catalog.all(), cfg.hidden(), getPackageName()));
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        grid.setNumColumns(GridMath.columns(metrics.widthPixels, metrics.density, 96, 16,
                cfg.columnsOverride()));
        grid.setAdapter(new Adapter());
    }

    private final class Adapter extends BaseAdapter {
        @Override public int getCount() {
            return shown.size();
        }

        @Override public Object getItem(int position) {
            return shown.get(position);
        }

        @Override public long getItemId(int position) {
            return position;
        }

        @Override public View getView(int position, View convertView, ViewGroup parent) {
            TileView tile = convertView instanceof TileView
                    ? (TileView) convertView : new TileView(AppsActivity.this);
            App app = shown.get(position);
            DisplayMetrics metrics = getResources().getDisplayMetrics();
            int column = grid.getColumnWidth();
            int px = column > 0
                    ? Math.max(Math.round(GridMath.MIN_TOUCH_DP * metrics.density), column * 3 / 5)
                    : Math.round(GridMath.MIN_TOUCH_DP * metrics.density);
            tile.bind(catalog.icon(app, px), app.label);
            tile.setOnClickListener(v -> {
                Launch.app(AppsActivity.this, app);
                finish();
            });
            tile.setOnLongClickListener(v -> {
                TileMenu.show(AppsActivity.this, tile, app, AppsActivity.this::render);
                return true;
            });
            return tile;
        }
    }
}
