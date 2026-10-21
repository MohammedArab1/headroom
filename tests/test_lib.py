import os
import re
import subprocess
import unittest

from helpers import ROOT, Run


class LibTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def lib(self, snippet, state=None, profile="fixture-unit"):
        r = Run(state=state, profile=profile)
        self.runs.append(r)
        return r.bash(snippet)

    def assert_lib_ok(self, p):
        self.assertEqual(p.returncode, 0, msg=p.stderr + p.stdout)

    # ---------- lists ----------

    def test_list_of_strips_comments_and_blank_lines(self):
        p = self.lib(
            "f=$(mktemp); printf '# x\\n\\ncom.a   \\ncom.b # y\\n' > \"$f\"; "
            'list_of "$f"; rm -f "$f"'
        )
        self.assert_lib_ok(p)
        self.assertEqual(p.stdout.splitlines(), ["com.a", "com.b"])

    def test_in_lines_exact_only(self):
        p = self.lib(
            'in_lines com.a "com.ab"; echo "a=$?"; '
            'in_lines com.a "com.a"; echo "b=$?"; '
            'in_lines com.a ""; echo "c=$?"'
        )
        self.assert_lib_ok(p)
        self.assertEqual(p.stdout.splitlines(), ["a=1", "b=0", "c=1"])

    def test_in_words_exact_only(self):
        p = self.lib(
            'in_words com.a "com.ab"; echo "a=$?"; '
            'in_words com.a "com.b com.a"; echo "b=$?"'
        )
        self.assert_lib_ok(p)
        self.assertEqual(p.stdout.splitlines(), ["a=1", "b=0"])

    # ---------- guards ----------

    def test_is_never_exact_and_pattern(self):
        p = self.lib(
            "load_device_facts; "
            'is_never com.android.documentsui; echo "exact=$?"; '
            'is_never com.android.systemui; echo "pattern=$?"; '
            'is_never com.vendor.ads; echo "ads=$?"'
        )
        self.assert_lib_ok(p)
        self.assertEqual(p.stdout.splitlines(), ["exact=0", "pattern=0", "ads=1"])

    def test_risk_persistent_and_uid(self):
        state = {
            "dumpsys": {
                "com.vendor.svc": (
                    "Packages:\n  Package [com.vendor.svc] (abc):\n    userId=1000\n"
                    "    pkgFlags=[ SYSTEM PERSISTENT ]\n    requested permissions:\n"
                )
            }
        }
        p = self.lib("load_device_facts; risk_reasons com.vendor.svc", state=state)
        self.assert_lib_ok(p)
        self.assertIn("risk: shared core uid 1000", p.stdout)
        self.assertIn("risk: persistent", p.stdout)

    def test_risk_sensitive_permission(self):
        state = {
            "dumpsys": {
                "com.vendor.kb": (
                    "Packages:\n  Package [com.vendor.kb] (abc):\n    userId=10123\n"
                    "    pkgFlags=[ SYSTEM ]\n    requested permissions:\n"
                    "      android.permission.INJECT_EVENTS\n"
                )
            }
        }
        p = self.lib("load_device_facts; risk_reasons com.vendor.kb", state=state)
        self.assert_lib_ok(p)
        self.assertIn("risk: requests android.permission.INJECT_EVENTS", p.stdout)

    def test_allow_risky_clears_risk_not_hard(self):
        state = {
            "home": "com.vendor.home/.Main",
            "dumpsys": {
                "com.vendor.home": (
                    "Packages:\n  Package [com.vendor.home] (abc):\n    userId=10123\n"
                    "    pkgFlags=[ SYSTEM PERSISTENT ]\n    requested permissions:\n"
                )
            },
        }
        p = self.lib(
            "load_device_facts; ALLOW_RISKY=com.vendor.home; blocking_reasons com.vendor.home",
            state=state,
        )
        self.assert_lib_ok(p)
        self.assertIn("hard: owns HOME", p.stdout)
        self.assertNotIn("risk: persistent", p.stdout)

    def test_home_and_ime_are_hard(self):
        p = self.lib(
            "load_device_facts; risk_reasons com.vendor.launcher; echo ---; "
            "risk_reasons com.android.inputmethod.latin"
        )
        self.assert_lib_ok(p)
        home_out, ime_out = p.stdout.split("---\n")
        self.assertIn("hard: owns HOME", home_out)
        self.assertIn("hard: current keyboard", ime_out)

    def test_guards_fail_closed_without_home(self):
        cmd = (
            "cmd package query-activities --brief -a android.intent.action.MAIN "
            "-c android.intent.category.HOME"
        )
        p = self.lib("load_device_facts", state={"canned": {cmd: ""}})
        self.assertEqual(p.returncode, 1)
        self.assertIn("could not tell which apps answer HOME", p.stderr)

    # ---------- changing packages ----------

    def test_disable_one_parses_outcomes(self):
        state = {
            "installed": ["com.vendor.ads", "com.vendor.refuse", "com.vendor.weird"],
            "refuse": ["com.vendor.refuse"],
            "canned": {"pm disable-user --user 0 com.vendor.weird": "weird output"},
        }
        p = self.lib(
            'disable_one com.vendor.ads; echo "rc=$?"; '
            'disable_one com.vendor.refuse; echo "rc=$?"; '
            'disable_one com.vendor.weird; echo "rc=$?"',
            state=state,
        )
        self.assert_lib_ok(p)
        self.assertEqual(
            p.stdout.splitlines(),
            [
                "disabled",
                "rc=0",
                "refused",
                "rc=0",
                "suspect: weird output",
                "rc=0",
            ],
        )
        self.assertIn("com.vendor.ads", self.runs[0].state()["disabled"])

    # ---------- batches ----------

    def test_write_plan_is_atomic_and_first_wins(self):
        p = self.lib(
            'STATE=$(mktemp -d); mkdir -p "$STATE/batches"; '
            'printf "a\\tx\\n" | write_plan b1; '
            'printf "b\\ty\\n" | write_plan b2; '
            '( printf "c\\tz\\n" | write_plan b1 ); echo "second=$?"; '
            'printf "FILE="; cat "$STATE/batches/b1.tsv"; '
            'printf "ORDER="; tr "\\n" "," < "$STATE/batches/order.txt"; echo; '
            'find "$STATE/batches" -name "*.tmp" | wc -l | tr -d " "'
        )
        self.assert_lib_ok(p)
        self.assertIn("second=1", p.stdout)
        self.assertIn("FILE=a\tx", p.stdout)
        self.assertIn("ORDER=b1,b2,", p.stdout)
        self.assertTrue(p.stdout.rstrip().endswith("0"), p.stdout)

    # ---------- device selection ----------

    def test_need_device_refuses_two_devices(self):
        r = Run(
            state={"devices": ["test-hu", "other-hu"]},
            profile="fixture-unit",
            preset_serial=False,
        )
        self.runs.append(r)
        p = r.bash("need_device")
        self.assertEqual(p.returncode, 1)
        self.assertIn("several devices connected", p.stderr)

    def test_need_device_dedupes_one_unit_listed_twice(self):
        r = Run(
            state={
                "devices": ["test-hu", "203.0.113.5:5555"],
                "serials": ["test-hu", "203.0.113.5:5555"],
            },
            profile="fixture-unit",
            preset_serial=False,
        )
        self.runs.append(r)
        p = r.bash('need_device; echo "serial=$SERIAL"; echo "sdk=$SDK"')
        self.assert_lib_ok(p)
        self.assertIn("serial=203.0.113.5:5555", p.stdout)
        self.assertIn("sdk=33", p.stdout)

    def test_detect_profile_from_props(self):
        r = Run(profile="")
        self.runs.append(r)
        p = r.bash('need_device; echo "profile=$PROFILE"')
        self.assert_lib_ok(p)
        self.assertIn("profile=fixture-unit", p.stdout)

    # ---------- rules enforced by scanning the sources ----------

    def source_files(self):
        files = sorted((ROOT / "scripts").glob("*.sh"))
        files += (
            sorted((ROOT / "launcher").glob("*.sh"))
            if (ROOT / "launcher").exists()
            else []
        )
        return files

    def test_no_grep_q_in_pipelines(self):
        pat = re.compile(r"\|\s*grep\s+-q")
        for f in self.source_files():
            self.assertIsNone(
                pat.search(f.read_text()), msg=f"{f} ends a pipeline in grep -q"
            )

    def test_forbidden_commands_absent(self):
        forbidden = [
            "adb root",
            "remount",
            "su -c",
            "pm uninstall",
            "content query",
            "pm clear",
            "wipe",
        ]
        for f in self.source_files():
            text = f.read_text()
            for word in forbidden:
                self.assertNotIn(
                    word, text, msg=f"{f} contains forbidden command: {word}"
                )

    def test_fake_adb_unknown_command_exits_92(self):
        r = Run()
        self.runs.append(r)
        p = subprocess.run(
            [str(ROOT / "tests/fake_adb.py"), "-s", "test-hu", "shell", "uname", "-a"],
            env=r.env(),
            text=True,
            capture_output=True,
        )
        self.assertEqual(p.returncode, 92)
        self.assertIn("unexpected command", p.stderr)


if __name__ == "__main__":
    unittest.main()
