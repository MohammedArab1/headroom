import json
import unittest
from pathlib import Path

from helpers import Run


class BenchmarkTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def run_bench(self, *args, state=None, conf=""):
        state = dict(state or {})
        state.setdefault("installed", ["com.waze", "com.vendor.music"])
        state.setdefault("third", ["com.waze"])
        state.setdefault("launchers", {"com.waze": ["com.waze/.Main"]})
        state.setdefault("am_home_times", [250, 300, 200])
        state.setdefault("am_app_times", {"com.waze": [900, 1200, 1000]})
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        return r, r("benchmark.sh", *args)

    def report(self, r, label="test"):
        reports = list((Path(r.tmp.name) / "report").glob(f"bench-{label}-*.json"))
        self.assertEqual(len(reports), 1, msg=f"expected one report, got {reports}")
        return reports[0], json.loads(reports[0].read_text())

    def test_medians_and_json(self):
        r, p = self.run_bench(
            "--label",
            "test",
            "--runs",
            "3",
            "--settle",
            "0",
            conf="BENCH_APPS=com.waze\n",
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        path, data = self.report(r)
        self.assertEqual(data["label"], "test")
        self.assertEqual(data["runs"], 3)
        self.assertEqual(data["sdk"], 33)
        self.assertEqual(data["mem_available_kb"], 612340)
        self.assertEqual(data["app_processes"], 3)
        self.assertEqual(data["loadavg_1m"], 1.25)
        self.assertEqual(data["home_ms"], 250)
        self.assertEqual(data["apps.com.waze_cold_ms"], 1000)
        self.assertIsNone(data["boot_enable_screen_ms"])
        self.assertEqual(data["data_free_kb"], 11878400)
        self.assertEqual(data["disabled_packages"], 0)
        state_copies = list(Path(r.home).glob("*/bench/bench-test-*.json"))
        self.assertEqual(len(state_copies), 1)
        self.assertTrue(path.exists())

    def test_ps_fallback_and_null_when_output_is_empty(self):
        home_cmd = (
            "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME"
        )
        state = {
            "ps_users": "bad pid '-A'",
            "canned": {home_cmd: ""},
        }
        r, p = self.run_bench(
            "--label", "test", "--runs", "2", "--settle", "0", state=state
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        _, data = self.report(r)
        self.assertEqual(data["app_processes"], 3)
        self.assertIsNone(data["home_ms"])

    def test_guarded_bench_app_is_skipped(self):
        state = {
            "installed": ["com.vendor.radio"],
            "third": ["com.vendor.radio"],
        }
        r, p = self.run_bench(
            "--label",
            "test",
            "--runs",
            "1",
            "--settle",
            "0",
            state=state,
            conf="BENCH_APPS=com.vendor.radio\n",
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        _, data = self.report(r)
        self.assertNotIn("apps.com.vendor.radio_cold_ms", data)
        self.assertIn("guarded", p.stderr)

    def test_vendor_bench_app_is_skipped(self):
        state = {"installed": ["com.vendor.music"], "third": []}
        r, p = self.run_bench(
            "--label",
            "test",
            "--runs",
            "1",
            "--settle",
            "0",
            state=state,
            conf="BENCH_APPS=com.vendor.music\n",
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        _, data = self.report(r)
        self.assertNotIn("apps.com.vendor.music_cold_ms", data)
        self.assertIn("not third-party", p.stderr)

    def test_boot_metric(self):
        r, p = self.run_bench(
            "--label", "test", "--runs", "1", "--settle", "0", "--boot", "-y"
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        _, data = self.report(r)
        self.assertEqual(data["boot_enable_screen_ms"], 12000)
        self.assertEqual(r.state().get("reboots"), 1)

    def test_dry_run_writes_nothing_and_starts_nothing(self):
        r, p = self.run_bench(
            "--label", "test", "--dry-run", conf="BENCH_APPS=com.waze\n"
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("[dry-run]", p.stderr)
        reports = list((Path(r.tmp.name) / "report").glob("bench-*.json"))
        self.assertEqual(reports, [])
        for call in r.calls():
            if call[:3] == ["-s", "test-hu", "shell"]:
                self.assertFalse(
                    call[3].startswith(("am ", "input ", "reboot")),
                    msg=f"dry-run changed the foreground: {call[3]}",
                )

    def test_existing_before_requires_a_person(self):
        r, p = self.run_bench("--label", "test", "--runs", "1", "--settle", "0")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        report_dir = Path(r.tmp.name) / "report"
        (report_dir / "bench-before-20260101-1200.json").write_text("{}")
        p2 = r("benchmark.sh", "--label", "before", "--runs", "1", "--settle", "0")
        self.assertEqual(p2.returncode, 1)
        self.assertIn("needs a yes from a person", p2.stderr)

    def test_invalid_label_and_runs(self):
        _, p = self.run_bench("--label", "bad/name")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--label", p.stderr)
        _, p2 = self.run_bench("--label", "test", "--runs", "0")
        self.assertEqual(p2.returncode, 1)
        self.assertIn("--runs", p2.stderr)


if __name__ == "__main__":
    unittest.main()
