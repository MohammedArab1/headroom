package app.headroom.home;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.Arrays;
import java.util.List;

public class GridMathTest {
    @Test public void sevenColumnsOn1024x600() { assertEquals(7, GridMath.columns(1024, 1.0f, 120, 16, 0)); }
    @Test public void sixColumnsOn1280x720hdpi() { assertEquals(6, GridMath.columns(1280, 1.5f, 120, 16, 0)); }
    @Test public void clampedToEight() { assertEquals(8, GridMath.columns(2000, 1.0f, 120, 16, 0)); }
    @Test public void overrideWins() { assertEquals(5, GridMath.columns(1024, 1.0f, 120, 16, 5)); }
    @Test public void badOverrideIgnored() { assertEquals(7, GridMath.columns(1024, 1.0f, 120, 16, 2)); }

    @Test public void dockTileFills() { assertEquals(123, GridMath.tilePx(1024, 1.0f, 7, 16, 32)); }
    @Test public void neverBelowTouchMinimum() { assertEquals(152, GridMath.tilePx(400, 2.0f, 7, 16, 32)); }

    @Test public void dockFitsOneRowOn1024() { assertEquals(7, GridMath.perRow(1024, 1.0f, 7, 88, 16, 40)); }
    @Test public void dockWrapsOnPortrait() { assertEquals(2, GridMath.perRow(720, 2.0f, 7, 88, 16, 40)); }

    @Test public void perRowNeverExceedsTheTileCount() {
        assertEquals(3, GridMath.perRow(2000, 1.0f, 3, 88, 16, 40));
    }

    @Test public void perRowIsAtLeastOne() {
        assertEquals(1, GridMath.perRow(200, 2.0f, 6, 88, 16, 40));
    }

    @Test public void tileSizeIsAnIntegerAndNeverZero() {
        List<Integer> sizes = Arrays.asList(
                GridMath.tilePx(1, 1.0f, 8, 16, 32),
                GridMath.tilePx(1024, 1.0f, 1, 16, 32),
                GridMath.tilePx(1920, 2.0f, 6, 16, 32));
        for (int px : sizes) assertTrue(px > 0);
    }
}
