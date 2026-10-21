"""Run a script from scripts/ against tests/fake_adb.py. No head unit, no network."""

import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BASE_STATE = {
    "serial": "test-hu",
    "props": {
        "sys.boot_completed": "1",
        "ro.build.version.sdk": "33",
        "ro.serialno": "x",
        "ro.product.model": "Test Unit",
        "ro.adb.secure": "1",
    },
    "installed": [],
    "disabled": [],
    "third": [],
    "refuse": [],
    "home": "com.vendor.launcher/.Main",
    "settings": {
        "secure default_input_method": "com.android.inputmethod.latin/.LatinIME",
        "secure android_id": "abc",
    },
}


class Run:
    def __init__(
        self,
        state=None,
        conf="",
        profile="generic",
        data=ROOT / "tests/fixtures/data",
        preset_serial=True,
    ):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.state_file, self.log = t / "state.json", t / "calls.jsonl"
        s = json.loads(json.dumps(BASE_STATE))
        for k, v in (
            state or {}
        ).items():  # deep-merge one level: passing props keeps boot_completed
            if isinstance(v, dict) and isinstance(s.get(k), dict):
                s[k].update(v)
            else:
                s[k] = v
        self.state_file.write_text(json.dumps(s))
        self.conf = t / "headroom.conf"
        self.conf.write_text(conf)
        self.home = t / "state-root"
        self.profile, self.data, self.preset_serial = profile, data, preset_serial

    def env(self):
        env = dict(
            os.environ,
            ADB=str(ROOT / "tests/fake_adb.py"),
            SERIAL="test-hu",
            CONF=str(self.conf),
            HEADROOM_STATE=str(self.home),
            REBOOT_SETTLE="0",
            POLL="0",
            SETTLE="0",
            HOME_WAIT="0",
            COLD_SLEEP="0",
            FAKE_ADB_STATE=str(self.state_file),
            FAKE_ADB_LOG=str(self.log),
            PROFILE=self.profile,
            HEADROOM_DATA=str(self.data),
            HEADROOM_REPORT=str(Path(self.tmp.name) / "report"),
        )
        if not self.preset_serial:
            env.pop("SERIAL")
            env.pop("ADB_SERIAL", None)
        return env

    def __call__(self, script, *args, stdin=""):
        # /bin/bash on purpose: on macOS it is bash 3.2, the version the scripts must support.
        return subprocess.run(
            ["/bin/bash", str(ROOT / "scripts" / script), *args],
            env=self.env(),
            input=stdin,
            text=True,
            capture_output=True,
        )

    def bash(self, snippet):
        """Source scripts/lib.sh, then run snippet. Same fake device state as __call__."""
        return subprocess.run(
            ["/bin/bash", "-c", f'source "{ROOT}/scripts/lib.sh"; {snippet}'],
            env=self.env(),
            text=True,
            capture_output=True,
        )

    def state(self):
        return json.loads(self.state_file.read_text())

    def calls(self):
        return (
            [json.loads(l) for l in self.log.read_text().splitlines()]
            if self.log.exists()
            else []
        )
