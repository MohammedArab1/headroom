import json
import unittest
from pathlib import Path

from helpers import Run

INSTALLED = ["com.vendor.launcher", "com.vendor.ads", "app.headroom.home"]
VENDOR_HOME = "com.vendor.launcher/.Main"
HEADROOM_HOME = "app.headroom.home/.HomeActivity"
FALLBACK_HOME = "com.vendor.fallback/.Main"
BOOTS = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
]


class StockLauncherTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def new_run(
        self,
        home=HEADROOM_HOME,
        state=None,
        conf="ALLOW_RISKY=com.vendor.launcher\n",
        boots=None,
        launcher_installed=True,
        set_home_ignored=False,
    ):
        state = dict(state or {})
        state.setdefault("installed", INSTALLED)
        state.setdefault("home_claims", [VENDOR_HOME, HEADROOM_HOME])
        state["home"] = VENDOR_HOME  # preflight records the vendor as home-before
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        p = r("preflight.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)

        sd = self.state_dir(r)
        if launcher_installed:
            (sd / "launcher-installed").write_text("")
        if set_home_ignored:
            (sd / "set-home-ignored").write_text("")
        lines = BOOTS if boots is None else boots
        (sd / "launcher-soak.txt").write_text("\n".join(lines) + "\n")

        if home != VENDOR_HOME:
            current = r.state()
            current["home"] = home
            r.state_file.write_text(json.dumps(current))
        return r, sd

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_disable_after_soak(self):
        r, sd = self.new_run()
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("com.vendor.launcher", r.state()["disabled"])
        self.assertEqual(HEADROOM_HOME, r.state()["home"])
        batches = list((sd / "batches").glob("stock-launcher-*.tsv"))
        self.assertEqual(1, len(batches))
        self.assertIn("com.vendor.launcher\tenabled", batches[0].read_text())
        self.assertFalse(batches[0].with_suffix(".restored").exists())
        undo = list((Path(r.tmp.name) / "report").glob("manual-undo-*.txt"))
        self.assertEqual(1, len(undo))
        self.assertIn("com.vendor.launcher", undo[0].read_text())
        self.assertTrue(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))
        self.assertIn("verify.sh --manual", p.stderr)
        calls = self.shell_calls(r)
        disable_i = next(
            i
            for i, c in enumerate(calls)
            if c == "pm disable-user --user 0 com.vendor.launcher"
        )
        home_i = next(
            i
            for i, c in enumerate(calls)
            if c == f"cmd package set-home-activity --user 0 {HEADROOM_HOME}"
        )
        self.assertLess(disable_i, home_i)

    def test_disable_reports_a_vendor_re_enabled_at_boot(self):
        r, sd = self.new_run(state={"reenable_at_boot": ["com.vendor.launcher"]})
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("came back at boot", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])
        batch = next((sd / "batches").glob("stock-launcher-*.tsv"))
        self.assertTrue(batch.with_suffix(".restored").exists())

    def test_disable_refuses_without_the_soak(self):
        r, _ = self.new_run(boots=[BOOTS[0]])
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("needs 2", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])

    def test_disable_refuses_while_a_batch_is_unchecked(self):
        r, sd = self.new_run()
        (sd / "batches" / "old.tsv").write_text("com.vendor.ads\tenabled\n")
        (sd / "batches" / "order.txt").write_text("old\n")
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("has not passed the car checks", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])

    def test_disable_refuses_when_home_is_not_headroom(self):
        r, _ = self.new_run(home=VENDOR_HOME)
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("Run scripts/launcher.sh first", p.stderr)

    def test_disable_refuses_a_guarded_vendor(self):
        r, _ = self.new_run(conf="")
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("refusing to disable", p.stderr)
        self.assertIn("name matches", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])

    def test_disable_rolls_back_when_home_does_not_stay(self):
        r, sd = self.new_run(
            state={
                "ignore_set_home": True,
                "home_after_disable": FALLBACK_HOME,
            }
        )
        p = r("stock-launcher.sh", "--disable", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("HOME did not stay", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])
        batch = next((sd / "batches").glob("stock-launcher-*.tsv"))
        self.assertTrue(batch.with_suffix(".restored").exists())

    def test_handover_disables_the_vendor_and_keeps_headroom(self):
        r, sd = self.new_run(
            home=VENDOR_HOME,
            launcher_installed=False,
            set_home_ignored=True,
            state={"home_after_disable": HEADROOM_HOME},
        )
        p = r("stock-launcher.sh", "--handover", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("com.vendor.launcher", r.state()["disabled"])
        self.assertEqual(HEADROOM_HOME, r.state()["home"])
        self.assertTrue((sd / "launcher-installed").exists())
        self.assertFalse((sd / "set-home-ignored").exists())
        self.assertEqual(1, len(list((sd / "batches").glob("stock-launcher-*.tsv"))))

    def test_handover_rolls_back_immediately(self):
        r, sd = self.new_run(
            home=VENDOR_HOME,
            launcher_installed=False,
            set_home_ignored=True,
            state={"ignore_set_home": True},
        )
        p = r("stock-launcher.sh", "--handover", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("HOME did not stay", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])
        batch = next((sd / "batches").glob("stock-launcher-*.tsv"))
        self.assertTrue(batch.with_suffix(".restored").exists())

    def test_handover_requires_the_marker(self):
        r, _ = self.new_run(home=VENDOR_HOME, launcher_installed=False)
        p = r("stock-launcher.sh", "--handover", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("did not ignore set-home-activity", p.stderr)

    def test_enable_with_make_home(self):
        r, sd = self.new_run(
            state={"disabled": ["com.vendor.launcher"]},
        )
        (sd / "batches" / "stock-launcher-1.tsv").write_text(
            "com.vendor.launcher\tenabled\n"
        )
        (sd / "batches" / "order.txt").write_text("stock-launcher-1\n")
        p = r("stock-launcher.sh", "--enable", "--make-home", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])
        self.assertEqual(VENDOR_HOME, r.state()["home"])
        self.assertTrue((sd / "batches" / "stock-launcher-1.restored").exists())
        self.assertFalse((sd / "launcher-installed").exists())

    def test_enable_without_make_home_leaves_home_alone(self):
        r, _ = self.new_run(state={"disabled": ["com.vendor.launcher"]})
        p = r("stock-launcher.sh", "--enable", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])
        self.assertEqual(HEADROOM_HOME, r.state()["home"])

    def test_dry_run_changes_nothing(self):
        r, sd = self.new_run()
        p = r("stock-launcher.sh", "--disable", "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("dry-run: nothing changed", p.stderr)
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])
        self.assertEqual([], list((sd / "batches").glob("stock-launcher-*.tsv")))
        self.assertFalse(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))


if __name__ == "__main__":
    unittest.main()
