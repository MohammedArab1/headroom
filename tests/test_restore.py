import json
import unittest
from pathlib import Path

from helpers import Run

INSTALLED = [
    "com.vendor.ads",
    "com.vendor.telemetry",
    "com.vendor.promo",
    "com.vendor.keep",
    "com.vendor.launcher",
]


class RestoreTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def new_run(self, state=None, conf=""):
        state = dict(state or {})
        state.setdefault("installed", INSTALLED)
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        p = r("preflight.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        return r

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def write_plan(self, r, batch, lines, order=None):
        sd = self.state_dir(r)
        (sd / "batches" / f"{batch}.tsv").write_text("\n".join(lines) + "\n")
        (sd / "batches" / "order.txt").write_text((order or batch) + "\n")
        return sd

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_all_restores_batch_tweaks_and_home(self):
        r = self.new_run(
            state={
                "disabled": [
                    "com.vendor.ads",
                    "com.vendor.telemetry",
                    "com.vendor.promo",
                ]
            }
        )
        sd = self.write_plan(
            r,
            "b1",
            [
                "com.vendor.ads\tenabled",
                "com.vendor.telemetry\tenabled",
                "com.vendor.promo\tdisabled",
            ],
        )
        (sd / "tweaks.tsv").write_text(
            "setting\tglobal\twindow_animation_scale\t1.0\n"
            "setting\tglobal\tprivate_dns_mode\tnull\n"
            "appop\tcom.vendor.ads\tRUN_ANY_IN_BACKGROUND\tdefault\n"
        )
        (sd / "launcher-installed").write_text("")
        p = r("restore.sh", "--all", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        state = r.state()
        self.assertNotIn("com.vendor.ads", state["disabled"])
        self.assertNotIn("com.vendor.telemetry", state["disabled"])
        self.assertIn("com.vendor.promo", state["disabled"])
        self.assertTrue((sd / "batches" / "b1.restored").exists())
        self.assertFalse((sd / "launcher-installed").exists())
        self.assertEqual(state["settings"]["global window_animation_scale"], "1.0")
        self.assertNotIn("global private_dns_mode", state["settings"])
        self.assertEqual(
            state["appops"]["com.vendor.ads RUN_ANY_IN_BACKGROUND"], "default"
        )
        self.assertTrue(
            any(
                "cmd package set-home-activity --user 0 com.vendor.launcher/.Main" in c
                for c in self.shell_calls(r)
            )
        )
        self.assertTrue(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))
        self.assertIn("left disabled (as it was)", p.stdout)

        calls = self.shell_calls(r)
        delete_i = next(
            i
            for i, c in enumerate(calls)
            if "settings delete global private_dns_mode" in c
        )
        put_i = next(
            i
            for i, c in enumerate(calls)
            if "settings put global window_animation_scale 1.0" in c
        )
        self.assertLess(delete_i, put_i)

    def test_last_touches_only_newest_batch(self):
        r = self.new_run(state={"disabled": ["com.vendor.ads", "com.vendor.telemetry"]})
        sd = self.write_plan(r, "b1", ["com.vendor.ads\tenabled"], order="b1\nb2")
        (sd / "batches" / "b2.tsv").write_text("com.vendor.telemetry\tenabled\n")
        p = r("restore.sh", "--last", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("com.vendor.telemetry", r.state()["disabled"])
        self.assertIn("com.vendor.ads", r.state()["disabled"])
        self.assertTrue((sd / "batches" / "b2.restored").exists())
        self.assertFalse((sd / "batches" / "b1.restored").exists())
        self.assertTrue(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))
        self.assertFalse(any("settings put" in c for c in self.shell_calls(r)))

    def test_suspect_enable_leaves_batch_open(self):
        r = self.new_run(
            state={
                "disabled": ["com.vendor.ads"],
                "enable_reply": {"com.vendor.ads": "odd output"},
            }
        )
        sd = self.write_plan(r, "b1", ["com.vendor.ads\tenabled"])
        p = r("restore.sh", "--batch", "b1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("did not come back", p.stderr)
        self.assertFalse((sd / "batches" / "b1.restored").exists())
        self.assertIn("com.vendor.ads", r.state()["disabled"])

    def test_package_refuses_unknown(self):
        r = self.new_run(state={"disabled": ["com.vendor.ads"]})
        p = r("restore.sh", "--package", "com.vendor.telemetry")
        self.assertEqual(p.returncode, 1)
        self.assertIn("headroom never disabled", p.stderr)
        self.assertIn("com.vendor.ads", r.state()["disabled"])

    def test_package_enables_only_that_package(self):
        r = self.new_run(state={"disabled": ["com.vendor.ads", "com.vendor.telemetry"]})
        sd = self.write_plan(
            r, "b1", ["com.vendor.ads\tenabled", "com.vendor.telemetry\tenabled"]
        )
        p = r("restore.sh", "--package", "com.vendor.ads")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])
        self.assertIn("com.vendor.telemetry", r.state()["disabled"])
        self.assertFalse((sd / "batches" / "b1.restored").exists())

    def test_before_disabled_is_left_alone(self):
        r = self.new_run(state={"disabled": ["com.vendor.promo"]})
        sd = self.write_plan(r, "b1", ["com.vendor.promo\tdisabled"])
        p = r("restore.sh", "--batch", "b1")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("com.vendor.promo", r.state()["disabled"])
        self.assertTrue((sd / "batches" / "b1.restored").exists())

    def test_from_snapshot_enables_only_new_disables(self):
        r = self.new_run(state={"disabled": ["com.vendor.keep"]})
        sd = self.state_dir(r)
        state = json.loads(r.state_file.read_text())
        state["disabled"].append("com.vendor.ads")
        r.state_file.write_text(json.dumps(state))
        p = r("restore.sh", "--all", "--from-snapshot", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])
        self.assertIn("com.vendor.keep", r.state()["disabled"])
        self.assertIn("packages disabled after the snapshot", p.stderr)

    def test_no_records_needs_from_snapshot(self):
        r = self.new_run()
        p = r("restore.sh", "--all", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no batch records", p.stderr)
        self.assertIn("--from-snapshot", p.stderr)

    def test_dry_run_changes_nothing(self):
        r = self.new_run(state={"disabled": ["com.vendor.ads"]})
        sd = self.write_plan(r, "b1", ["com.vendor.ads\tenabled"])
        (sd / "tweaks.tsv").write_text("setting\tglobal\twindow_animation_scale\t1.0\n")
        p = r("restore.sh", "--all", "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("dry-run", p.stderr)
        self.assertIn("com.vendor.ads", r.state()["disabled"])
        self.assertFalse((sd / "batches" / "b1.restored").exists())
        for cmd in self.shell_calls(r):
            self.assertNotIn("pm enable", cmd)
            self.assertNotIn("settings put", cmd)
            self.assertNotIn("set-home-activity", cmd)
        self.assertFalse(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))

    def test_no_tweaks_no_home(self):
        r = self.new_run(state={"disabled": ["com.vendor.ads"]})
        sd = self.write_plan(r, "b1", ["com.vendor.ads\tenabled"])
        (sd / "tweaks.tsv").write_text("setting\tglobal\twindow_animation_scale\t1.0\n")
        p = r("restore.sh", "--all", "-y", "--no-tweaks", "--no-home")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])
        self.assertFalse(any("settings put" in c for c in self.shell_calls(r)))
        self.assertFalse(any("set-home-activity" in c for c in self.shell_calls(r)))
        self.assertTrue((sd / "batches" / "b1.restored").exists())


if __name__ == "__main__":
    unittest.main()
