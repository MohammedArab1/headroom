import unittest
from pathlib import Path

from helpers import Run

INSTALLED = [
    "com.vendor.ads",
    "com.vendor.music",
    "com.vendor.weather",
    "com.vendor.launcher",
]

# Everything off except what a test turns on: keeps each test about one tweak.
QUIET = "ANIM_SCALE=1\nSCAN_OFF=0\nDEXOPT=0\nTRIM_CACHES=0\nPRIVATE_DNS=0\n"


class TuneTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def new_run(self, state=None, conf="", preflight=True):
        state = dict(state or {})
        state.setdefault("installed", INSTALLED)
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        if preflight:
            p = r("preflight.sh")
            self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        return r

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def tweaks(self, r):
        f = self.state_dir(r) / "tweaks.tsv"
        return f.read_text() if f.exists() else ""

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_first_value_is_recorded_once_and_survives_a_second_run(self):
        old = {
            "global window_animation_scale": "1.0",
            "global transition_animation_scale": "1.0",
            "global animator_duration_scale": "1.0",
        }
        r = self.new_run(state={"settings": old}, conf=QUIET + "ANIM_SCALE=0.5\n")
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertEqual(r.state()["settings"]["global window_animation_scale"], "0.5")
        text = self.tweaks(r)
        for key in (
            "window_animation_scale",
            "transition_animation_scale",
            "animator_duration_scale",
        ):
            self.assertEqual(text.count(f"global\t{key}\t"), 1, msg=text)
            self.assertIn(f"setting\tglobal\t{key}\t1.0", text)

        # A later run must not overwrite the value recorded before the first change.
        r.conf.write_text(QUIET + "ANIM_SCALE=0\n")
        p2 = r("tune.sh", "-y")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertEqual(r.state()["settings"]["global window_animation_scale"], "0")
        text2 = self.tweaks(r)
        self.assertEqual(text2.count("global\twindow_animation_scale\t"), 1, msg=text2)
        self.assertIn("setting\tglobal\twindow_animation_scale\t1.0", text2)
        self.assertEqual(
            self.shell_calls(r).count("settings get global window_animation_scale"),
            1,
            msg="the original value should only be read before the first change",
        )

    def test_bg_restrict_records_the_old_mode(self):
        state = {"appops": {"com.vendor.music RUN_IN_BACKGROUND": "allow"}}
        r = self.new_run(state=state, conf=QUIET + "BG_RESTRICT=com.vendor.music\n")
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        calls = self.shell_calls(r)
        self.assertIn("cmd appops set com.vendor.music RUN_IN_BACKGROUND ignore", calls)
        self.assertIn(
            "cmd appops set com.vendor.music RUN_ANY_IN_BACKGROUND ignore", calls
        )
        text = self.tweaks(r)
        self.assertIn("appop\tcom.vendor.music\tRUN_IN_BACKGROUND\tallow", text)
        self.assertIn("appop\tcom.vendor.music\tRUN_ANY_IN_BACKGROUND\tdefault", text)

    def test_keep_apps_is_refused(self):
        r = self.new_run(
            conf=QUIET + "BG_RESTRICT=com.vendor.music\nKEEP_APPS=com.vendor.music\n"
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("is in KEEP_APPS; refusing", p.stderr)
        self.assertFalse(
            any("appops set com.vendor.music" in c for c in self.shell_calls(r))
        )
        self.assertNotIn("appop\tcom.vendor.music", self.tweaks(r))

    def test_dock_app_is_refused(self):
        r = self.new_run(
            conf=QUIET
            + "BG_RESTRICT=com.vendor.weather\nDOCK_APPS=com.vendor.weather\n"
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("is a dock app; refusing", p.stderr)
        self.assertFalse(
            any("appops set com.vendor.weather" in c for c in self.shell_calls(r))
        )

    def test_guarded_app_is_refused(self):
        # com.vendor.launcher answers HOME on the fake unit.
        r = self.new_run(conf=QUIET + "BG_RESTRICT=com.vendor.launcher\n")
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("is guarded; refusing", p.stderr)
        self.assertIn("owns HOME", p.stderr)
        self.assertFalse(
            any("appops set com.vendor.launcher" in c for c in self.shell_calls(r))
        )

    def test_absent_package_is_skipped(self):
        r = self.new_run(conf=QUIET + "BG_RESTRICT=com.vendor.gone\n")
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("is not installed; skipping", p.stderr)
        self.assertFalse(any("appops set" in c for c in self.shell_calls(r)))

    def test_private_dns_success_keeps_both_keys(self):
        old = {
            "global private_dns_specifier": "old.example",
            "global private_dns_mode": "off",
        }
        r = self.new_run(
            state={"settings": old},
            conf=QUIET + "PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n",
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("Private DNS resolver answers", p.stderr)
        self.assertIn("does not block YouTube ads", p.stderr)
        settings = r.state()["settings"]
        self.assertEqual(settings["global private_dns_specifier"], "dns.example.org")
        self.assertEqual(settings["global private_dns_mode"], "hostname")
        text = self.tweaks(r)
        self.assertIn("setting\tglobal\tprivate_dns_specifier\told.example", text)
        self.assertIn("setting\tglobal\tprivate_dns_mode\toff", text)

    def test_private_dns_failure_reverts_both_keys(self):
        old = {
            "global private_dns_specifier": "old.example",
            "global private_dns_mode": "off",
        }
        r = self.new_run(
            state={"settings": old, "ping": "ping: unknown host\n"},
            conf=QUIET + "PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n",
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("reverting both settings immediately", p.stderr)
        settings = r.state()["settings"]
        self.assertEqual(settings["global private_dns_specifier"], "old.example")
        self.assertEqual(settings["global private_dns_mode"], "off")
        self.assertIn(
            "settings put global private_dns_specifier old.example",
            self.shell_calls(r),
        )

    def test_private_dns_failure_deletes_values_that_were_unset(self):
        r = self.new_run(
            state={"ping": "ping: unknown host\n"},
            conf=QUIET + "PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n",
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        settings = r.state()["settings"]
        self.assertNotIn("global private_dns_specifier", settings)
        self.assertNotIn("global private_dns_mode", settings)
        calls = self.shell_calls(r)
        self.assertIn("settings delete global private_dns_specifier", calls)
        self.assertIn("settings delete global private_dns_mode", calls)
        text = self.tweaks(r)
        self.assertIn("setting\tglobal\tprivate_dns_specifier\tnull", text)

    def test_private_dns_needs_api_28(self):
        r = self.new_run(
            state={"props": {"ro.build.version.sdk": "27"}},
            conf=QUIET + "PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n",
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("Private DNS needs API 28 or later", p.stderr)
        self.assertFalse(
            any("settings put global private_dns" in c for c in self.shell_calls(r))
        )

    def test_dry_run_changes_nothing(self):
        r = self.new_run(
            conf=(
                "ANIM_SCALE=0.5\nSCAN_OFF=1\nDEXOPT=1\nTRIM_CACHES=1\n"
                "PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n"
                "BG_RESTRICT=com.vendor.music\n"
            )
        )
        p = r("tune.sh", "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("dry-run: nothing changed", p.stderr)
        for c in self.shell_calls(r):
            for change in (
                "settings put ",
                "cmd appops set ",
                "pm trim-caches",
                "cmd package bg-dexopt-job",
                "cmd package compile",
            ):
                self.assertNotIn(change, c)
        self.assertFalse((self.state_dir(r) / "tweaks.tsv").exists())

    def test_cache_trim_only_when_data_is_over_85_percent(self):
        full = (
            "Filesystem      1K-blocks     Used Available Use% Mounted on\n"
            "/dev/block/dm-0  26214400 23592960   2621440  90% /data\n"
        )
        r = self.new_run(state={"df_data": full}, conf=QUIET + "TRIM_CACHES=1\n")
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("cache trimmed", p.stderr)
        self.assertIn("pm trim-caches 999G", self.shell_calls(r))

        r2 = self.new_run(conf=QUIET + "TRIM_CACHES=1\n")
        p2 = r2("tune.sh", "-y")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertIn("storage is below 85%", p2.stderr)
        self.assertNotIn("pm trim-caches 999G", self.shell_calls(r2))

    def test_dexopt_and_launcher_compile(self):
        state = {"installed": INSTALLED + ["app.headroom.home"]}
        r = self.new_run(state=state, conf=QUIET + "DEXOPT=1\n")
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("this takes 5 to 30 minutes", p.stderr)
        calls = self.shell_calls(r)
        self.assertIn("cmd package bg-dexopt-job", calls)
        self.assertIn("cmd package compile -m speed -f app.headroom.home", calls)

    def test_launcher_is_not_compiled_when_absent(self):
        r = self.new_run(conf=QUIET)
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("nothing to do", p.stderr)
        self.assertFalse(any("cmd package compile" in c for c in self.shell_calls(r)))

    def test_needs_a_snapshot(self):
        r = self.new_run(conf=QUIET + "ANIM_SCALE=0.5\n", preflight=False)
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no snapshot", p.stderr)
        self.assertFalse(any("settings put" in c for c in self.shell_calls(r)))

    def test_needs_a_yes_without_a_tty(self):
        r = self.new_run(conf=QUIET + "ANIM_SCALE=0.5\n")
        p = r("tune.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("needs a yes from a person", p.stderr)
        self.assertFalse(any("settings put" in c for c in self.shell_calls(r)))

    def test_restore_puts_every_tweak_back(self):
        old = {
            "global window_animation_scale": "1.0",
            "global transition_animation_scale": "1.0",
            "global animator_duration_scale": "1.0",
        }
        state = {
            "settings": old,
            "appops": {"com.vendor.music RUN_IN_BACKGROUND": "allow"},
        }
        r = self.new_run(
            state=state, conf=QUIET + "ANIM_SCALE=0.5\nBG_RESTRICT=com.vendor.music\n"
        )
        p = r("tune.sh", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)

        p2 = r("restore.sh", "--all", "--from-snapshot", "-y")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        settings = r.state()["settings"]
        for key, value in old.items():
            self.assertEqual(settings[key], value, msg=key)
        appops = r.state()["appops"]
        self.assertEqual(appops["com.vendor.music RUN_IN_BACKGROUND"], "allow")
        self.assertEqual(appops["com.vendor.music RUN_ANY_IN_BACKGROUND"], "default")


if __name__ == "__main__":
    unittest.main()
