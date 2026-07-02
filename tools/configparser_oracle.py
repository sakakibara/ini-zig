#!/usr/bin/env python3
"""Differential oracle: parse a generic INI fixture with Python configparser
and print the normalized form to stdout.

Output format mirrors tools/differential.zig:
  sorted `path = escaped_value` lines, one per leaf.
  Special chars escaped: backslash -> \\\\, newline -> \\n, tab -> \\t.

Alignment with the generic dialect:
- Keys are lowercased (configparser default; matches case_insensitive_keys=true).
- Section names are lowercased in the path (matches case_insensitive_sections).
- Duplicate keys: last-wins via strict=False (matches duplicate_keys=last_wins).
- Global keys (before any section) are NOT supported by configparser; when the
  fixture requires them the script prints a warning to stderr and exits 0 so
  the caller can skip or note the divergence explicitly.

Usage: configparser_oracle.py <fixture_file>
Exit 0 on success or graceful skip, non-zero on unexpected errors.
Prints nothing and exits 0 when called with --skip-check (CI portability).
"""

import configparser
import sys
import os


def escape_value(s: str) -> str:
    """Escape special chars for normalized output."""
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--skip-check":
        return 0
    if len(sys.argv) != 2:
        print("usage: configparser_oracle.py <fixture_file>", file=sys.stderr)
        return 1

    fixture = sys.argv[1]
    if not os.path.exists(fixture):
        print(f"file not found: {fixture}", file=sys.stderr)
        return 1

    # strict=False: allow duplicate keys (last-wins, matching generic dialect).
    # Default optionxform lowercases keys (matching case_insensitive_keys=true).
    cfg = configparser.RawConfigParser(strict=False)

    try:
        with open(fixture, encoding="utf-8") as fh:
            cfg.read_file(fh)
    except configparser.MissingSectionHeaderError:
        # configparser does not support global keys (keys before any section).
        # Graceful skip: note the divergence and exit 0 so the harness can
        # record it rather than treating it as a tool failure.
        print(
            f"SKIP: {fixture}: global keys before section not supported by configparser",
            file=sys.stderr,
        )
        return 0
    except configparser.Error as exc:
        print(f"parse error: {exc}", file=sys.stderr)
        return 2

    pairs = []

    # configparser makes DEFAULT section keys available in every section;
    # collect them as top-level globals (path = key).
    defaults = dict(cfg.defaults())
    for key, val in defaults.items():
        pairs.append((key, escape_value(val)))

    for section in cfg.sections():
        # Lower-case the section name to match case_insensitive_sections.
        sec_lower = section.lower()
        for key in cfg.options(section):
            if key in defaults:
                # Skip keys inherited from DEFAULTSECT to avoid duplication.
                continue
            val = cfg.get(section, key)
            path = f"{sec_lower}.{key}"
            pairs.append((path, escape_value(val)))

    pairs.sort(key=lambda pv: pv[0])
    for path, val in pairs:
        print(f"{path} = {val}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
