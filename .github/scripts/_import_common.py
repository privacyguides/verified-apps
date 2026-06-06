#!/usr/bin/env python3
"""Shared helpers for the AppVerifier and GrapheneOS forum import scripts."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

# Reuse parsing and fingerprint helpers from the submission lookup action.
_LOOKUP_DIR = Path(__file__).resolve().parents[1] / "actions" / "lookup-grapheneos-forum"
sys.path.insert(0, str(_LOOKUP_DIR))
from lookup import signatures_equal, signatures_overlap  # noqa: E402

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    raise SystemExit("PyYAML is required (install pyyaml)") from exc

VERIFICATION_HEADER = "### Verification Info"
FULL_HASH_RE = re.compile(r"^([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})$")
PACKAGE_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$")


def fingerprint_covered(proposed_block: str, data_fingerprint: str) -> bool:
    return signatures_equal(proposed_block, data_fingerprint) or signatures_overlap(
        proposed_block, data_fingerprint
    )


def load_data_yml_fingerprints(path: Path) -> dict[str, list[str]]:
    with path.open(encoding="utf-8") as handle:
        document = yaml.safe_load(handle)

    packages: dict[str, list[str]] = {}
    for entry in document.get("packages") or []:
        package_name = entry.get("package")
        if not isinstance(package_name, str) or not package_name:
            continue
        for signature in entry.get("signature") or []:
            fingerprint = signature.get("fingerprint")
            if isinstance(fingerprint, str) and fingerprint.strip():
                packages.setdefault(package_name, []).append(fingerprint)
    return packages


def parse_issue_verification(body: str) -> tuple[str | None, list[str]]:
    if VERIFICATION_HEADER not in body:
        return None, []

    section = body.split(VERIFICATION_HEADER, 1)[1]
    section = section.split("###", 1)[0]
    lines: list[str] = []
    in_fence = False
    for raw_line in section.splitlines():
        line = raw_line.strip()
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence and not line:
            continue
        lines.append(line)

    if not lines:
        return None, []

    package_name = lines[0]
    fingerprints = [line for line in lines[1:] if FULL_HASH_RE.fullmatch(line)]
    if not PACKAGE_RE.fullmatch(package_name):
        return None, fingerprints
    return package_name, fingerprints


def submission_already_open(
    repo: str,
    package_name: str,
    fingerprints: list[str],
) -> bool:
    proposed = "\n".join(fingerprints)
    search = f'"{package_name}" in:body is:issue is:open'
    result = subprocess.run(
        [
            "gh",
            "issue",
            "list",
            "--repo",
            repo,
            "--search",
            search,
            "--json",
            "number,body",
            "--limit",
            "50",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    issues = json.loads(result.stdout or "[]")
    for issue in issues:
        body = issue.get("body") or ""
        existing_package, existing_fps = parse_issue_verification(body)
        if existing_package != package_name:
            continue
        if signatures_equal(proposed, "\n".join(existing_fps)):
            return True
    return False
