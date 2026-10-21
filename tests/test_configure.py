import subprocess
import unittest
from pathlib import Path

from helpers import Run

FIELDS = (
    "KEEP_APPS",
    "REMOVE_APPS",
    "ALLOW_RISKY",
    "TIER1",
    "TIER2",
    "SIM",
    "UPDATER_KEEP",
    "ANIM_SCALE",
    "DEXOPT",
    "TRIM_CACHES",
    "SCAN_OFF",
    "BG_RESTRICT",
    "PRIVATE_DNS",
    "PRIVATE_DNS_HOST",
    "LAUNCHER",
    "DOCK_APPS",
    "BENCH_APPS",
)

BASE_INSTALLED = [
    "com.android.stk",
    "com.google.android.apps.maps",
    "com.vendor.ads",
    "com.vendor.music",
    "com.vendor.telemetry",
    "com.waze",
]


def conf_values(path):
    script = 'source "$1" || exit 1; printf "%s\\n" ' + " ".join(
        f'"${f}"' for f in FIELDS
    )
    p = subprocess.run(
        ["/bin/bash", "-c", script, "_", str(path)], text=True, capture_output=True
    )
    assert p.returncode == 0, p.stderr
    return dict(zip(FIELDS, p.stdout.splitlines()))


class ConfigureTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def run_configure(self, *args, state=None, conf=""):
        state = dict(state or {})
        state.setdefault("installed", BASE_INSTALLED)
        state.setdefault("third", ["com.waze"])
        r = Run(state=state, conf=conf, profile="fixture-unit")
        self.runs.append(r)
        return r, r("configure.sh", *args)

    def test_flags_write_the_exact_file(self):
        r, p = self.run_configure(
            "--keep",
            "Google Maps,com.vendor.music",
            "--remove",
            "com.vendor.ads",
            "--tier1",
            "0",
            "--tier2",
            "0",
            "--sim",
            "1",
            "--updater-keep",
            "0",
            "--anim",
            "1",
            "--dexopt",
            "0",
            "--scan-off",
            "0",
            "--trim-caches",
            "1",
            "--bg-restrict",
            "com.vendor.ads",
            "--private-dns",
            "dns.example.org",
            "--launcher",
            "0",
            "--dock",
            "com.waze,com.vendor.music",
            "--bench-apps",
            "com.waze",
            "--allow-risky",
            "com.vendor.telemetry",
        )
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertTrue(Path(r.conf).exists())
        values = conf_values(r.conf)
        self.assertEqual(
            values["KEEP_APPS"],
            "com.google.android.apps.maps com.vendor.music com.android.stk",
        )
        self.assertEqual(values["REMOVE_APPS"], "com.vendor.ads")
        self.assertEqual(values["ALLOW_RISKY"], "com.vendor.telemetry")
        self.assertEqual(values["TIER1"], "0")
        self.assertEqual(values["TIER2"], "0")
        self.assertEqual(values["SIM"], "1")
        self.assertEqual(values["UPDATER_KEEP"], "0")
        self.assertEqual(values["ANIM_SCALE"], "1")
        self.assertEqual(values["DEXOPT"], "0")
        self.assertEqual(values["SCAN_OFF"], "0")
        self.assertEqual(values["TRIM_CACHES"], "1")
        self.assertEqual(values["BG_RESTRICT"], "com.vendor.ads")
        self.assertEqual(values["PRIVATE_DNS"], "1")
        self.assertEqual(values["PRIVATE_DNS_HOST"], "dns.example.org")
        self.assertEqual(values["LAUNCHER"], "0")
        self.assertEqual(values["DOCK_APPS"], "com.waze com.vendor.music")
        self.assertEqual(values["BENCH_APPS"], "com.waze")
        self.assertIn("# Written by scripts/configure.sh", Path(r.conf).read_text())

    def test_keep_accepts_an_apps_txt_name(self):
        r, p = self.run_configure("--keep", "Google Maps")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertEqual(
            conf_values(r.conf)["KEEP_APPS"], "com.google.android.apps.maps"
        )

    def test_keep_refuses_an_unknown_name(self):
        _, p = self.run_configure("--keep", "Nope App")
        self.assertEqual(p.returncode, 1)
        self.assertIn("matched nothing", p.stderr)

    def test_keep_refuses_a_package_that_is_not_installed(self):
        _, p = self.run_configure("--keep", "com.vendor.notinstalled")
        self.assertEqual(p.returncode, 1)
        self.assertIn("is not installed", p.stderr)

    def test_invalid_animation_scale_dies(self):
        _, p = self.run_configure("--anim", "2")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--anim must be 0, 0.5 or 1", p.stderr)

    def test_invalid_tier_value_dies(self):
        _, p = self.run_configure("--tier1", "2")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--tier1 must be 0 or 1", p.stderr)

    def test_invalid_private_dns_host_dies(self):
        _, p = self.run_configure("--private-dns", "not-a-host")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--private-dns needs a host", p.stderr)

    def test_dry_run_writes_nothing(self):
        r, p = self.run_configure("--dry-run", "--tier1", "0")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("# Written by scripts/configure.sh", p.stdout)
        self.assertIn("TIER1=0", p.stdout)
        self.assertEqual(Path(r.conf).read_text(), "")

    def test_no_flags_without_a_tty_stops(self):
        _, p = self.run_configure()
        self.assertEqual(p.returncode, 1)
        self.assertIn("not a terminal", p.stderr)

    def test_existing_conf_is_kept_by_y(self):
        conf = (
            "KEEP_APPS=com.vendor.music\n"
            "REMOVE_APPS=''\n"
            "ALLOW_RISKY=''\n"
            "TIER1=0\nTIER2=0\nSIM=0\nUPDATER_KEEP=0\n"
            "ANIM_SCALE=1\nDEXOPT=0\nTRIM_CACHES=1\nSCAN_OFF=0\n"
            "BG_RESTRICT=''\nPRIVATE_DNS=1\nPRIVATE_DNS_HOST=dns.example.org\n"
            "LAUNCHER=0\nDOCK_APPS=com.waze\nBENCH_APPS=com.waze\n"
        )
        r, p = self.run_configure("-y", conf=conf)
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        values = conf_values(r.conf)
        self.assertEqual(values["TIER1"], "0")
        self.assertEqual(values["TIER2"], "0")
        self.assertEqual(values["UPDATER_KEEP"], "0")
        self.assertEqual(values["ANIM_SCALE"], "1")
        self.assertEqual(values["TRIM_CACHES"], "1")
        self.assertEqual(values["PRIVATE_DNS"], "1")
        self.assertEqual(values["PRIVATE_DNS_HOST"], "dns.example.org")
        self.assertEqual(values["LAUNCHER"], "0")
        self.assertEqual(values["KEEP_APPS"], "com.vendor.music")
        self.assertEqual(values["BENCH_APPS"], "com.waze")

    def test_bench_apps_must_be_third_party(self):
        _, p = self.run_configure("--bench-apps", "com.vendor.music")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not third-party", p.stderr)


if __name__ == "__main__":
    unittest.main()
