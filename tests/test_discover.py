import unittest
from pathlib import Path

from helpers import Run

INSTALLED = [
    "com.android.systemui",
    "com.android.printspooler",
    "com.google.android.misc",
    "com.vendor.factory",
    "com.vendor.canbus",
    "com.vendor.rear",
    "com.vendor.telemetry",
    "com.vendor.ads",
    "com.vendor.store",
    "com.vendor.music",
    "com.vendor.pushsvc",
    "com.vendor.svc",
    "com.example.app",
]

DUMPSYS = {
    "com.vendor.rear": (
        "Packages:\n  Package [com.vendor.rear] (abc):\n    userId=1000\n"
        "    pkgFlags=[ SYSTEM PERSISTENT ]\n"
        "    requested permissions:\n      android.permission.CAMERA\n"
        "    Registered Services:\n      com.vendor.rear/.RearCameraService\n"
        "    Receiver Resolver Table:\n      android.intent.action.BOOT_COMPLETED\n"
    ),
    "com.vendor.pushsvc": (
        "Packages:\n  Package [com.vendor.pushsvc] (abc):\n    userId=10123\n"
        "    pkgFlags=[ SYSTEM PERSISTENT ]\n    requested permissions:\n"
    ),
}


class DiscoverTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def run_discover(self, *args, env=None):
        state = {
            "installed": INSTALLED,
            "disabled": ["com.vendor.ads"],
            "third": ["com.example.app"],
            "dumpsys": DUMPSYS,
            "launchers": {
                "com.vendor.ads": ["com.vendor.ads/.MainActivity"],
                "com.vendor.music": ["com.vendor.music/.Player"],
                "com.vendor.rear": ["com.vendor.rear/.CameraActivity"],
            },
            "home_claims": ["com.vendor.launcher/.Main"],
        }
        r = Run(state=state, profile="fixture-unit")
        self.runs.append(r)
        p = r("discover.sh", *args, env=env)
        reports = list((Path(r.tmp.name) / "report").glob("discover-*.txt"))
        return r, p, reports

    def report_text(self, reports):
        self.assertEqual(len(reports), 1, msg=f"expected one report, got {reports}")
        return reports[0].read_text()

    def shell_commands(self, r):
        return [
            " ".join(c[3:]) for c in r.calls() if c[:3] == ["-s", "test-hu", "shell"]
        ]

    def test_report_has_every_section_and_category(self):
        _, p, reports = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("1. likely safe to disable", p.stdout)
        self.assertIn("report:", p.stdout)

        text = self.report_text(reports)
        for heading in (
            "1. likely safe to disable",
            "2. looks car-critical: verify, probably keep",
            "3. factory or test: never open these",
            "4. who answers HOME / keyboard / accessibility / device admin",
            "5. paste-ready blocks",
        ):
            self.assertIn(heading, text)

        self.assertIn("com.vendor.telemetry", text)
        self.assertIn("telemetry", text)
        self.assertIn("com.vendor.ads", text)
        self.assertIn("ads-promo", text)
        self.assertIn("com.vendor.store", text)
        self.assertIn("store", text)
        self.assertIn("com.vendor.music", text)
        self.assertIn("media-dupe", text)
        self.assertIn("com.android.printspooler", text)
        self.assertIn("known", text)
        self.assertIn("com.vendor.factory", text)
        self.assertIn("com.vendor.rear", text)
        self.assertIn("com.vendor.svc", text)
        self.assertIn("core (never touched): 2", text)

    def test_core_factory_and_other_get_no_dumpsys(self):
        r, p, _ = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        dumps = [
            c[3]
            for c in r.calls()
            if c[:3] == ["-s", "test-hu", "shell"]
            and c[3].startswith("dumpsys package")
        ]
        for pkg in (
            "com.android.systemui",
            "com.vendor.factory",
            "com.example.app",
            "com.google.android.misc",
            "com.vendor.canbus",
        ):
            self.assertNotIn(f"dumpsys package {pkg}", dumps)

    def test_car_name_and_risky_go_to_section_two_with_evidence(self):
        _, p, reports = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        text = self.report_text(reports)
        section2 = text.split("2. looks car-critical", 1)[1].split("3. factory", 1)[0]
        self.assertIn("com.vendor.rear", section2)
        self.assertIn("RearCameraService", section2)
        self.assertIn("BOOT_COMPLETED", section2)
        self.assertIn("risk: persistent", section2)
        self.assertIn("com.vendor.pushsvc", section2)
        self.assertIn("com.vendor.svc", section2)
        self.assertIn("verify by hand", section2)

        section1 = text.split("1. likely safe to disable", 1)[1].split("2. looks", 1)[0]
        self.assertNotIn("com.vendor.rear", section1)
        self.assertNotIn("com.vendor.pushsvc", section1)

    def test_factory_section_and_never_core_are_not_suggested(self):
        _, p, reports = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        text = self.report_text(reports)
        factory = text.split("3. factory or test", 1)[1].split("4. who answers", 1)[0]
        self.assertIn("com.vendor.factory", factory)
        self.assertIn("never open", factory)
        section1 = text.split("1. likely safe to disable", 1)[1].split("2. looks", 1)[0]
        self.assertNotIn("com.android.systemui", section1)
        self.assertNotIn("com.vendor.canbus", section1)

    def test_paste_ready_blocks_are_commented(self):
        _, p, reports = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        text = self.report_text(reports)
        self.assertIn("# data/profiles/fixture-unit/packages.txt", text)
        self.assertIn("# com.vendor.telemetry 1 # telemetry", text)
        self.assertIn("# data/profiles/fixture-unit/never-disable.txt", text)
        self.assertIn("# com.vendor.rear # car-name", text)

    def test_disabled_state_and_launcher_icon_are_recorded(self):
        _, p, reports = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        text = self.report_text(reports)
        self.assertIn("disabled", text)
        self.assertIn("launcher icon: yes (1)", text)
        self.assertIn("com.vendor.ads", text)

    def test_who_answers_home_and_keyboard(self):
        _, p, reports = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        text = self.report_text(reports)
        who = text.split("4. who answers", 1)[1].split("5. paste-ready", 1)[0]
        self.assertIn("com.vendor.launcher/.Main", who)
        self.assertIn("com.android.inputmethod.latin/.LatinIME", who)
        self.assertIn("(none)", who)

    def test_discover_changes_nothing(self):
        r, p, _ = self.run_discover()
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
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
                    forbidden, cmd, msg=f"discover changed the unit: {cmd}"
                )

    def test_screens_captures_and_removes_the_device_file(self):
        r, p, reports = self.run_discover("--screens")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        shots = list((Path(r.tmp.name) / "report").glob("screen-*.png"))
        self.assertEqual(1, len(shots))
        self.assertIn(
            "screencap -p /data/local/tmp/headroom-screen.png",
            self.shell_commands(r),
        )
        self.assertIn("/data/local/tmp/headroom-screen.png", r.state()["removed"])
        self.assertIn("screenshot:", self.report_text(reports))

    def test_screens_dry_run_touches_nothing(self):
        r, p, reports = self.run_discover("--screens", "--dry-run")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("would capture", p.stderr)
        self.assertEqual([], list((Path(r.tmp.name) / "report").glob("screen-*.png")))
        commands = self.shell_commands(r)
        self.assertFalse(any(c.startswith("screencap") for c in commands))
        self.report_text(reports)

    def test_labels_reads_the_apk_label_and_deletes_the_temp_files(self):
        r, p, reports = self.run_discover("--labels")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        text = self.report_text(reports)
        self.assertIn("label: Label for com.vendor.telemetry", text)
        pulled = [x for x in r.state().get("pulled", []) if x.endswith(".apk")]
        self.assertTrue(pulled)
        self.assertTrue(any(x.endswith("com.vendor.telemetry.apk") for x in pulled))
        for path in pulled:
            self.assertFalse(
                Path(path).exists(), msg=f"temporary APK left behind: {path}"
            )

    def test_labels_skip_apks_over_50_mb(self):
        path = "/system/app/com.vendor.telemetry/base.apk"
        r = Run(
            state={
                "installed": INSTALLED,
                "disabled": ["com.vendor.ads"],
                "third": ["com.example.app"],
                "dumpsys": DUMPSYS,
                "apk_sizes": {path: 60 * 1024 * 1024},
            },
            profile="fixture-unit",
        )
        self.runs.append(r)
        p = r("discover.sh", "--labels")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("skipping com.vendor.telemetry", p.stderr)
        self.assertFalse(
            any(
                x.endswith("com.vendor.telemetry.apk")
                for x in r.state().get("pulled", [])
            )
        )

    def test_labels_without_aapt2_falls_back_to_package_names(self):
        r, p, reports = self.run_discover(
            "--labels", env={"AAPT2": "/nonexistent/aapt2"}
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("needs aapt2", p.stderr)
        self.assertEqual([], r.state().get("pulled", []))
        self.assertNotIn("label:", self.report_text(reports))

    def test_screens_and_labels_do_not_change_packages_or_settings(self):
        r, p, _ = self.run_discover("--screens", "--labels")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        for cmd in self.shell_commands(r):
            for forbidden in (
                "pm disable-user",
                "pm enable",
                "settings put",
                "settings delete",
                "pm install",
                "pm uninstall",
            ):
                self.assertNotIn(
                    forbidden, cmd, msg=f"discover changed the unit: {cmd}"
                )


if __name__ == "__main__":
    unittest.main()
