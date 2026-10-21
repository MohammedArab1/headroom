#!/usr/bin/env python3
"""Compare two benchmark JSON files and say which direction each metric moved."""

import argparse
import json
import sys

HIGHER_IS_BETTER = {"mem_available_kb", "data_free_kb"}
CONTEXT_ONLY = {"disabled_packages"}
SKIP = {"label", "date", "runs", "sdk"}


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def percent(before, after):
    if not is_number(before) or not is_number(after):
        return "-"
    if before == 0:
        return "n/a"
    return f"{(after - before) / before * 100:+.1f}%"


def verdict(key, before, after):
    if not is_number(before) or not is_number(after):
        return "missing"
    if key in CONTEXT_ONLY:
        return "context"
    if before == after:
        return "same"
    higher = key in HIGHER_IS_BETTER
    better = (after > before) if higher else (after < before)
    return "better" if better else "worse"


def rows(before, after):
    for key in sorted(set(before) | set(after)):
        if key in SKIP:
            continue
        b, a = before.get(key), after.get(key)
        yield key, b, a, percent(b, a), verdict(key, b, a)


def render(before, after):
    lines = [f"{'metric':<28} {'before':>10} {'after':>10} {'change':>9}  verdict"]
    for key, b, a, change, result in rows(before, after):
        bs = "-" if b is None else str(b)
        as_ = "-" if a is None else str(a)
        lines.append(f"{key:<28} {bs:>10} {as_:>10} {change:>9}  {result}")
    return "\n".join(lines)


def load(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("the JSON root must be an object")
    return data


def main(argv):
    parser = argparse.ArgumentParser(
        description="Compare two benchmark JSON files (before, then after)."
    )
    parser.add_argument("before")
    parser.add_argument("after")
    args = parser.parse_args(argv)
    try:
        before = load(args.before)
        after = load(args.after)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(render(before, after))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
