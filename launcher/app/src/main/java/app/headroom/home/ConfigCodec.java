package app.headroom.home;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.regex.Pattern;

/** Parsing for the dock and hidden lists. Invalid names are dropped: they come from a file a person edits. */
public final class ConfigCodec {
    static final Pattern PKG = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+");

    private ConfigCodec() {}

    /** "a.b, c.d  e.f" -> [a.b, c.d, e.f]; invalid names and duplicates dropped, order kept. */
    public static List<String> parseList(String raw) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (raw != null) {
            for (String part : raw.split("[,\\s]+")) {
                if (PKG.matcher(part).matches()) out.add(part);
            }
        }
        return new ArrayList<>(out);
    }

    public static String join(List<String> items) {
        StringBuilder sb = new StringBuilder();
        for (String s : items) {
            if (sb.length() > 0) sb.append(',');
            sb.append(s);
        }
        return sb.toString();
    }

    public static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }
}
