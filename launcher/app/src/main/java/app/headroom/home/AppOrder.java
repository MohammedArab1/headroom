package app.headroom.home;

import java.text.Collator;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/** Sorted app grid: hidden apps and ourselves are dropped, then labels are compared the way a person reads them. */
public final class AppOrder {
    private AppOrder() {}

    public static List<App> sorted(List<App> apps, Set<String> hidden, String selfPkg) {
        List<App> out = new ArrayList<>();
        for (App a : apps) {
            if (a == null) continue;
            if (a.pkg.equals(selfPkg)) continue;
            if (hidden != null && hidden.contains(a.pkg)) continue;
            out.add(a);
        }
        final Collator collator = Collator.getInstance();
        collator.setStrength(Collator.PRIMARY); // case and accents do not split the order
        out.sort((x, y) -> {
            int byLabel = collator.compare(x.label == null ? "" : x.label,
                    y.label == null ? "" : y.label);
            return byLabel != 0 ? byLabel : x.key().compareTo(y.key());
        });
        return out;
    }
}
