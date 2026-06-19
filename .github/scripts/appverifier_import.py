#!/usr/bin/env python3
"""Compare AppVerifier internal database entries against data.yml and file missing submissions."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from _import_common import (
    VERIFICATION_HEADER,
    fingerprint_covered,
    load_data_yml_fingerprints,
    submission_already_open,
)

AV_PACKAGE_RE = re.compile(r'^\s*"([a-zA-Z][a-zA-Z0-9_.]+)"\s*,', re.MULTILINE)
AV_HASH_RE = re.compile(r'"([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})"')
AV_SOURCE_RE = re.compile(r"Source\.(\w+)")

SOURCE_TO_APP_SOURCE = {
    "GOOGLE_PLAY_STORE": "Google Play / Aurora Store",
    "GOOGLE_PIXEL_OS": "Other",
    "GITHUB": "GitHub",
    "ACCRESCENT": "Accrescent",
    "CODEBERG": "Codeberg",
    "FDROID": "F-Droid",
    "APP_FDROID_REPO": "F-Droid",
    "WEBSITE": "Developer's Website",
    "GITLAB": "GitLab",
}

SOURCE_DISPLAY = {
    "GOOGLE_PLAY_STORE": "Google Play Store",
    "GOOGLE_PIXEL_OS": "Google Pixel OS",
    "GITHUB": "GitHub",
    "ACCRESCENT": "Accrescent",
    "CODEBERG": "Codeberg",
    "FDROID": "F-Droid",
    "APP_FDROID_REPO": "App F-Droid repo",
    "WEBSITE": "App website",
    "GITLAB": "GitLab",
}

APP_SOURCE_PRIORITY = (
    "GOOGLE_PLAY_STORE",
    "FDROID",
    "APP_FDROID_REPO",
    "GITHUB",
    "GITLAB",
    "CODEBERG",
    "ACCRESCENT",
    "WEBSITE",
    "GOOGLE_PIXEL_OS",
)


def parse_appverifier_database(text: str) -> dict[str, list[dict[str, object]]]:
    packages: dict[str, list[dict[str, object]]] = {}

    for chunk in text.split("InternalDatabaseVerificationInfo(")[1:]:
        package_match = AV_PACKAGE_RE.search(chunk)
        if not package_match:
            continue
        package_name = package_match.group(1)
        configs: list[dict[str, object]] = []
        pos = 0

        while True:
            marker = chunk.find("Hashes(", pos)
            if marker < 0:
                break

            depth = 0
            index = marker
            while index < len(chunk):
                char = chunk[index]
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        block = chunk[marker : index + 1]
                        pos = index + 1
                        break
                index += 1
            else:
                break

            fingerprints = AV_HASH_RE.findall(block)
            sources = AV_SOURCE_RE.findall(block)
            if not fingerprints:
                continue
            configs.append(
                {
                    "fingerprints": [fp.upper() for fp in fingerprints],
                    "sources": sources,
                }
            )

        if configs:
            packages[package_name] = configs

    return packages


def pick_app_source(sources: list[str]) -> str:
    for key in APP_SOURCE_PRIORITY:
        if key in sources:
            return SOURCE_TO_APP_SOURCE[key]
    return "Other"


def format_sources_line(sources: list[str]) -> str:
    labels = [SOURCE_DISPLAY.get(source, source) for source in sources]
    return ", ".join(labels) if labels else "Unknown"


def find_missing_entries(
    appverifier_packages: dict[str, list[dict[str, object]]],
    data_packages: dict[str, list[str]],
) -> list[dict[str, object]]:
    missing: list[dict[str, object]] = []

    for package_name in sorted(appverifier_packages):
        for config in appverifier_packages[package_name]:
            fingerprints = [str(fp) for fp in config["fingerprints"]]
            proposed_block = "\n".join(fingerprints)
            data_blocks = data_packages.get(package_name, [])

            if any(
                fingerprint_covered(proposed_block, block) for block in data_blocks
            ):
                continue

            missing.append(
                {
                    "package": package_name,
                    "fingerprints": fingerprints,
                    "sources": [str(source) for source in config.get("sources", [])],
                }
            )

    return missing


def format_issue_title(package_name: str, sources: list[str]) -> str:
    leaf = package_name.rsplit(".", 1)[-1]
    if not leaf:
        leaf = package_name
    title = f"[New]: {leaf[0].upper()}{leaf[1:]}"
    if sources:
        title += f" ({format_sources_line(sources)})"
    return title


def format_issue_body(
    package_name: str,
    fingerprints: list[str],
    *,
    database_url: str,
    sources: list[str],
) -> str:
    verification = "\n".join([package_name, *fingerprints])
    sources_line = format_sources_line(sources)
    app_source = pick_app_source(sources)
    return (
        f"{VERIFICATION_HEADER}\n\n"
        f"```text\n{verification}\n```\n\n"
        "### Direct download link\n\n"
        "_No response_\n\n"
        "### Custom F-Droid Repository\n\n"
        "_No response_\n\n"
        "### Signing key citation\n\n"
        f"AppVerifier internal database ({database_url}). "
        f"Signing configuration sources in AppVerifier: {sources_line}.\n\n"
        "### Submitted app source\n\n"
        f"{app_source}\n\n"
        "### Verifying app\n\n"
        "AppVerifier (@soupslurpr)\n\n"
        "### Verifying app source\n\n"
        "Other download source"
    )


def create_issues(
    repo: str,
    entries: list[dict[str, object]],
    *,
    database_url: str,
    dry_run: bool,
    max_issues: int = 0,
) -> list[dict[str, object]]:
    created: list[dict[str, object]] = []
    filed = 0

    for entry in entries:
        if max_issues > 0 and filed >= max_issues:
            print(
                f"Reached --max-issues limit ({max_issues}); "
                "remaining entries were not filed.",
                file=sys.stderr,
            )
            break

        package_name = str(entry["package"])
        fingerprints = [str(fp) for fp in entry["fingerprints"]]
        sources = [str(source) for source in entry.get("sources", [])]

        if submission_already_open(repo, package_name, fingerprints):
            print(
                f"skip {package_name}: open issue already lists the same fingerprint(s)",
                file=sys.stderr,
            )
            continue

        title = format_issue_title(package_name, sources)
        body = format_issue_body(
            package_name,
            fingerprints,
            database_url=database_url,
            sources=sources,
        )

        if dry_run:
            print(f"dry-run issue: {title}", file=sys.stderr)
            created.append(
                {
                    "package": package_name,
                    "fingerprints": fingerprints,
                    "sources": sources,
                    "title": title,
                    "dry_run": True,
                }
            )
            filed += 1
            continue

        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".md",
            delete=False,
            encoding="utf-8",
        ) as handle:
            handle.write(body)
            body_path = handle.name

        try:
            url = subprocess.check_output(
                [
                    "gh",
                    "issue",
                    "create",
                    "--repo",
                    repo,
                    "--title",
                    title,
                    "--body-file",
                    body_path,
                    "--label",
                    "Import AppVerifier",
                ],
                text=True,
            ).strip()
        finally:
            Path(body_path).unlink(missing_ok=True)

        print(f"created {url} ({package_name})", file=sys.stderr)
        created.append(
            {
                "package": package_name,
                "fingerprints": fingerprints,
                "sources": sources,
                "title": title,
                "url": url,
            }
        )
        filed += 1

    return created


def cmd_compare(args: argparse.Namespace) -> int:
    database_text = Path(args.database_file).read_text(encoding="utf-8")
    appverifier_packages = parse_appverifier_database(database_text)
    data_packages = load_data_yml_fingerprints(Path(args.data_yml))
    missing = find_missing_entries(appverifier_packages, data_packages)

    Path(args.output).write_text(
        json.dumps(missing, indent=2) + "\n", encoding="utf-8"
    )
    package_count = len(appverifier_packages)
    config_count = sum(len(configs) for configs in appverifier_packages.values())
    print(
        "appverifier packages: "
        f"{package_count}, signing configs: {config_count}, "
        f"missing submissions: {len(missing)}",
        file=sys.stderr,
    )
    return 0


def cmd_create_issues(args: argparse.Namespace) -> int:
    entries = json.loads(Path(args.missing_file).read_text(encoding="utf-8"))
    if not entries:
        print("No missing entries to file.", file=sys.stderr)
        if args.report:
            Path(args.report).write_text("[]\n", encoding="utf-8")
        return 0

    created = create_issues(
        args.repo,
        entries,
        database_url=args.database_url,
        dry_run=args.dry_run,
        max_issues=args.max_issues,
    )
    if args.report:
        Path(args.report).write_text(
            json.dumps(created, indent=2) + "\n", encoding="utf-8"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    compare = subparsers.add_parser("compare")
    compare.add_argument("--database-file", required=True)
    compare.add_argument("--data-yml", required=True)
    compare.add_argument("--output", required=True)
    compare.set_defaults(func=cmd_compare)

    create = subparsers.add_parser("create-issues")
    create.add_argument("--missing-file", required=True)
    create.add_argument("--repo", required=True)
    create.add_argument("--database-url", required=True)
    create.add_argument("--dry-run", action="store_true")
    create.add_argument(
        "--max-issues",
        type=int,
        default=0,
        help=(
            "Stop after filing this many eligible entries (0 = no limit). "
            "Entries skipped because an open issue already exists do not count."
        ),
    )
    create.add_argument("--report")
    create.set_defaults(func=cmd_create_issues)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
