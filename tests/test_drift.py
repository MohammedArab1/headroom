import json
import unittest
from pathlib import Path

from helpers import Run

INSTALLED = [
    "com.vendor.ads",
    "com.vendor.telemetry",
    "app.headroom.home",
    "com.android.systemui",
]
VENDOR_HOME = "com.vendor.launcher/.Main"
HEADROOM_HOME = "app.headroom.home/.HomeActivity"


class DriftTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def new_run(self, state=None, conf=""):
        state = dict(state or {})
        state.setdefault("installed", INSTALLED)
        props = {"ro.product.model": "Test Unit", "ro.build.display.id": "TEST.1"}
        props.update(state.pop("props", {}))
        state["props"] = props
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        p = r("preflight.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        return r, self.state_dir(r)

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def add_batch(self, sd, pkg, batch="t1", checked=True, restored=False):
        (sd / "batches" / f"{batch}.tsv").write_text(f"{pkg}\tenabled\n")
        order = sd / "batches" / "order.txt"
        order.write_text((order.read_text() if order.exists() else "") + batch + "\n")
        if checked:
            (sd / "batches" / f"{batch}.checked").write_text("")
        if restored:
            (sd / "batches" / f"{batch}.restored").write_text("")
        with (sd / "journal.tsv").open("a") as journal:
            journal.write(f"2026-01-01T00:00:00\t{batch}\t{pkg}\tdisabled\n")

    def set_state(self, r, **changes):
        state = r.state()
        state.update(changes)
        r.state_file.write_text(json.dumps(state))

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_reports_a_package_that_came_back(self):
        r, sd = self.new_run()
        self.add_batch(sd, "com.vendor.ads")
        p = r("drift.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("back on: com.vendor.ads", p.stdout)
        self.assertIn("scripts/drift.sh --fix", p.stdout)

    def test_a_package_still_disabled_is_not_drift(self):
        r, sd = self.new_run(state={"disabled": ["com.vendor.ads"]})
        self.add_batch(sd, "com.vendor.ads")
        p = r("drift.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("in sync", p.stdout)

    def test_a_restored_batch_is_not_drift(self):
        r, sd = self.new_run()
        self.add_batch(sd, "com.vendor.ads", restored=True)
        p = r("drift.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)

    def test_fix_creates_a_drift_batch(self):
        r, sd = self.new_run()
        self.add_batch(sd, "com.vendor.ads")
        p = r("drift.sh", "--fix", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("com.vendor.ads", r.state()["disabled"])
        batches = list((sd / "batches").glob("drift-*.tsv"))
        self.assertEqual(1, len(batches))
        self.assertIn("com.vendor.ads\tenabled", batches[0].read_text())
        self.assertIn("drift-", (sd / "journal.tsv").read_text())
        self.assertTrue(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))
        self.assertIn("verify.sh --manual", p.stderr)

    def test_a_never_list_package_is_not_fixed(self):
        r, sd = self.new_run()
        self.add_batch(sd, "com.android.systemui")
        p = r("drift.sh", "--fix", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("never-disable list", p.stderr)
        self.assertNotIn("com.android.systemui", r.state()["disabled"])
        self.assertEqual([], list((sd / "batches").glob("drift-*.tsv")))
        self.assertIn("stayed enabled", p.stderr)

    def test_build_change_is_reported(self):
        r, sd = self.new_run()
        state = r.state()
        state["props"]["ro.build.display.id"] = "TEST.2"
        r.state_file.write_text(json.dumps(state))
        p = r("drift.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("build changed: TEST.1 -> TEST.2", p.stdout)
        self.assertIn("discover.sh", p.stdout)

    def test_new_package_since_snapshot_is_reported(self):
        r, sd = self.new_run()
        state = r.state()
        state["installed"].append("com.vendor.preload")
        r.state_file.write_text(json.dumps(state))
        p = r("drift.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("new since snapshot: com.vendor.preload", p.stdout)

    def test_tweak_drift_is_reported_and_fixed(self):
        r, sd = self.new_run(
            state={"settings": {"global window_animation_scale": "1.0"}},
            conf="ANIM_SCALE=0.5\n",
        )
        (sd / "tweaks.tsv").write_text("setting\tglobal\twindow_animation_scale\t1.0\n")
        p = r("drift.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn("window_animation_scale", p.stdout)
        self.assertIn("want 0.5, got 1.0", p.stdout)

        p2 = r("drift.sh", "--fix", "-y")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertEqual("0.5", r.state()["settings"]["global window_animation_scale"])

    def test_home_drift_is_reported_and_fixed(self):
        r, sd = self.new_run(
            state={"home": VENDOR_HOME, "home_claims": [VENDOR_HOME, HEADROOM_HOME]}
        )
        (sd / "launcher-installed").write_text("")
        p = r("drift.sh")
        self.assertEqual(p.returncode, 1)
        self.assertIn(
            "HOME: expected app.headroom.home, found com.vendor.launcher", p.stdout
        )

        p2 = r("drift.sh", "--fix", "-y")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertEqual(HEADROOM_HOME, r.state()["home"])
        self.assertIn(
            f"cmd package set-home-activity --user 0 {HEADROOM_HOME}",
            self.shell_calls(r),
        )

    def test_fix_refuses_while_a_batch_is_unchecked(self):
        r, sd = self.new_run()
        self.add_batch(sd, "com.vendor.ads", checked=False)
        p = r("drift.sh", "--fix", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("has not passed the car checks", p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])

    def test_dry_run_changes_nothing(self):
        r, sd = self.new_run()
        self.add_batch(sd, "com.vendor.ads")
        p = r("drift.sh", "--fix", "--dry-run")
        self.assertEqual(p.returncode, 1)
        self.assertIn("dry-run: nothing changed", p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])
        self.assertEqual([], list((sd / "batches").glob("drift-*.tsv")))

    def test_private_dns_failure_reverts_both_values(self):
        r, sd = self.new_run(
            state={
                "ping": "ping: unknown host\n",
                "settings": {
                    "global private_dns_specifier": "old.example",
                    "global private_dns_mode": "off",
                },
            },
            conf="PRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n",
        )
        (sd / "tweaks.tsv").write_text(
            "setting\tglobal\tprivate_dns_specifier\told.example\n"
            "setting\tglobal\tprivate_dns_mode\toff\n"
        )
        p = r("drift.sh", "--fix", "-y")
        self.assertEqual(p.returncode, 1, msg=p.stdout + p.stderr)
        self.assertIn("reverting both settings immediately", p.stderr)
        settings = r.state()["settings"]
        self.assertEqual("old.example", settings["global private_dns_specifier"])
        self.assertEqual("off", settings["global private_dns_mode"])

    def test_unknown_flag_is_a_usage_error(self):
        r, _ = self.new_run()
        p = r("drift.sh", "--nope")
        self.assertEqual(p.returncode, 2)
        self.assertIn("unknown flag", p.stderr)


if __name__ == "__main__":
    unittest.main()
