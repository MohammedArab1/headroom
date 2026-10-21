package app.headroom.home;

import android.app.Activity;
import android.view.View;
import android.widget.PopupMenu;

import java.util.List;
import java.util.Set;

/** Long-press menu for one app. The caller redraws its screen through {@code afterChange}. */
final class TileMenu {
    private static final int ADD = 1;
    private static final int REMOVE = 2;
    private static final int LEFT = 3;
    private static final int RIGHT = 4;
    private static final int HIDE = 5;
    private static final int INFO = 6;

    private TileMenu() {}

    static void show(Activity activity, View anchor, App app, Runnable afterChange) {
        HomeConfig cfg = HomeConfig.get(activity);
        List<String> dock = cfg.dock();
        PopupMenu menu = new PopupMenu(activity, anchor);
        menu.getMenu().add(0, ADD, 0, R.string.add_to_dock);
        menu.getMenu().add(0, REMOVE, 1, R.string.remove_from_dock);
        menu.getMenu().add(0, LEFT, 2, R.string.move_left);
        menu.getMenu().add(0, RIGHT, 3, R.string.move_right);
        menu.getMenu().add(0, HIDE, 4, R.string.hide);
        menu.getMenu().add(0, INFO, 5, R.string.app_info);
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case ADD:
                    cfg.setDock(DockModel.add(dock, app.pkg, cfg.dockSlots()));
                    break;
                case REMOVE:
                    cfg.setDock(DockModel.remove(dock, app.pkg));
                    break;
                case LEFT:
                    cfg.setDock(DockModel.move(dock, app.pkg, -1));
                    break;
                case RIGHT:
                    cfg.setDock(DockModel.move(dock, app.pkg, 1));
                    break;
                case HIDE:
                    Set<String> hidden = cfg.hidden();
                    hidden.add(app.pkg);
                    cfg.setHidden(hidden);
                    break;
                case INFO:
                    Launch.appInfo(activity, app.pkg);
                    return true;
                default:
                    return false;
            }
            afterChange.run();
            return true;
        });
        menu.show();
    }
}
