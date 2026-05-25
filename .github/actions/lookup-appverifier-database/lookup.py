#!/usr/bin/env python3
"""Extract package fingerprints from AppVerifier's InternalVerificationInfoDatabase.kt."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


HASH_FIND_RE = re.compile(r"([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})")
FULL_HASH_RE = re.compile(r"^([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})$")
SOURCE_RE = re.compile(r"Source\.([A-Z_]+)")
ENTRY_SPLIT_RE = re.compile(r"InternalDatabaseVerificationInfo\(")
HASHES_BLOCK_RE = re.compile(
    r"Hashes\(\s*listOf\(\s*(.*?)\s*\),\s*listOf\(\s*(.*?)\s*\),\s*(?:true|false)\s*\)",
    re.DOTALL,
)


def format_sources(sources: list[str]) -> str:
    labels = {
        "GOOGLE_PLAY_STORE": "Google Play Store",
        "GOOGLE_PIXEL_OS": "Google Pixel OS",
        "GITHUB": "GitHub",
        "ACCRESCENT": "Accrescent",
        "CODEBERG": "Codeberg",
        "FDROID": "F-Droid",
        "APP_FDROID_REPO": "App's F-Droid Repo",
        "WEBSITE": "App's Website",
        "GITLAB": "GitLab",
    }
    return ", ".join(labels.get(source, source.replace("_", " ").title()) for source in sources)


def parse_hashes_blocks(entry_text: str) -> list[dict]:
    blocks: list[dict] = []
    for sources_raw, hashes_raw in HASHES_BLOCK_RE.findall(entry_text):
        sources = SOURCE_RE.findall(sources_raw)
        hashes = [value.upper() for value in HASH_FIND_RE.findall(hashes_raw)]
        if hashes:
            blocks.append({"sources": sources, "hashes": hashes})
    return blocks


def find_package_entry(database_text: str, package_name: str) -> str | None:
    for chunk in ENTRY_SPLIT_RE.split(database_text)[1:]:
        package_match = re.match(r'\s*"([^"]+)"', chunk)
        if package_match and package_match.group(1) == package_name:
            return chunk
    return None


def write_github_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as handle:
        if "\n" in value:
            handle.write(f"{name}<<EOF\n{value}\nEOF\n")
        else:
            handle.write(f"{name}={value}\n")


def normalize_signature_set(text: str) -> list[str]:
    values: list[str] = []
    for token in re.split(r"\s+", text.strip()):
        token = token.strip()
        if FULL_HASH_RE.fullmatch(token):
            values.append(token.upper())
    for line in text.splitlines():
        line = line.strip()
        if FULL_HASH_RE.fullmatch(line):
            values.append(line.upper())
    return sorted(set(values))


def signature_sets_equal(left: str, right: str) -> bool:
    return normalize_signature_set(left) == normalize_signature_set(right)


def choose_block(blocks: list[dict], user_signature: str) -> dict:
    if user_signature.strip():
        for block in blocks:
            block_text = "\n".join(block["hashes"])
            if signature_sets_equal(block_text, user_signature):
                return block
    return blocks[0]


def main() -> int:
    if len(sys.argv) not in {3, 4}:
        print("usage: lookup.py <database.kt> <packageName> [userSignature]", file=sys.stderr)
        return 2

    database_path = Path(sys.argv[1])
    package_name = sys.argv[2]
    user_signature = sys.argv[3] if len(sys.argv) == 4 else ""
    database_text = database_path.read_text(encoding="utf-8")

    entry = find_package_entry(database_text, package_name)
    if entry is None:
        write_github_output("found", "false")
        write_github_output("signature", "")
        write_github_output("sources", "")
        write_github_output(
            "infoNote",
            ":information_source: **AppVerifier:** this package is not in AppVerifier's "
            "[internal verification database](https://github.com/soupslurpr/AppVerifier/blob/main/app/src/main/kotlin/dev/soupslurpr/appverifier/InternalVerificationInfoDatabase.kt).",
        )
        return 0

    blocks = parse_hashes_blocks(entry)
    if not blocks:
        write_github_output("found", "false")
        write_github_output("signature", "")
        write_github_output("sources", "")
        write_github_output(
            "infoNote",
            ":warning: **AppVerifier:** this package is listed in AppVerifier's internal database, "
            "but no fingerprints could be parsed from the current file format.",
        )
        return 0

    write_github_output("found", "true")
    block = choose_block(blocks, user_signature)
    signature = "\n".join(block["hashes"])
    sources = format_sources(block["sources"])
    write_github_output("signature", signature)
    write_github_output("sources", sources)

    if len(blocks) > 1:
        if user_signature.strip() and signature_sets_equal(signature, user_signature):
            note = (
                ":information_source: **AppVerifier:** this package has multiple signing "
                f"configurations in AppVerifier's internal database; matched entry sources: {sources}."
            )
        else:
            note = (
                ":information_source: **AppVerifier:** this package has multiple signing "
                f"configurations in AppVerifier's internal database; comparing against ({sources})."
            )
        write_github_output("infoNote", note)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
