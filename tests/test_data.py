import re
import unittest
from pathlib import Path

from helpers import ROOT

PKG = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
DATA_ROOTS = [ROOT / "data", ROOT / "tests/fixtures/data"]


def entries(path):
    """Strip comments and blank lines exactly as lib.sh's list_of does."""
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].rstrip()
        if line.strip():
            out.append(line)
    return out


class DataTest(unittest.TestCase):
    def profiles(self, base):
        return sorted(p for p in (base / "profiles").iterdir() if p.is_dir())

    def test_package_names_are_valid(self):
        for base in DATA_ROOTS:
            files = [base / "common/never-disable.txt", base / "common/candidates.txt"]
            files += [p / "packages.txt" for p in self.profiles(base)]
            for f in files:
                for line in entries(f):
                    pkg = line.split()[0]
                    self.assertRegex(pkg, PKG, msg=f"{f}: bad package name {pkg!r}")

    def test_apps_txt_maps_names_to_valid_packages(self):
        for base in DATA_ROOTS:
            for line in entries(base / "common/apps.txt"):
                parts = re.split(r"\s{2,}", line.strip())
                self.assertGreaterEqual(
                    len(parts), 2, msg=f"bad apps.txt line: {line!r}"
                )
                self.assertRegex(parts[1], PKG, msg=f"bad apps.txt package: {line!r}")

    def test_sensitive_permissions_are_android_permissions(self):
        for base in DATA_ROOTS:
            for line in entries(base / "common/sensitive-permissions.txt"):
                self.assertTrue(
                    line.split()[0].startswith("android.permission."),
                    msg=f"bad permission line: {line!r}",
                )

    def test_regex_files_compile_and_are_lowercase(self):
        for base in DATA_ROOTS:
            for name in ("never-patterns.txt", "sensitive-patterns.txt"):
                for pat in entries(base / "common" / name):
                    self.assertEqual(
                        pat, pat.lower(), msg=f"{name}: uppercase pattern {pat!r}"
                    )
                    try:
                        re.compile(pat)
                    except re.error as e:
                        self.fail(f"{name}: invalid regex {pat!r}: {e}")

    def test_profile_package_is_never_in_a_never_list_or_pattern(self):
        for base in DATA_ROOTS:
            patterns = entries(base / "common/never-patterns.txt")
            for profile in self.profiles(base):
                never = set(entries(base / "common/never-disable.txt"))
                never.update(entries(profile / "never-disable.txt"))
                for line in entries(profile / "packages.txt"):
                    pkg = line.split()[0]
                    self.assertNotIn(
                        pkg, never, msg=f"{profile.name}: {pkg} is also never-disable"
                    )
                    for pat in patterns:
                        self.assertIsNone(
                            re.search(pat, pkg),
                            msg=f"{profile.name}: {pkg} matches never pattern {pat!r}",
                        )

    def test_packages_have_a_tier_and_evidence(self):
        for base in DATA_ROOTS:
            for profile in self.profiles(base):
                for raw in (profile / "packages.txt").read_text().splitlines():
                    if not raw.strip() or raw.lstrip().startswith("#"):
                        continue
                    line, _, comment = raw.partition("#")
                    parts = line.split()
                    self.assertGreaterEqual(
                        len(parts), 2, msg=f"{profile.name}: missing tier: {raw!r}"
                    )
                    self.assertIn(
                        parts[1],
                        ("1", "2", "3"),
                        msg=f"{profile.name}: bad tier: {raw!r}",
                    )
                    self.assertTrue(
                        comment.strip(),
                        msg=f"{profile.name}: no evidence comment: {raw!r}",
                    )

    def test_packages_start_with_a_header(self):
        for base in DATA_ROOTS:
            for profile in self.profiles(base):
                text = (profile / "packages.txt").read_text().splitlines()
                self.assertTrue(
                    text and text[0].startswith("#"),
                    msg=f"{profile.name}: packages.txt needs a header comment",
                )
                if profile.name != "generic":
                    self.assertIn(
                        "build",
                        text[0].lower(),
                        msg=f"{profile.name}: header should name the build",
                    )

    def test_no_duplicates_within_a_file(self):
        for base in DATA_ROOTS:
            files = [base / "common/never-disable.txt", base / "common/candidates.txt"]
            files += [p / "packages.txt" for p in self.profiles(base)]
            for f in files:
                lines = entries(f)
                pkgs = [line.split()[0] for line in lines]
                self.assertEqual(
                    len(pkgs), len(set(pkgs)), msg=f"{f}: duplicate entries"
                )

    def test_every_real_profile_is_complete(self):
        for base in DATA_ROOTS:
            for profile in self.profiles(base):
                self.assertTrue(
                    (profile / "README.md").exists(),
                    msg=f"{profile.name}: missing README.md",
                )
                if profile.name != "generic":
                    self.assertTrue(
                        (profile / "match.txt").exists(),
                        msg=f"{profile.name}: missing match.txt",
                    )

    def test_match_txt_uses_known_rules(self):
        for base in DATA_ROOTS:
            for profile in self.profiles(base):
                m = profile / "match.txt"
                if not m.exists():
                    continue
                for line in entries(m):
                    parts = line.split(None, 1)
                    self.assertEqual(len(parts), 2, msg=f"{m}: bad line {line!r}")
                    self.assertIn(
                        parts[0], ("prop", "pkg"), msg=f"{m}: bad rule {line!r}"
                    )
                    if parts[0] == "prop":
                        self.assertIn("=", parts[1], msg=f"{m}: prop needs name=glob")
                    else:
                        self.assertRegex(
                            parts[1], PKG, msg=f"{m}: bad package {parts[1]!r}"
                        )


if __name__ == "__main__":
    unittest.main()
