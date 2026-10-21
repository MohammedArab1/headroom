import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import ROOT

STUB_LIB = """\
CONF=${CONF:?}
REPORT=${REPORT:?}
load_conf() { LAUNCHER=1; [[ -f $CONF ]] && . "$CONF"; }
"""

STUB = """\
#!/usr/bin/env bash
name=$(basename "$0")
{
  printf '%s' "$name"
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\\n'
} >> "$STUB_LOG"
if [[ ${STUB_FAIL:-} == "$name" ]]; then exit 1; fi
if [[ $name == benchmark.sh ]]; then
  case " $* " in *" --label before "*) : > "$REPORT/bench-before-stub.json" ;; esac
fi
exit 0
"""

STEPS = [
    "preflight.sh",
    "configure.sh",
    "benchmark.sh",
    "debloat.sh",
    "verify.sh",
    "tune.sh",
    "launcher.sh",
]

EXPECTED_ORDER = [
    "preflight.sh",
    "benchmark.sh --label before",
    "debloat.sh --tier 1",
    "verify.sh",
    "verify.sh --manual",
    "debloat.sh --tier 2",
    "verify.sh",
    "verify.sh --manual",
    "debloat.sh --tier 3",
    "verify.sh",
    "verify.sh --manual",
    "tune.sh",
    "launcher.sh",
    "verify.sh",
]


class AllTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        shutil.copy(ROOT / "scripts/all.sh", self.dir / "all.sh")
        (self.dir / "lib.sh").write_text(STUB_LIB)
        for name in STEPS:
            path = self.dir / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.conf = self.dir / "headroom.conf"
        self.conf.write_text("")
        self.report = self.dir / "report"
        self.report.mkdir()
        self.log = self.dir / "calls.log"

    def run_all(self, *args, fail=None):
        env = dict(
            os.environ,
            CONF=str(self.conf),
            REPORT=str(self.report),
            STUB_LOG=str(self.log),
        )
        if fail:
            env["STUB_FAIL"] = fail
        return subprocess.run(
            ["/bin/bash", str(self.dir / "all.sh"), *args],
            env=env,
            cwd=self.dir,
            text=True,
            capture_output=True,
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_exact_order(self):
        p = self.run_all()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertEqual(EXPECTED_ORDER, self.calls())

    def test_configure_runs_when_the_conf_is_missing(self):
        self.conf.unlink()
        p = self.run_all()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        calls = self.calls()
        self.assertEqual("preflight.sh", calls[0])
        self.assertEqual("configure.sh", calls[1])

    def test_flags_pass_through_and_manual_checks_are_skipped_in_dry_run(self):
        p = self.run_all("--dry-run", "-y")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        calls = self.calls()
        self.assertFalse(any("--manual" in line for line in calls), msg=calls)
        self.assertNotIn("Car checks for tier", p.stdout)
        for line in calls:
            if line.startswith(
                ("preflight.sh", "benchmark.sh", "debloat.sh", "tune.sh", "launcher.sh")
            ):
                self.assertTrue(line.endswith("--dry-run -y"), msg=line)
        self.assertIn("debloat.sh --tier 3 --dry-run -y", calls)
        self.assertIn("launcher.sh --dry-run -y", calls)

    def test_a_failing_step_stops_the_run(self):
        p = self.run_all(fail="debloat.sh")
        self.assertEqual(p.returncode, 1)
        calls = self.calls()
        self.assertEqual(
            ["preflight.sh", "benchmark.sh --label before", "debloat.sh --tier 1"],
            calls,
        )
        self.assertNotIn("tune.sh", calls)
        self.assertNotIn("launcher.sh", calls)

    def test_launcher_is_skipped_when_disabled(self):
        self.conf.write_text("LAUNCHER=0\n")
        p = self.run_all()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertNotIn("launcher.sh", self.calls())
        self.assertEqual("verify.sh", self.calls()[-1])

    def test_help_does_nothing(self):
        p = self.run_all("--help")
        self.assertEqual(p.returncode, 0)
        self.assertIn("usage: scripts/all.sh", p.stdout)
        self.assertEqual([], self.calls())


if __name__ == "__main__":
    unittest.main()
