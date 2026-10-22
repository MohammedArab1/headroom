#!/usr/bin/env python3
"""Validate catalog entries against catalog/schema.json and the privacy rules.

Usage: python3 catalog/validate.py [FILE ...]

With no arguments it checks catalog/devices/*.yaml except _template.yaml.
Requires PyYAML: python3 -m pip install pyyaml.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "catalog" / "schema.json"
DEVICES = ROOT / "catalog" / "devices"

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
MAC = re.compile(r"\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")
VIN = re.compile(
    r"\b(?=[A-HJ-NPR-Z0-9]{17}\b)(?=[^\s]*\d)(?=[^\s]*[A-HJ-NPR-Z])"
    r"[A-HJ-NPR-Z0-9]{17}\b"
)
GPS = re.compile(r"-?\d{1,2}\.\d{4,},\s*-?\d{1,3}\.\d{4,}")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
PROFILE = re.compile(r"[A-Za-z0-9._-]+")


def check(value, schema, path, problems):
    """A small subset of JSON Schema: the keywords schema.json actually uses."""
    if not isinstance(schema, dict):
        return
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {value!r} is not one of {schema['enum']}")
        return
    kind = schema.get("type")
    if kind == "object":
        if not isinstance(value, dict):
            problems.append(f"{path}: expected an object")
            return
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path}: missing required key '{key}'")
        properties = schema.get("properties", {})
        extra = schema.get("additionalProperties")
        for key, sub in value.items():
            if key in properties:
                check(sub, properties[key], f"{path}.{key}", problems)
            elif isinstance(extra, dict):
                check(sub, extra, f"{path}.{key}", problems)
    elif kind == "array":
        if not isinstance(value, list):
            problems.append(f"{path}: expected a list")
            return
        for index, item in enumerate(value):
            check(item, schema.get("items", {}), f"{path}[{index}]", problems)
    elif kind == "string":
        if not isinstance(value, str):
            problems.append(f"{path}: expected a string")
            return
        if len(value) < schema.get("minLength", 0):
            problems.append(f"{path}: shorter than {schema['minLength']} characters")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            problems.append(f"{path}: does not match {schema['pattern']}")
    elif kind == "integer":
        if not isinstance(value, int) or isinstance(value, bool):
            problems.append(f"{path}: expected an integer")
            return
        if "minimum" in schema and value < schema["minimum"]:
            problems.append(f"{path}: below the minimum {schema['minimum']}")
    elif kind == "boolean":
        if not isinstance(value, bool):
            problems.append(f"{path}: expected true or false")


def privacy_problems(path, text):
    found = []
    for label, pattern in (
        ("an IP address", IPV4),
        ("a MAC address", MAC),
        ("a possible VIN", VIN),
        ("GPS coordinates", GPS),
        ("an e-mail address", EMAIL),
    ):
        if pattern.search(text):
            found.append(
                f"{path}: contains {label}; identifiers never go into the catalog"
            )
    return found


def validate_file(path, schema, seen_ids):
    problems = []
    if not path.is_file():
        return [f"{path}: no such file"]
    text = path.read_text(encoding="utf-8")
    try:
        import yaml

        data = yaml.safe_load(text)
    except Exception as exc:  # a parse error is a problem, not a crash
        return [f"{path}: cannot parse YAML: {exc}"]
    if not isinstance(data, dict):
        return [f"{path}: the root must be a mapping"]

    check(data, schema, path.name, problems)
    problems.extend(privacy_problems(path, text))

    ident = data.get("id")
    if isinstance(ident, str):
        if ident != path.stem:
            problems.append(f"{path}: id {ident!r} does not match the file name")
        if ident in seen_ids:
            problems.append(f"{path}: duplicate id {ident!r}")
        seen_ids.add(ident)

    profile = data.get("profile")
    if isinstance(profile, str):
        if not PROFILE.fullmatch(profile) or profile in (".", ".."):
            problems.append(f"{path}: invalid profile name {profile!r}")
        elif not (ROOT / "data" / "profiles" / profile).is_dir():
            problems.append(f"{path}: profile {profile!r} is not under data/profiles/")

    if data.get("status") == "tested":
        checks = data.get("car_checks")
        if not isinstance(checks, dict) or not checks:
            problems.append(
                f"{path}: status 'tested' needs at least one recorded car check"
            )
        else:
            for name, result in checks.items():
                if result not in ("pass", "n/a"):
                    problems.append(
                        f"{path}: status 'tested' but car check {name!r} is {result!r}"
                    )
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "files", nargs="*", help="YAML entries; default: catalog/devices"
    )
    args = parser.parse_args(argv)

    try:
        import yaml  # noqa: F401
    except ImportError:
        print(
            "catalog/validate.py needs PyYAML: python3 -m pip install pyyaml",
            file=sys.stderr,
        )
        return 2

    if args.files:
        paths = [Path(name) for name in args.files]
    else:
        paths = sorted(
            path for path in DEVICES.glob("*.yaml") if path.name != "_template.yaml"
        )
    if not paths:
        print("catalog: no device entries yet")
        return 0

    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    seen_ids = set()
    problems = []
    for path in paths:
        problems.extend(validate_file(path, schema, seen_ids))
    if problems:
        for problem in problems:
            print(problem)
        return 1
    print(f"catalog: {len(paths)} entr{'y' if len(paths) == 1 else 'ies'} valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
