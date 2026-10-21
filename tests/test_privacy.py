import re
import unittest
from pathlib import Path

from helpers import ROOT

TEXT_EXTENSIONS = {
    ".md",
    ".sh",
    ".py",
    ".txt",
    ".yaml",
    ".yml",
    ".json",
    ".xml",
    ".gradle",
    ".java",
    ".properties",
}
TEXT_NAMES = {".gitignore", ".editorconfig", ".shellcheckrc", "pyadb"}
SKIP_DIRS = {".git", "report", "venv", "build", ".gradle", "__pycache__"}

PRIVATE_IP = re.compile(
    r"\b(10\.\d{1,3}|172\.(1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b"
)
MAC = re.compile(r"\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")
VIN = re.compile(
    r"\b(?=[A-HJ-NPR-Z0-9]{17}\b)(?=[^\s]*\d)(?=[^\s]*[A-HJ-NPR-Z])[A-HJ-NPR-Z0-9]{17}\b"
)
GPS = re.compile(r"-?\d{1,2}\.\d{4,},\s*-?\d{1,3}\.\d{4,}")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")


def text_files():
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts[:-1]):
            continue
        if path.suffix in TEXT_EXTENSIONS or path.name in TEXT_NAMES:
            yield path


class PrivacyTest(unittest.TestCase):
    def test_no_private_identifiers(self):
        for path in text_files():
            text = path.read_text(errors="replace")
            rel = path.relative_to(ROOT)
            self.assertIsNone(
                PRIVATE_IP.search(text), msg=f"{rel}: private IPv4 address"
            )
            self.assertIsNone(MAC.search(text), msg=f"{rel}: MAC address")
            self.assertIsNone(VIN.search(text), msg=f"{rel}: possible VIN")
            self.assertIsNone(GPS.search(text), msg=f"{rel}: GPS coordinates")
            if rel.parts[0] in ("catalog", "data"):
                self.assertIsNone(EMAIL.search(text), msg=f"{rel}: e-mail address")

    def test_gitignore_keeps_device_data_out(self):
        text = (ROOT / ".gitignore").read_text()
        for entry in ("headroom.conf", "report/*", "tools/adbkey/", "*.keystore"):
            self.assertIn(entry, text)


if __name__ == "__main__":
    unittest.main()
