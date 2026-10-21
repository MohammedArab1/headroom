package app.headroom.home;

/** One launchable activity. Plain Java so the logic classes can be tested on the JVM. */
public final class App {
    public final String pkg, activity, label;

    public App(String pkg, String activity, String label) {
        this.pkg = pkg;
        this.activity = activity;
        this.label = label;
    }

    public String key() {
        return pkg + "/" + activity;
    }
}
