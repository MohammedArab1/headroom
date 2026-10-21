package app.headroom.home;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** The dock: the configured packages that are installed, in order, at most {@code slots}. */
public final class DockModel {
    private DockModel() {}

    public static List<App> resolve(List<String> wanted, Map<String, App> installedByPkg, int slots) {
        List<App> out = new ArrayList<>();
        for (String pkg : wanted) {
            if (out.size() >= slots) break;
            App a = installedByPkg.get(pkg);
            if (a != null) out.add(a); // uninstalled or disabled apps simply drop out
        }
        return out;
    }

    public static List<String> add(List<String> wanted, String pkg, int max) {
        List<String> out = new ArrayList<>(wanted);
        if (!out.contains(pkg) && out.size() < max) out.add(pkg);
        return out;
    }

    public static List<String> remove(List<String> wanted, String pkg) {
        List<String> out = new ArrayList<>(wanted);
        out.remove(pkg);
        return out;
    }

    /** Moves pkg one place (delta -1 or +1). Unchanged at either end or when pkg is absent. */
    public static List<String> move(List<String> wanted, String pkg, int delta) {
        List<String> out = new ArrayList<>(wanted);
        int i = out.indexOf(pkg), j = i + delta;
        if (i < 0 || j < 0 || j >= out.size()) return out;
        out.set(i, out.get(j));
        out.set(j, pkg);
        return out;
    }
}
