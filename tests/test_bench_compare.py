import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from helpers import ROOT


def load_compare():
    path = ROOT / "tools" / "bench_compare.py"
    spec = importlib.util.spec_from_file_location("bench_compare", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BenchCompareTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_compare()

    def test_percentage_and_direction(self):
        self.assertEqual(self.mod.percent(100, 130), "+30.0%")
        self.assertEqual(self.mod.percent(100, 50), "-50.0%")
        self.assertEqual(self.mod.percent(0, 10), "n/a")

        self.assertEqual(self.mod.verdict("mem_available_kb", 100, 130), "better")
        self.assertEqual(self.mod.verdict("mem_available_kb", 100, 90), "worse")
        self.assertEqual(self.mod.verdict("home_ms", 100, 50), "better")
        self.assertEqual(self.mod.verdict("home_ms", 100, 150), "worse")
        self.assertEqual(self.mod.verdict("apps.com.waze_cold_ms", 900, 800), "better")
        self.assertEqual(self.mod.verdict("disabled_packages", 2, 3), "context")

    def test_missing_key_is_not_a_crash(self):
        text = self.mod.render({"home_ms": 100, "app_processes": 10}, {"home_ms": 80})
        self.assertIn("home_ms", text)
        self.assertIn("app_processes", text)
        self.assertIn("missing", text)

    def test_render_has_header_and_skips_metadata(self):
        text = self.mod.render(
            {
                "label": "before",
                "runs": 5,
                "sdk": 33,
                "home_ms": 100,
                "data_free_kb": 1000,
                "disabled_packages": 1,
            },
            {
                "label": "after",
                "runs": 5,
                "sdk": 33,
                "home_ms": 50,
                "data_free_kb": 2000,
                "disabled_packages": 1,
            },
        )
        self.assertIn("metric", text)
        self.assertIn("+100.0%", text)
        self.assertIn("better", text)
        self.assertIn("context", text)
        self.assertNotIn("label", text)
        self.assertNotIn("runs", text)
        self.assertNotIn("sdk", text)

    def test_main_reads_two_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            before = Path(tmp) / "before.json"
            after = Path(tmp) / "after.json"
            before.write_text(json.dumps({"mem_available_kb": 100, "home_ms": 400}))
            after.write_text(json.dumps({"mem_available_kb": 150, "home_ms": 200}))
            with mock.patch("sys.stdout") as out:
                rc = self.mod.main([str(before), str(after)])
            self.assertEqual(rc, 0)
            printed = "".join(call.args[0] for call in out.write.call_args_list)
            self.assertIn("mem_available_kb", printed)
            self.assertIn("+50.0%", printed)
            self.assertIn("-50.0%", printed)

    def test_bad_json_exits_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.json"
            bad.write_text("{not json")
            rc = self.mod.main([str(bad), str(bad)])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
