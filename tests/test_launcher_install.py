import unittest
from pathlib import Path

from helpers import ROOT, Run

APK = ROOT / "tests/fixtures/empty.apk"
INSTALLED = ["com.vendor.launcher", "com.vendor.ads"]
VENDOR_HOME = "com.vendor.launcher/.Main"
HEADROOM_HOME = "app.headroom.home/.HomeActivity"


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def new_run(self, state=None):
        state = dict(state or {})
        state.setdefault("installed", INSTALLED)
        r = Run(state=state, profile="fixture-unit")
        self.runs.append(r)
        p = r("preflight.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        return r

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_install_makes_headroom_home(self):
        r = self.new_run()
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        state = r.state()
        self.assertEqual(HEADROOM_HOME, state["home"])
        self.assertIn("app.headroom.home", state["installed"])
        self.assertEqual(["/data/local/tmp/headroom-home.apk"], state["pushed"])
        calls = self.shell_calls(r)
        self.assertIn("pm install -r /data/local/tmp/headroom-home.apk", calls)
        self.assertIn(f"am start -W -n {HEADROOM_HOME}", calls)
        self.assertIn(f"cmd package set-home-activity --user 0 {HEADROOM_HOME}", calls)
        self.assertIn("cmd package compile -m speed -f app.headroom.home", calls)
        self.assertIn("input keyevent KEYCODE_HOME", calls)
        sd = self.state_dir(r)
        self.assertTrue((sd / "launcher-installed").exists())
        self.assertFalse((sd / "set-home-ignored").exists())
        self.assertEqual(VENDOR_HOME, (sd / "home-before.txt").read_text().strip())
        self.assertIn(f"foreground: {HEADROOM_HOME}", p.stderr)
        self.assertIn("reboot test and ignition test", p.stderr)

    def test_ignored_set_home_rolls_back_and_writes_recovery(self):
        r = self.new_run(state={"ignore_set_home": True})
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("ignores set-home-activity", p.stderr)
        self.assertEqual(VENDOR_HOME, r.state()["home"])
        sd = self.state_dir(r)
        self.assertTrue((sd / "set-home-ignored").exists())
        self.assertFalse((sd / "launcher-installed").exists())
        rollback = Path(r.tmp.name) / "report" / "launcher-rollback.txt"
        self.assertTrue(rollback.exists())
        text = rollback.read_text()
        self.assertIn(VENDOR_HOME, text)
        self.assertIn("set-home-activity", text)

    def test_failed_start_leaves_home_alone(self):
        r = self.new_run(
            state={
                "am_start_reply": {
                    HEADROOM_HOME: "Error: Activity not started, unable to resolve Intent"
                }
            }
        )
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("HOME was not changed", p.stderr)
        self.assertEqual(VENDOR_HOME, r.state()["home"])
        self.assertFalse(any("set-home-activity" in c for c in self.shell_calls(r)))
        self.assertFalse((self.state_dir(r) / "launcher-installed").exists())

    def test_install_failure_update_incompatible(self):
        r = self.new_run(
            state={"install_reply": "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"}
        )
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("built with another key", p.stderr)
        self.assertEqual(VENDOR_HOME, r.state()["home"])

    def test_install_failure_verification(self):
        r = self.new_run(
            state={"install_reply": "Failure [INSTALL_FAILED_VERIFICATION_FAILURE]"}
        )
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("refuses sideloaded apps", p.stderr)

    def test_unchecked_batch_blocks_the_install(self):
        r = self.new_run()
        sd = self.state_dir(r)
        (sd / "batches" / "old.tsv").write_text("com.vendor.ads\tenabled\n")
        (sd / "batches" / "order.txt").write_text("old\n")
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("has not passed the car checks", p.stderr)
        self.assertEqual([], r.state().get("pushed", []))
        self.assertEqual(VENDOR_HOME, r.state()["home"])

    def test_dry_run_changes_nothing(self):
        r = self.new_run()
        p = r("launcher/install.sh", "--apk", str(APK), "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("dry-run: nothing changed", p.stderr)
        self.assertEqual(VENDOR_HOME, r.state()["home"])
        self.assertEqual([], r.state().get("pushed", []))
        self.assertFalse(any("pm install" in c for c in self.shell_calls(r)))
        self.assertFalse((self.state_dir(r) / "launcher-installed").exists())

    def test_undo_restores_the_previous_home(self):
        r = self.new_run()
        p = r("launcher/install.sh", "--apk", str(APK), "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)

        p2 = r("scripts/launcher.sh", "--undo")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertEqual(VENDOR_HOME, r.state()["home"])
        self.assertIn("app.headroom.home", r.state()["installed"])
        self.assertFalse((self.state_dir(r) / "launcher-installed").exists())
        self.assertIn("stays installed", p2.stderr)

    def test_undo_refuses_when_home_was_the_chooser(self):
        r = self.new_run(
            state={"home": "android/com.android.internal.app.ChooserActivity"}
        )
        p = r("launcher/install.sh", "--undo")
        self.assertEqual(p.returncode, 1)
        self.assertIn("system chooser", p.stderr)


if __name__ == "__main__":
    unittest.main()
