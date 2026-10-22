package app.headroom.home;

import static org.junit.Assert.assertEquals;

import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.Test;

public class DockModelTest {

    private static App app(String pkg) {
        return new App(pkg, "Main", pkg);
    }

    private static List<String> pkgs(List<App> apps) {
        return Arrays.asList(
            apps
                .stream()
                .map(a -> a.pkg)
                .toArray(String[]::new)
        );
    }

    @Test
    public void orderIsKept() {
        Map<String, App> installed = new HashMap<>();
        installed.put("a.one", app("a.one"));
        installed.put("a.two", app("a.two"));
        assertEquals(
            Arrays.asList("a.two", "a.one"),
            pkgs(
                DockModel.resolve(Arrays.asList("a.two", "a.one"), installed, 5)
            )
        );
    }

    @Test
    public void missingAppIsSkippedAndTheNextMovesUp() {
        Map<String, App> installed = new HashMap<>();
        installed.put("a.one", app("a.one"));
        installed.put("a.three", app("a.three"));
        assertEquals(
            Arrays.asList("a.one", "a.three"),
            pkgs(
                DockModel.resolve(
                    Arrays.asList("a.one", "a.two", "a.three"),
                    installed,
                    5
                )
            )
        );
    }

    @Test
    public void slotLimitHolds() {
        Map<String, App> installed = new HashMap<>();
        installed.put("a.one", app("a.one"));
        installed.put("a.two", app("a.two"));
        assertEquals(
            Arrays.asList("a.one"),
            pkgs(
                DockModel.resolve(Arrays.asList("a.one", "a.two"), installed, 1)
            )
        );
    }

    @Test
    public void hiddenAppIsSkippedAndTheNextMovesUp() {
        Map<String, App> installed = new HashMap<>();
        installed.put("a.one", app("a.one"));
        installed.put("a.two", app("a.two"));
        installed.put("a.three", app("a.three"));
        Set<String> hidden = new HashSet<>(Arrays.asList("a.two"));
        assertEquals(
            Arrays.asList("a.one", "a.three"),
            pkgs(
                DockModel.resolve(
                    Arrays.asList("a.one", "a.two", "a.three"),
                    installed,
                    5,
                    hidden
                )
            )
        );
    }

    @Test
    public void hiddenAppDoesNotConsumeASlot() {
        Map<String, App> installed = new HashMap<>();
        installed.put("a.one", app("a.one"));
        installed.put("a.two", app("a.two"));
        installed.put("a.three", app("a.three"));
        Set<String> hidden = new HashSet<>(Arrays.asList("a.two"));
        assertEquals(
            Arrays.asList("a.one", "a.three"),
            pkgs(
                DockModel.resolve(
                    Arrays.asList("a.one", "a.two", "a.three"),
                    installed,
                    2,
                    hidden
                )
            )
        );
    }

    @Test
    public void addRefusesDuplicates() {
        assertEquals(
            Arrays.asList("a.one", "a.two"),
            DockModel.add(Arrays.asList("a.one"), "a.two", 5)
        );
        assertEquals(
            Arrays.asList("a.one"),
            DockModel.add(Arrays.asList("a.one"), "a.one", 5)
        );
    }

    @Test
    public void addRefusesWhenFull() {
        assertEquals(
            Arrays.asList("a.one", "a.two"),
            DockModel.add(Arrays.asList("a.one", "a.two"), "a.three", 2)
        );
    }

    @Test
    public void removeDropsOneOccurrence() {
        assertEquals(
            Arrays.asList("a.two"),
            DockModel.remove(Arrays.asList("a.one", "a.two"), "a.one")
        );
        assertEquals(
            Arrays.asList("a.one"),
            DockModel.remove(Arrays.asList("a.one"), "a.two")
        );
    }

    @Test
    public void moveLeftAndRight() {
        List<String> dock = Arrays.asList("a.one", "a.two", "a.three");
        assertEquals(
            Arrays.asList("a.two", "a.one", "a.three"),
            DockModel.move(dock, "a.two", -1)
        );
        assertEquals(
            Arrays.asList("a.one", "a.three", "a.two"),
            DockModel.move(dock, "a.two", 1)
        );
    }

    @Test
    public void moveAtAnEndOrMissingIsUnchanged() {
        List<String> dock = Arrays.asList("a.one", "a.two", "a.three");
        assertEquals(dock, DockModel.move(dock, "a.one", -1));
        assertEquals(dock, DockModel.move(dock, "a.three", 1));
        assertEquals(dock, DockModel.move(dock, "a.gone", 1));
    }
}
