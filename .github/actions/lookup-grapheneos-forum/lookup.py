#!/usr/bin/env python3
"""Parse the GrapheneOS forum submissions export. Imported by the import scripts."""

from __future__ import annotations

import re

FULL_HASH_RE = re.compile(r"^([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})$")
PACKAGE_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$")


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
