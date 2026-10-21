package app.headroom.home;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Display and dock settings. Every row is at least 76 dp tall so it works with a rotary knob. */
public final class OptionsActivity extends Activity {
    private HomeConfig cfg;
    private AppCatalog catalog;
    private TextView slotsRow;
    private TextView clockRow;
    private TextView columnsRow;
    private TextView hiddenRow;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        cfg = HomeConfig.get(this);
        catalog = AppCatalog.get(this);

        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(0, dp(16), 0, dp(32));

        slotsRow = row(getString(R.string.dock_slots), v -> {
            cfg.setDockSlots(cfg.dockSlots() >= 6 ? 3 : cfg.dockSlots() + 1);
            update();
        });
        clockRow = row(getString(R.string.clock_setting), v -> {
            cfg.setClock(nextClock());
            update();
        });
        columnsRow = row(getString(R.string.grid_columns), v -> {
            int current = cfg.columnsOverride();
            cfg.setColumnsOverride(current < 3 ? 3 : current >= 8 ? 0 : current + 1);
            update();
        });
        hiddenRow = row(getString(R.string.hidden_apps), v -> showHidden());

        list.addView(slotsRow);
        list.addView(clockRow);
        list.addView(columnsRow);
        list.addView(hiddenRow);
        list.addView(row(getString(R.string.previous_home), v -> showPreviousHome()));
        list.addView(row(getString(R.string.reset), v -> confirmReset()));
        list.addView(row(getString(R.string.about) + ": " + getString(R.string.about_text), null));

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(getResources().getColor(R.color.bg, getTheme()));
        scroll.addView(list);
        setContentView(scroll);
        update();
    }

    /** Only the text changes, so focus stays on the row a person just used. */
    private void update() {
        slotsRow.setText(getString(R.string.dock_slots) + ": " + cfg.dockSlots());
        clockRow.setText(getString(R.string.clock_setting) + ": " + clockLabel());
        columnsRow.setText(getString(R.string.grid_columns) + ": " + columnsLabel());
        hiddenRow.setText(getString(R.string.hidden_apps) + " (" + cfg.hidden().size() + ")");
    }

    private String nextClock() {
        String now = cfg.clock();
        if ("auto".equals(now)) return "12";
        if ("12".equals(now)) return "24";
        return "auto";
    }

    private String clockLabel() {
        String now = cfg.clock();
        if ("12".equals(now)) return getString(R.string.clock_12);
        if ("24".equals(now)) return getString(R.string.clock_24);
        return getString(R.string.clock_auto);
    }

    private String columnsLabel() {
        int columns = cfg.columnsOverride();
        return columns < 3 ? getString(R.string.columns_auto) : String.valueOf(columns);
    }

    private void showHidden() {
        final List<App> apps = AppOrder.sorted(catalog.all(), Collections.<String>emptySet(),
                getPackageName());
        if (apps.isEmpty()) return;
        final CharSequence[] labels = new CharSequence[apps.size()];
        final boolean[] checked = new boolean[apps.size()];
        Set<String> hidden = cfg.hidden();
        for (int i = 0; i < apps.size(); i++) {
            App app = apps.get(i);
            labels[i] = app.label + "  " + app.pkg;
            checked[i] = hidden.contains(app.pkg);
        }
        new AlertDialog.Builder(this)
                .setTitle(R.string.hidden_apps)
                .setMultiChoiceItems(labels, checked,
                        (dialog, which, isChecked) -> checked[which] = isChecked)
                .setPositiveButton(R.string.ok, (dialog, which) -> {
                    Set<String> out = new LinkedHashSet<>();
                    for (int i = 0; i < apps.size(); i++) {
                        if (checked[i]) out.add(apps.get(i).pkg);
                    }
                    cfg.setHidden(out);
                    update();
                })
                .setNegativeButton(R.string.cancel, null)
                .show();
    }

    private void showPreviousHome() {
        PackageManager pm = getPackageManager();
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        final List<ResolveInfo> found = new ArrayList<>();
        for (ResolveInfo info : pm.queryIntentActivities(home, 0)) {
            if (!getPackageName().equals(info.activityInfo.packageName)) found.add(info);
        }
        if (found.isEmpty()) {
            Toast.makeText(this, R.string.no_other_home, Toast.LENGTH_SHORT).show();
            return;
        }
        CharSequence[] labels = new CharSequence[found.size()];
        for (int i = 0; i < found.size(); i++) labels[i] = found.get(i).loadLabel(pm);
        new AlertDialog.Builder(this)
                .setTitle(R.string.previous_home)
                .setItems(labels, (dialog, which) -> {
                    ResolveInfo info = found.get(which);
                    Launch.component(this, new ComponentName(info.activityInfo.packageName,
                            info.activityInfo.name));
                })
                .show();
    }

    private void confirmReset() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.reset)
                .setMessage(R.string.reset_question)
                .setPositiveButton(R.string.ok, (dialog, which) -> {
                    cfg.reset();
                    update();
                })
                .setNegativeButton(R.string.cancel, null)
                .show();
    }

    private TextView row(String text, View.OnClickListener listener) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(20);
        view.setTextColor(getResources().getColor(R.color.text, getTheme()));
        view.setGravity(Gravity.CENTER_VERTICAL);
        view.setPadding(dp(24), 0, dp(24), 0);
        view.setMinHeight(dp(GridMath.MIN_TOUCH_DP));
        view.setBackgroundResource(android.R.drawable.list_selector_background);
        if (listener != null) {
            view.setClickable(true);
            view.setFocusable(true);
            view.setOnClickListener(listener);
        }
        return view;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
