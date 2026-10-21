package app.headroom.home;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class AppOrderTest {
    private static App app(String pkg, String label) {
        return new App(pkg, "Main", label);
    }

    private static List<App> sorted(List<App> apps, Set<String> hidden, String selfPkg) {
        return AppOrder.sorted(apps, hidden, selfPkg);
    }

    @Test public void dropsHiddenAppsAndOurselves() {
        List<App> apps = Arrays.asList(
                app("a.alpha", "Alpha"),
                app("a.beta", "Beta"),
                app("me.self", "headroom home"));
        List<App> out = sorted(apps, new HashSet<>(Arrays.asList("a.beta")), "me.self");
        assertEquals(1, out.size());
        assertEquals("a.alpha", out.get(0).pkg);
    }

    @Test public void accentsDoNotSplitTheOrder() {
        List<App> apps = Arrays.asList(
                app("z.zz", "Zebra"),
                app("a.aa", "eclair"),
                app("b.bb", "\u00c9clair"));
        List<App> out = sorted(apps, new HashSet<String>(), "me.self");
        assertEquals("Zebra", out.get(2).label);
        assertEquals("eclair", out.get(0).label);
        assertEquals("\u00c9clair", out.get(1).label);
    }

    @Test public void tiesBreakOnTheKeySoTheOrderIsStable() {
        List<App> first = Arrays.asList(
                app("b.bb", "Maps"),
                app("a.aa", "Maps"));
        List<App> second = Arrays.asList(
                app("a.aa", "Maps"),
                app("b.bb", "Maps"));
        assertEquals("a.aa", sorted(first, new HashSet<String>(), "me.self").get(0).pkg);
        assertEquals("a.aa", sorted(second, new HashSet<String>(), "me.self").get(0).pkg);
    }

    @Test public void nullLabelSortsFirst() {
        List<App> apps = Arrays.asList(
                app("a.zz", "Zebra"),
                app("a.aa", null));
        List<App> out = sorted(apps, null, "me.self");
        assertEquals("a.aa", out.get(0).pkg);
    }

    @Test public void doesNotChangeTheInputList() {
        List<App> apps = Arrays.asList(
                app("b.bb", "Beta"),
                app("a.aa", "Alpha"));
        AppOrder.sorted(apps, new HashSet<String>(), "me.self");
        assertEquals("b.bb", apps.get(0).pkg);
    }
}
