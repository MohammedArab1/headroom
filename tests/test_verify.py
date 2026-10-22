import json
import unittest
from pathlib import Path

from helpers import Run

CHECK_IDS = [
    "reverse",
    "guides",
    "swc",
    "radio",
    "bt-pair",
    "bt-call",
    "bt-audio",
    "usb-media",
    "nav",
    "projection",
    "canbus",
    "dimming",
    "mic",
    "acc-sleep",
    "acc-wake",
    "clock",
    "keyboard",
]


def answers(overrides=None):
    overrides = overrides or {}
    return " ".join(f"{i}={overrides.get(i, 'y')}" for i in CHECK_IDS)


class VerifyTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def run_verify(self, *args, state=None, conf=""):
        state = dict(state or {})
        state.setdefault(
            "installed",
            [
                "com.android.systemui",
                "com.android.inputmethod.latin",
                "com.vendor.launcher",
                "com.vendor.ads",
                "com.example.app",
            ],
        )
        state.setdefault("third", ["com.example.app"])
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        p0 = r("preflight.sh")
        self.assertEqual(p0.returncode, 0, msg=p0.stdout + p0.stderr)
        return r, r("verify.sh", *args)

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def test_all_good_automatic_checks_pass(self):
        _, p = self.run_verify()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        for name in (
            "never",
            "batches",
            "keyboard",
            "home",
            "crashes",
            "tweaks",
            "dns",
            "adb",
        ):
            self.assertIn(name, p.stdout)
        self.assertNotIn("FAIL", p.stdout)

    def test_never_package_already_disabled_at_snapshot_is_ok(self):
        state = {"disabled": ["com.android.systemui"]}
        _, p = self.run_verify(state=state)
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("already off: com.android.systemui", p.stdout)
        self.assertNotIn("FAIL", p.stdout)

    def test_never_package_disabled_after_snapshot_fails(self):
        r = Run(
            state={
                "installed": [
                    "com.android.systemui",
                    "com.android.inputmethod.latin",
                    "com.vendor.launcher",
                    "com.vendor.ads",
                    "com.example.app",
                ],
                "third": ["com.example.app"],
            },
            profile="fixture-unit",
        )
        self.runs.append(r)
        p0 = r("preflight.sh")
        self.assertEqual(p0.returncode, 0, msg=p0.stdout + p0.stderr)
        state = r.state()
        state["disabled"].append("com.android.systemui")
        r.state_file.write_text(json.dumps(state))
        p = r("verify.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("never", p.stdout)
        self.assertIn("FAIL", p.stdout)
        self.assertIn("restore.sh --package", p.stdout)

    def test_sensitive_crash_fails(self):
        state = {"logcat_crash": "Process: com.android.systemui, PID: 1234\n"}
        _, p = self.run_verify(state=state)
        self.assertEqual(p.returncode, 1)
        self.assertIn("sensitive crash", p.stdout)

    def test_random_app_crash_is_only_a_warning(self):
        state = {"logcat_crash": "Process: com.example.app, PID: 1234\n"}
        _, p = self.run_verify(state=state)
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("crashes", p.stdout)
        self.assertIn("warn", p.stdout)
        self.assertNotIn("FAIL", p.stdout)

    def test_home_marker_mismatch_fails(self):
        r = Run(state={"installed": ["com.vendor.launcher"]}, profile="fixture-unit")
        self.runs.append(r)
        p0 = r("preflight.sh")
        self.assertEqual(p0.returncode, 0, msg=p0.stdout + p0.stderr)
        (self.state_dir(r) / "launcher-installed").write_text("")
        p = r("verify.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("HOME is", p.stdout)

    def test_manual_all_yes_marks_the_batch_checked(self):
        r = Run(
            state={
                "installed": [
                    "com.android.systemui",
                    "com.android.inputmethod.latin",
                    "com.vendor.launcher",
                    "com.vendor.ads",
                ],
                "disabled": ["com.vendor.ads"],
            },
            profile="fixture-unit",
        )
        self.runs.append(r)
        p0 = r("preflight.sh")
        self.assertEqual(p0.returncode, 0, msg=p0.stdout + p0.stderr)
        sd = self.state_dir(r)
        (sd / "batches" / "b1.tsv").write_text("com.vendor.ads\tenabled\n")
        (sd / "batches" / "order.txt").write_text("b1\n")
        (sd / "journal.tsv").write_text(
            "2026-01-01T00:00:00\tb1\tcom.vendor.ads\tdisabled\n"
        )
        p = r("verify.sh", "--manual", "--answers", answers())
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertTrue((sd / "batches" / "b1.checked").exists())
        checks = list((sd / "checks").glob("*.tsv"))
        self.assertEqual(len(checks), 1)
        self.assertIn("reverse\ty\tb1", checks[0].read_text())

    def test_manual_one_no_leaves_the_batch_unchecked(self):
        r = Run(
            state={
                "installed": [
                    "com.android.systemui",
                    "com.android.inputmethod.latin",
                    "com.vendor.launcher",
                    "com.vendor.ads",
                ],
                "disabled": ["com.vendor.ads"],
            },
            profile="fixture-unit",
        )
        self.runs.append(r)
        p0 = r("preflight.sh")
        self.assertEqual(p0.returncode, 0, msg=p0.stdout + p0.stderr)
        sd = self.state_dir(r)
        (sd / "batches" / "b1.tsv").write_text("com.vendor.ads\tenabled\n")
        (sd / "batches" / "order.txt").write_text("b1\n")
        (sd / "journal.tsv").write_text(
            "2026-01-01T00:00:00\tb1\tcom.vendor.ads\tdisabled\n"
        )
        p = r("verify.sh", "--manual", "--answers", answers({"reverse": "n"}))
        self.assertEqual(p.returncode, 1)
        self.assertFalse((sd / "batches" / "b1.checked").exists())
        checks = list((sd / "checks").glob("*.tsv"))
        self.assertEqual(len(checks), 1)
        self.assertIn("reverse\tn\tb1", checks[0].read_text())
        self.assertIn("restore.sh --last", p.stderr)

    def test_manual_without_tty_or_answers_stops(self):
        _, p = self.run_verify("--manual")
        self.assertEqual(p.returncode, 1)
        self.assertIn("a person at the car must answer", p.stderr)

    def test_automatic_failure_blocks_manual(self):
        state = {"logcat_crash": "Process: com.android.systemui, PID: 1234\n"}
        _, p = self.run_verify("--manual", "--answers", answers(), state=state)
        self.assertEqual(p.returncode, 1)
        self.assertIn("automatic checks failed", p.stderr)
        self.assertNotIn("reverse", p.stdout)

    def test_tweak_mismatch_is_a_warning(self):
        r, p = self.run_verify(conf="ANIM_SCALE=0.5\n")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        sd = self.state_dir(r)
        (sd / "tweaks.tsv").write_text("setting\tglobal\twindow_animation_scale\t1.0\n")
        p2 = r("verify.sh")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertIn("Re-run scripts/tune.sh", p2.stdout)

    def test_dns_failure_fails(self):
        state = {
            "settings": {
                "secure default_input_method": "com.android.inputmethod.latin/.LatinIME",
                "secure android_id": "abc",
                "global private_dns_mode": "hostname",
            },
            "ping": "ping: unknown host\n",
        }
        conf = "PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n"
        _, p = self.run_verify(state=state, conf=conf)
        self.assertEqual(p.returncode, 1)
        self.assertIn("dns", p.stdout)
        self.assertIn("resolver did not answer", p.stdout)

    def test_insecure_adb_is_a_warning(self):
        state = {"props": {"ro.adb.secure": "0"}}
        _, p = self.run_verify(state=state)
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("ro.adb.secure=0", p.stdout)


if __name__ == "__main__":
    unittest.main()
