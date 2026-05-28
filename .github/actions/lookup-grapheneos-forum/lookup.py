#!/usr/bin/env python3
"""Look up package fingerprints from the GrapheneOS forum submissions export."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

FULL_HASH_RE = re.compile(r"^([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})$")
PACKAGE_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$")


def write_github_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as handle:
        if "\n" not in value:
            handle.write(f"{name}={value}\n")
            return
        delimiter = "GHA_DELIM"
        while delimiter in value:
            delimiter = f"GHA_DELIM_{os.getpid()}_{id(value)}"
        handle.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")


def normalize_signature_set(text: str) -> set[str]:
    values: set[str] = set()
    for token in re.split(r"\s+", text.strip()):
        token = token.strip()
        if FULL_HASH_RE.fullmatch(token):
            values.add(token.upper())
    for line in text.splitlines():
        line = line.strip()
        if FULL_HASH_RE.fullmatch(line):
            values.add(line.upper())
    return values


def signatures_equal(left: str, right: str) -> bool:
    return normalize_signature_set(left) == normalize_signature_set(right)


def signatures_overlap(left: str, right: str) -> bool:
    return bool(normalize_signature_set(left) & normalize_signature_set(right))


def parse_forum_hashes(text: str) -> dict[str, list[str]]:
    packages: dict[str, list[str]] = {}
    current_pkg: str | None = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if FULL_HASH_RE.fullmatch(line):
            if current_pkg is not None:
                packages.setdefault(current_pkg, []).append(line.upper())
            continue
        if PACKAGE_RE.fullmatch(line):
            current_pkg = line
            packages.setdefault(current_pkg, [])
            continue

    return packages


def match_status(user_signature: str, forum_fingerprints: list[str]) -> str:
    block = "\n".join(forum_fingerprints)
    if signatures_equal(user_signature, block):
        return ":white_check_mark:"
    if signatures_overlap(user_signature, block):
        return ":white_check_mark:"
    return ":x:"


def main() -> int:
    if len(sys.argv) not in {3, 4}:
        print(
            "usage: lookup.py <hashes.txt> <packageName> [userSignature]",
            file=sys.stderr,
        )
        return 2

    hashes_path = Path(sys.argv[1])
    package_name = sys.argv[2]
    user_signature = sys.argv[3] if len(sys.argv) == 4 else ""
    source_label = os.environ.get("SOURCE_LABEL", "")

    text = hashes_path.read_text(encoding="utf-8")
    packages = parse_forum_hashes(text)
    fingerprints = packages.get(package_name)

    write_github_output("found", "false")
    write_github_output("signature", "")
    write_github_output("match", "")
    write_github_output("packageName", package_name)
    write_github_output("infoNote", "")
    write_github_output("sourceLabel", source_label)

    if not fingerprints:
        return 0

    write_github_output("found", "true")
    write_github_output("signature", "\n".join(fingerprints))
    write_github_output("match", match_status(user_signature, fingerprints))

    if len(fingerprints) > 1:
        note = (
            ":information_source: **GrapheneOS forum:** this package has "
            f"{len(fingerprints)} signing certificate(s) in the forum submissions export."
        )
        if source_label:
            note += f" Source: `{source_label}`."
        note += " This check is informational only and is not used when updating `data.yml`."
        write_github_output("infoNote", note)
    elif source_label:
        write_github_output(
            "infoNote",
            ":information_source: **GrapheneOS forum:** matched against the community "
            f"submissions export (`{source_label}`). This check is informational only and "
            "is not used when updating `data.yml`.",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
