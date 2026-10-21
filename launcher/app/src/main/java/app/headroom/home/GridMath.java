package app.headroom.home;

/** Tile sizes from the screen. Pure arithmetic. */
public final class GridMath {
    /** Android for Cars minimum touch target. */
    public static final int MIN_TOUCH_DP = 76;

    private GridMath() {}

    /** Grid columns: as many tiles of at least minTileDp as fit, between 3 and 8, unless overridden (3..8). */
    public static int columns(int widthPx, float density, int minTileDp, int gapDp, int override) {
        if (override >= 3 && override <= 8) return override;
        int widthDp = Math.round(widthPx / density);
        return ConfigCodec.clamp((widthDp + gapDp) / (minTileDp + gapDp), 3, 8);
    }

    /** How many dock tiles of at least minDp fit on one row, between 1 and count. */
    public static int perRow(int widthPx, float density, int count, int minDp, int gapDp, int paddingDp) {
        int usableDp = Math.round(widthPx / density) - 2 * paddingDp;
        return ConfigCodec.clamp((usableDp + gapDp) / (minDp + gapDp), 1, Math.max(1, count));
    }

    /** Edge of one tile in px, so {@code count} tiles plus gaps fill the width minus padding; never below 76 dp. */
    public static int tilePx(int widthPx, float density, int count, int gapDp, int paddingDp) {
        int usable = widthPx
                - Math.round(2 * paddingDp * density)
                - Math.round((count - 1) * gapDp * density);
        return Math.max(Math.round(MIN_TOUCH_DP * density), usable / Math.max(1, count));
    }
}
