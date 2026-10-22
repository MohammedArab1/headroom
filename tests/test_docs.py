import re
import subprocess
import unittest
from pathlib import Path

from helpers import ROOT

DOC_GLOBS = ["*.md", "docs/*.md", "launcher/README.md", "skills/*/SKILL.md"]
SCRIPT = re.compile(r"scripts/([a-z0-9-]+\.sh)\b")
FLAG = re.compile(r"(?<![\w-])(--[a-z][a-z0-9-]*|-y)(?=[\s,.)`=]|$)")


def doc_files():
    for pattern in DOC_GLOBS:
        for path in ROOT.glob(pattern):
            # The local plan is git-ignored and is not part of the shipped docs.
            if path.name == "headroom-plan.md":
                continue
            yield path


def commands(text):
    """Yield (script name, flag) for each script segment in a Markdown file."""
    for line in text.splitlines():
        for segment in re.split(r"&&|\|\||[;|]", line):
            starts = list(SCRIPT.finditer(segment))
            for index, match in enumerate(starts):
                end = (
                    starts[index + 1].start()
                    if index + 1 < len(starts)
                    else len(segment)
                )
                rest = segment[match.end() : end].split("#", 1)[0]
                for flag in FLAG.findall(rest):
                    yield match.group(1), flag


class DocsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.help = {}

    def help_text(self, name):
        if name not in self.help:
            path = ROOT / "scripts" / name
            self.assertTrue(path.exists(), msg=f"the docs mention missing {path}")
            p = subprocess.run(
                ["/bin/bash", str(path), "--help"],
                text=True,
                capture_output=True,
                timeout=20,
            )
            self.help[name] = p.stdout + p.stderr
        return self.help[name]

    def test_documented_flags_appear_in_the_script_help(self):
        seen = set()
        for path in doc_files():
            for name, flag in commands(path.read_text()):
                seen.add((name, flag))
                self.assertIn(
                    flag,
                    self.help_text(name),
                    msg=f"{path.relative_to(ROOT)} documents {name} {flag}, "
                    f"but `{name} --help` does not list it",
                )
        self.assertTrue(seen, msg="no script commands found in the docs")

    def test_every_documented_script_exists(self):
        for path in doc_files():
            for name, _flag in commands(path.read_text()):
                self.assertTrue(
                    (ROOT / "scripts" / name).is_file(),
                    msg=f"{path.relative_to(ROOT)} mentions missing scripts/{name}",
                )


if __name__ == "__main__":
    unittest.main()
