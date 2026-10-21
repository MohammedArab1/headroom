import json
import unittest
from pathlib import Path

from helpers import Run


class PreflightTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def run_preflight(self, *args, state=None):
        state = dict(state or {})
        state.setdefault("installed", ["com.android.systemui"])
        r = Run(state=state, profile="fixture-unit")
        self.runs.append(r)
        return r, r("preflight.sh", *args)

    def state_dir(self, r):
        dirs = [p for p in Path(r.home).iterdir() if p.is_dir()]
        self.assertEqual(len(dirs), 1, msg=f"expected one device state dir, got {dirs}")
        return dirs[0]

    def shell_commands(self, r):
        out = []
        for call in r.calls():
            if call[:3] == ["-s", "test-hu", "shell"]:
                out.append(" ".join(call[3:]))
        return out

    def test_prints_facts_and_writes_snapshot(self):
        state = {
            "installed": [
                "com.vendor.launcher",
                "com.android.systemui",
                "com.vendor.ads",
            ]
        }
        r, p = self.run_preflight(state=state)
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("real API 33", p.stdout)
        self.assertIn("profile        fixture-unit", p.stdout)
        self.assertIn("3 installed", p.stdout)
        self.assertIn("25.0 GB", p.stdout)
        self.assertIn("snapshot       written to", p.stdout)

        sd = self.state_dir(r) / "snapshot"
        for name in (
            "props.txt",
            "settings-system.txt",
            "settings-secure.txt",
            "settings-global.txt",
            "packages-all.txt",
            "packages-disabled.txt",
            "packages-third.txt",
            "packages-paths.txt",
            "home.txt",
            "meta.txt",
        ):
            self.assertTrue((sd / name).exists(), msg=f"missing snapshot file {name}")
        self.assertIn("[ro.product.model]: [Test Unit]", (sd / "props.txt").read_text())
        meta = (sd / "meta.txt").read_text()
        self.assertIn("version=0.1.0", meta)
        self.assertIn("sdk=33", meta)
        self.assertTrue((self.state_dir(r) / "home-before.txt").exists())
        self.assertIn(
            "com.vendor.launcher/.Main",
            (self.state_dir(r) / "home-before.txt").read_text(),
        )

        for cmd in self.shell_commands(r):
            for forbidden in (
                "pm disable-user",
                "pm enable",
                "settings put",
                "settings delete",
                "reboot",
                "pm install",
                "pm uninstall",
            ):
                self.assertNotIn(
                    forbidden, cmd, msg=f"preflight changed the unit: {cmd}"
                )

    def test_snapshot_first_run_wins(self):
        r, p = self.run_preflight()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        sd = self.state_dir(r) / "snapshot"
        before = (sd / "props.txt").read_text()

        state = json.loads(r.state_file.read_text())
        state["props"]["ro.build.display.id"] = "CHANGED.BUILD"
        r.state_file.write_text(json.dumps(state))

        p2 = r("preflight.sh")
        self.assertEqual(p2.returncode, 0, msg=p2.stdout + p2.stderr)
        self.assertIn("already exists", p2.stdout)
        self.assertEqual((sd / "props.txt").read_text(), before)
        self.assertNotIn("CHANGED.BUILD", (sd / "props.txt").read_text())

    def test_dry_run_writes_no_snapshot(self):
        r, p = self.run_preflight("--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("would write", p.stdout)
        sd = self.state_dir(r)
        self.assertFalse((sd / "snapshot").exists())
        self.assertFalse((sd / "home-before.txt").exists())

    def test_mismatch_is_flagged(self):
        _, p = self.run_preflight(
            state={
                "props": {
                    "ro.build.version.release": "13",
                    "ro.build.version.sdk": "29",
                }
            }
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("MISMATCH", p.stdout)

    def test_matching_release_is_not_flagged(self):
        _, p = self.run_preflight(
            state={
                "props": {
                    "ro.build.version.release": "13",
                    "ro.build.version.sdk": "33",
                }
            }
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("MISMATCH", p.stdout)

    def test_ram_smaller_than_claimed_is_flagged(self):
        _, p = self.run_preflight(state={"props": {"ro.config.ram": "4096"}})
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("smaller than claimed", p.stdout)


if __name__ == "__main__":
    unittest.main()
