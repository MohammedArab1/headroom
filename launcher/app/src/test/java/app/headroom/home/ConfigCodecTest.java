package app.headroom.home;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.Arrays;
import java.util.List;

public class ConfigCodecTest {
    @Test public void parsesCommasSpacesAndTabs() {
        assertEquals(Arrays.asList("a.b", "c.d", "e.f"),
                ConfigCodec.parseList("a.b, c.d\t e.f"));
    }

    @Test public void dropsInvalidNamesButKeepsTheOrder() {
        assertEquals(Arrays.asList("a.b", "c.d"),
                ConfigCodec.parseList("a.b, not a package!, .., 1bad.x, c.d"));
    }

    @Test public void dropsDuplicates() {
        assertEquals(Arrays.asList("a.b"), ConfigCodec.parseList("a.b,a.b a.b"));
    }

    @Test public void acceptsUnderscoresAndDollarFreeNames() {
        assertEquals(Arrays.asList("com.vendor.my_app"), ConfigCodec.parseList("com.vendor.my_app"));
    }

    @Test public void nullAndEmptyInput() {
        assertTrue(ConfigCodec.parseList(null).isEmpty());
        assertTrue(ConfigCodec.parseList("").isEmpty());
        assertTrue(ConfigCodec.parseList(" , \t ").isEmpty());
    }

    @Test public void joinUsesCommas() {
        List<String> list = Arrays.asList("a.b", "c.d", "e.f");
        assertEquals("a.b,c.d,e.f", ConfigCodec.join(list));
        assertTrue(ConfigCodec.join(Arrays.asList()).isEmpty());
    }

    @Test public void clamp() {
        assertEquals(8, ConfigCodec.clamp(9, 3, 8));
        assertEquals(3, ConfigCodec.clamp(1, 3, 8));
        assertEquals(5, ConfigCodec.clamp(5, 3, 8));
    }
}
