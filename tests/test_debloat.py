import shutil
import tempfile
import unittest
from pathlib import Path

from helpers import ROOT, Run

FIXTURE_PACKAGES = [
    "com.vendor.ads",
    "com.vendor.telemetry",
    "com.vendor.promo",
    "com.android.printspooler",
    "com.android.dreams.basic",
    "com.vendor.updater",
    "com.vendor.games",
    "com.vendor.music",
    "com.vendor.email",
    "com.vendor.weather",
]

GUARD_PACKAGES = ["com.vendor.launcher", "com.vendor.persistent", "com.vendor.weird"]


class DebloatTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def temp_data(self, packages, profile="fixture-never"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        data = Path(tmp.name) / "data"
        shutil.copytree(ROOT / "tests/fixtures/data", data)
        p = data / "profiles" / profile
        p.mkdir(parents=True, exist_ok=True)
        (p / "packages.txt").write_text(packages)
        (p / "never-disable.txt").write_text("# no extra never entries\n")
        (p / "match.txt").write_text("prop ro.product.model=Test Unit\n")
        (p / "README.md").write_text("# temp profile\n")
        return data

    def new_run(self, state=None, conf="", profile="fixture-unit", data=None):
        state = dict(state or {})
        state.setdefault("installed", FIXTURE_PACKAGES)
        r = Run(
            state=state,
            conf=conf,
            profile=profile,
            data=data or (ROOT / "tests/fixtures/data"),
        )
        self.runs.append(r)
        p = r("preflight.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        return r

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def debloat(self, *args, state=None, conf="", profile="fixture-unit", data=None):
        r = self.new_run(state=state, conf=conf, profile=profile, data=data)
        return r, r("debloat.sh", *args)

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_dry_run_changes_nothing(self):
        r, p = self.debloat("--tier", "1", "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("will be disabled", p.stdout)
        self.assertIn("dry-run: nothing changed", p.stderr)
        self.assertEqual(list((self.state_dir(r) / "batches").glob("*.tsv")), [])
        for cmd in self.shell_calls(r):
            self.assertNotIn("pm disable-user", cmd)
        for call in r.calls():
            self.assertNotIn("reboot", call)

    def test_actual_batch_disables_records_and_reboots(self):
        r, p = self.debloat("--tier", "1", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        state = r.state()
        for pkg in ("com.vendor.ads", "com.vendor.telemetry", "com.vendor.promo"):
            self.assertIn(pkg, state["disabled"])
        files = list((self.state_dir(r) / "batches").glob("t1-*.tsv"))
        self.assertEqual(len(files), 1)
        plan = files[0].read_text()
        for pkg in ("com.vendor.ads", "com.vendor.telemetry", "com.vendor.promo"):
            self.assertIn(f"{pkg}\tenabled", plan)
        undo = list((Path(r.tmp.name) / "report").glob("manual-undo-*.txt"))
        self.assertEqual(len(undo), 1)
        for pkg in ("com.vendor.ads", "com.vendor.telemetry", "com.vendor.promo"):
            self.assertIn(pkg, undo[0].read_text())
        self.assertTrue(any(c == ["-s", "test-hu", "reboot"] for c in r.calls()))
        self.assertIn(
            "NEXT: a person at the car runs scripts/verify.sh --manual", p.stderr
        )

    def test_plan_covers_whole_batch_when_connection_drops(self):
        state = {"fail_on": ["pm disable-user --user 0 com.vendor.telemetry"]}
        r, p = self.debloat("--tier", "1", "-y", state=state)
        self.assertEqual(p.returncode, 1)
        self.assertIn("no answer from test-hu", p.stderr)
        files = list((self.state_dir(r) / "batches").glob("t1-*.tsv"))
        self.assertEqual(len(files), 1)
        plan = files[0].read_text()
        for pkg in ("com.vendor.ads", "com.vendor.telemetry", "com.vendor.promo"):
            self.assertIn(f"{pkg}\tenabled", plan)

    def test_never_package_is_guarded(self):
        data = self.temp_data(
            "# Never Fixture Unit, build TEST.NEVER\n"
            "com.android.systemui 1 # never-list guard\n",
        )
        r, p = self.debloat(
            "--tier",
            "1",
            "-y",
            state={"installed": ["com.android.systemui"]},
            profile="fixture-never",
            data=data,
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("GUARD", p.stdout)
        self.assertIn("hard: never-disable list", p.stdout)
        self.assertFalse(
            any(
                "pm disable-user --user 0 com.android.systemui" in c
                for c in self.shell_calls(r)
            )
        )

    def test_home_owner_is_guarded(self):
        state = {"installed": GUARD_PACKAGES}
        r, p = self.debloat("--tier", "1", "-y", state=state, profile="fixture-guard")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("GUARD", p.stdout)
        self.assertIn("owns HOME", p.stdout)
        self.assertFalse(
            any(
                "pm disable-user --user 0 com.vendor.launcher" in c
                for c in self.shell_calls(r)
            )
        )

    def test_persistent_guard_and_allow_risky(self):
        state = {
            "installed": GUARD_PACKAGES,
            "dumpsys": {
                "com.vendor.persistent": (
                    "Packages:\n  Package [com.vendor.persistent] (abc):\n"
                    "    userId=10123\n    pkgFlags=[ SYSTEM PERSISTENT ]\n"
                    "    requested permissions:\n"
                )
            },
        }
        r, p = self.debloat(
            "--tier",
            "1",
            "-y",
            state=state,
            profile="fixture-guard",
            conf="ALLOW_RISKY=com.vendor.persistent\n",
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("GUARD", p.stdout)
        self.assertIn("owns HOME", p.stdout)
        self.assertIn("com.vendor.persistent", r.state()["disabled"])
        self.assertNotIn("com.vendor.launcher", r.state()["disabled"])

    def test_keep_list_wins(self):
        r, p = self.debloat("--tier", "1", "-y", conf="KEEP_APPS=com.vendor.ads\n")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("SKIP (keep list)", p.stdout)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])
        self.assertIn("com.vendor.telemetry", r.state()["disabled"])

    def test_tier3_requires_remove_apps(self):
        r, p = self.debloat("--tier", "3", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("SKIP (not chosen in configure.sh)", p.stdout)
        self.assertEqual(r.state()["disabled"], [])

        r2, p2 = self.debloat(
            "--tier", "3", "-y", conf="REMOVE_APPS=com.vendor.games\n"
        )
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertIn("com.vendor.games", r2.state()["disabled"])
        self.assertNotIn("com.vendor.music", r2.state()["disabled"])

    def test_already_disabled_is_not_in_plan(self):
        r, p = self.debloat("--tier", "1", "-y", state={"disabled": ["com.vendor.ads"]})
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("already disabled", p.stdout)
        files = list((self.state_dir(r) / "batches").glob("t1-*.tsv"))
        self.assertEqual(len(files), 1)
        self.assertNotIn("com.vendor.ads", files[0].read_text())

    def test_refused_is_counted(self):
        r, p = self.debloat("--tier", "1", "-y", state={"refuse": ["com.vendor.ads"]})
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("refused", p.stdout)
        self.assertIn("refused 1", p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])

    def test_reenabled_at_boot_is_reported(self):
        r, p = self.debloat(
            "--tier", "1", "-y", state={"reenable_at_boot": ["com.vendor.ads"]}
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("re-enabled at boot", p.stderr)
        self.assertIn("com.vendor.ads", p.stderr)
        self.assertNotIn("com.vendor.ads", r.state()["disabled"])

    def test_updater_kept(self):
        r, p = self.debloat("--tier", "2", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("SKIP (UPDATER_KEEP=1)", p.stdout)
        self.assertNotIn("com.vendor.updater", r.state()["disabled"])
        self.assertIn("com.android.printspooler", r.state()["disabled"])

    def test_suspect_is_counted(self):
        state = {
            "installed": GUARD_PACKAGES,
            "canned": {"pm disable-user --user 0 com.vendor.weird": "weird output"},
        }
        _, p = self.debloat("--tier", "2", "-y", state=state, profile="fixture-guard")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("suspect: weird output", p.stdout)
        self.assertIn("suspect 1", p.stderr)

    def test_gate_blocks_until_checked(self):
        r = self.new_run()
        sd = self.state_dir(r)
        (sd / "batches" / "old.tsv").write_text("com.vendor.ads\tenabled\n")
        (sd / "batches" / "order.txt").write_text("old\n")
        p = r("debloat.sh", "--tier", "1", "-y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("has not passed the car checks", p.stderr)
        self.assertFalse(any("pm disable-user" in c for c in self.shell_calls(r)))

    def test_no_confirmation_without_a_tty(self):
        r = self.new_run()
        p = r("debloat.sh", "--tier", "1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("needs a yes from a person", p.stderr)
        self.assertFalse(any("pm disable-user" in c for c in self.shell_calls(r)))

    def test_tier_disabled_in_conf_does_nothing(self):
        r, p = self.debloat("--tier", "1", "-y", conf="TIER1=0\n")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("TIER1=0", p.stderr)
        self.assertEqual(r.state()["disabled"], [])

    def test_absent_is_skipped(self):
        state = {"installed": [p for p in FIXTURE_PACKAGES if p != "com.vendor.ads"]}
        r, p = self.debloat("--tier", "1", "-y", state=state)
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("absent", p.stdout)
        self.assertIn("com.vendor.telemetry", r.state()["disabled"])


if __name__ == "__main__":
    unittest.main()
