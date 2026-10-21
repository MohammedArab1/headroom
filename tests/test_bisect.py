import unittest
from pathlib import Path

from helpers import Run

PACKAGES = [f"com.vendor.p{i}" for i in range(1, 7)]


class BisectTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def new_run(self, state=None):
        state = dict(state or {})
        state.setdefault("installed", PACKAGES)
        r = Run(state=state, profile="fixture-unit")
        self.runs.append(r)
        p = r("preflight.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        return r

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one state dir, got {dirs}")
        return dirs[0]

    def write_batch(self, r, packages, batch="b1", restored=True, order=None):
        sd = self.state_dir(r)
        (sd / "batches" / f"{batch}.tsv").write_text(
            "".join(f"{p}\tenabled\n" for p in packages)
        )
        (sd / "batches" / "order.txt").write_text((order or batch) + "\n")
        if restored:
            (sd / "batches" / f"{batch}.restored").write_text("")
        return sd

    def shell_calls(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_finds_planted_culprit_in_six_packages(self):
        r = self.new_run()
        sd = self.write_batch(r, PACKAGES)
        p = r("bisect.sh", "--batch", "b1", "--answers", "y n y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("the culprit is com.vendor.p2", p.stderr)
        rounds = sorted((sd / "batches").glob("bisect-*-r*.tsv"))
        self.assertEqual(len(rounds), 3, msg=str(rounds))
        restored = [path for path in rounds if path.with_suffix(".restored").exists()]
        self.assertEqual(len(restored), 2, msg=str(rounds))
        # The unproven half from round 2 stays disabled until restore.
        self.assertIn("com.vendor.p1", r.state()["disabled"])
        self.assertNotIn("com.vendor.p2", r.state()["disabled"])

        p2 = r("restore.sh", "--all", "--no-tweaks", "--no-home", "-y")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertEqual(r.state()["disabled"], [])

    def test_all_no_answers_find_the_last_package(self):
        r = self.new_run()
        self.write_batch(r, PACKAGES[:4])
        p = r("bisect.sh", "--batch", "b1", "--answers", "n n")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("the culprit is com.vendor.p4", p.stderr)
        self.assertNotIn("com.vendor.p4", r.state()["disabled"])
        for pkg in ("com.vendor.p1", "com.vendor.p2", "com.vendor.p3"):
            self.assertIn(pkg, r.state()["disabled"])

    def test_one_suspect_needs_no_questions(self):
        r = self.new_run()
        self.write_batch(r, ["com.vendor.p1"])
        p = r("bisect.sh", "--batch", "b1")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("the culprit is com.vendor.p1", p.stderr)
        self.assertFalse(any("pm disable-user" in c for c in self.shell_calls(r)))

    def test_dry_run_changes_nothing(self):
        r = self.new_run()
        sd = self.write_batch(r, PACKAGES[:2])
        p = r("bisect.sh", "--batch", "b1", "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("[dry-run] would disable", p.stderr)
        self.assertFalse(any("pm disable-user" in c for c in self.shell_calls(r)))
        self.assertEqual(len(list((sd / "batches").glob("bisect-*.tsv"))), 0)

    def test_suspect_still_disabled_needs_restore_first(self):
        r = self.new_run(state={"disabled": ["com.vendor.p1"]})
        self.write_batch(r, PACKAGES[:2])
        p = r("bisect.sh", "--batch", "b1", "--answers", "y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("still disabled", p.stderr)
        self.assertIn("restore.sh --last", p.stderr)
        self.assertFalse(any("pm disable-user" in c for c in self.shell_calls(r)))

    def test_guard_refuses_to_disable_a_suspect(self):
        state = {
            "dumpsys": {
                "com.vendor.p1": (
                    "Packages:\n  Package [com.vendor.p1] (abc):\n    userId=10123\n"
                    "    pkgFlags=[ SYSTEM PERSISTENT ]\n    requested permissions:\n"
                )
            },
        }
        r = self.new_run(state=state)
        self.write_batch(r, PACKAGES[:2])
        p = r("bisect.sh", "--batch", "b1", "--answers", "y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("GUARD", p.stderr)
        self.assertFalse(
            any(
                "pm disable-user --user 0 com.vendor.p1" in c
                for c in self.shell_calls(r)
            )
        )

    def test_no_answers_and_no_tty_stops_before_disabling(self):
        r = self.new_run()
        self.write_batch(r, PACKAGES[:2])
        p = r("bisect.sh", "--batch", "b1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("a person at the car must answer", p.stderr)
        self.assertFalse(any("pm disable-user" in c for c in self.shell_calls(r)))

    def test_invalid_answer_dies(self):
        r = self.new_run()
        self.write_batch(r, PACKAGES[:2])
        p = r("bisect.sh", "--batch", "b1", "--answers", "maybe")
        self.assertEqual(p.returncode, 1)
        self.assertIn("takes y or n", p.stderr)

    def test_reboot_each_reboots_once_per_round(self):
        r = self.new_run()
        self.write_batch(r, PACKAGES[:2])
        p = r("bisect.sh", "--batch", "b1", "--reboot-each", "--answers", "y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertEqual(r.state().get("reboots"), 1)
        self.assertIn("the culprit is com.vendor.p1", p.stderr)

    def test_missing_batch_dies(self):
        r = self.new_run()
        p = r("bisect.sh", "--batch", "nope", "--answers", "y")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no plan for batch", p.stderr)


if __name__ == "__main__":
    unittest.main()
