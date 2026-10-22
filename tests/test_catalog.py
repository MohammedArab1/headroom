import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from helpers import ROOT, Run

TEMPLATE = ROOT / "catalog" / "devices" / "_template.yaml"
VALIDATE = ROOT / "catalog" / "validate.py"

BASE = [
    "--no-device",
    "-y",
    "--id",
    "test-fixture",
    "--title",
    "Test Head Unit",
    "--developer-mode",
    "Settings > About > tap Build number 7 times",
    "--adb-method",
    "wireless-debugging",
    "--ip-location",
    "Settings > Network",
    "--sdk",
    "33",
    "--ram-mb",
    "2048",
    "--profile",
    "generic",
]


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def variant(self, name="test-fixture", replacements=(), set_id=True):
        text = TEMPLATE.read_text()
        if set_id:
            text = text.replace("id: example-unit", f"id: {name}")
        for old, new in replacements:
            self.assertIn(old, text)
            text = text.replace(old, new)
        path = self.dir / f"{name}.yaml"
        path.write_text(text)
        return path

    def validate(self, *paths):
        return subprocess.run(
            [sys.executable, str(VALIDATE), *map(str, paths)],
            text=True,
            capture_output=True,
        )

    def contribute(self, *args):
        r = Run(profile="generic")
        self.addCleanup(r.tmp.cleanup)
        env = r.env()
        env["PYTHON"] = sys.executable
        p = subprocess.run(
            ["/bin/bash", str(ROOT / "scripts" / "contribute.sh"), *args],
            env=env,
            text=True,
            capture_output=True,
        )
        return r, p

    def test_template_copies_as_a_valid_entry(self):
        p = self.validate(self.variant())
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("entry valid", p.stdout)

    def test_default_scan_skips_the_template(self):
        p = subprocess.run(
            [sys.executable, str(VALIDATE)], text=True, capture_output=True
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)

    def test_wrong_enum_is_rejected(self):
        p = self.validate(
            self.variant(replacements=[("platform: unknown", "platform: windows")])
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("platform", p.stdout)

    def test_tested_with_a_failed_check_is_rejected(self):
        p = self.validate(
            self.variant(
                replacements=[
                    ("status: untested", "status: tested"),
                    ("car_checks: {}", 'car_checks:\n  "reverse": "fail"'),
                ]
            )
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("reverse", p.stdout)

    def test_tested_without_checks_is_rejected(self):
        p = self.validate(
            self.variant(replacements=[("status: untested", "status: tested")])
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("at least one", p.stdout)

    def test_private_ip_in_notes_is_rejected(self):
        p = self.validate(
            self.variant(
                replacements=[
                    (
                        'notes: "Template only. status stays untested until a person ran the full pass."',
                        'notes: "The unit showed 203.0.113.5"',
                    )
                ]
            )
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("IP address", p.stdout)

    def test_email_in_notes_is_rejected(self):
        p = self.validate(
            self.variant(
                replacements=[
                    (
                        'notes: "Template only. status stays untested until a person ran the full pass."',
                        'notes: "Ask someone@example.com"',
                    )
                ]
            )
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("e-mail", p.stdout)

    def test_id_must_match_the_file_name(self):
        p = self.validate(self.variant(set_id=False))
        self.assertEqual(p.returncode, 1)
        self.assertIn("does not match the file name", p.stdout)

    def test_profile_must_exist(self):
        p = self.validate(
            self.variant(
                replacements=[("profile: generic", "profile: no-such-profile")]
            )
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("no-such-profile", p.stdout)

    def test_duplicate_ids_are_rejected(self):
        first = self.dir / "a"
        second = self.dir / "b"
        first.mkdir()
        second.mkdir()
        for directory in (first, second):
            (directory / "dup.yaml").write_text(
                TEMPLATE.read_text().replace("id: example-unit", "id: dup")
            )
        p = self.validate(first / "dup.yaml", second / "dup.yaml")
        self.assertEqual(p.returncode, 1)
        self.assertIn("duplicate id", p.stdout)

    def test_contribute_no_device_writes_a_valid_entry(self):
        r, p = self.contribute(*BASE, "--quirk", "The clock drifts after a cold boot")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        out = r.catalog / "test-fixture.yaml"
        self.assertTrue(out.exists())
        text = out.read_text()
        self.assertIn('id: "test-fixture"', text)
        self.assertIn("The clock drifts after a cold boot", text)
        v = self.validate(out)
        self.assertEqual(v.returncode, 0, msg=v.stdout + v.stderr)

    def test_contribute_refuses_an_ip_shaped_quirk(self):
        r, p = self.contribute(*BASE, "--quirk", "seen at 203.0.113.5")
        self.assertEqual(p.returncode, 1)
        self.assertIn("IP address", p.stderr)
        self.assertFalse((r.catalog / "test-fixture.yaml").exists())

    def test_contribute_dry_run_writes_nothing(self):
        r, p = self.contribute(*BASE, "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn('id: "test-fixture"', p.stdout)
        self.assertIn("dry-run: nothing written", p.stderr)
        self.assertFalse((r.catalog / "test-fixture.yaml").exists())

    def test_contribute_tested_needs_a_clean_check_file(self):
        _, p = self.contribute(*BASE, "--status", "tested")
        self.assertEqual(p.returncode, 1)
        self.assertIn("status tested", p.stderr)

    def test_contribute_prompt_needs_a_pipe(self):
        _, p = self.contribute(*BASE, "--prompt", "nopipe")
        self.assertEqual(p.returncode, 1)
        self.assertIn("name|fix", p.stderr)


if __name__ == "__main__":
    unittest.main()
