import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from helpers import ROOT

LAUNCHER = ROOT / "launcher"
APP = LAUNCHER / "app"
ANDROID = "{http://schemas.android.com/apk/res/android}"

PURE_JAVA = ("App", "ConfigCodec", "DockModel", "GridMath", "AppOrder")


class LauncherStaticTest(unittest.TestCase):
    """The acceptance budget, checked without Gradle or an Android SDK."""

    def manifest(self):
        return ET.parse(APP / "src/main/AndroidManifest.xml").getroot()

    def build_gradle(self):
        return (APP / "build.gradle").read_text()

    def test_manifest_requests_no_permissions(self):
        root = self.manifest()
        self.assertEqual([], root.findall("uses-permission"))
        self.assertEqual([], root.findall("uses-permission-sdk-23"))

    def test_no_background_components(self):
        root = self.manifest()
        for tag in ("service", "receiver", "provider"):
            self.assertEqual([], root.findall(".//" + tag), msg=tag)

    def test_home_activity_is_exported_and_answers_home(self):
        application = self.manifest().find("application")
        activities = {
            activity.get(ANDROID + "name"): activity
            for activity in application.findall("activity")
        }
        home = activities[".HomeActivity"]
        self.assertEqual("true", home.get(ANDROID + "exported"))
        categories = [
            category.get(ANDROID + "name")
            for intent_filter in home.findall("intent-filter")
            for category in intent_filter.findall("category")
        ]
        self.assertIn("android.intent.category.HOME", categories)
        self.assertIn("android.intent.category.LAUNCHER", categories)

    def test_other_activities_are_not_exported(self):
        application = self.manifest().find("application")
        for activity in application.findall("activity"):
            if activity.get(ANDROID + "name") != ".HomeActivity":
                self.assertEqual("false", activity.get(ANDROID + "exported"))

    def test_sdk_floor_and_target(self):
        text = self.build_gradle()
        self.assertRegex(text, r"minSdk\s+26")
        self.assertRegex(text, r"targetSdk\s+34")
        self.assertRegex(text, r"compileSdk\s+34")

    def test_no_runtime_dependencies(self):
        text = self.build_gradle()
        self.assertIsNone(re.search(r"(?m)^\s*implementation\s", text))
        self.assertIn("testImplementation 'junit:junit:4.13.2'", text)

    def test_pure_java_does_not_import_android(self):
        for name in PURE_JAVA:
            path = APP / "src/main/java/app/headroom/home" / f"{name}.java"
            text = path.read_text()
            self.assertNotIn("import android.", text, msg=name)

    def test_dock_default_is_built_from_the_local_properties(self):
        text = self.build_gradle()
        self.assertIn("resValue 'string', 'default_dock'", text)
        self.assertIn("headroom.local.properties", text)

    def test_touch_target_constant_is_the_cars_guidance(self):
        text = (APP / "src/main/java/app/headroom/home/GridMath.java").read_text()
        self.assertIn("MIN_TOUCH_DP = 76", text)


if __name__ == "__main__":
    unittest.main()
