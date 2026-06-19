#!/usr/bin/env python3
"""Compare GrapheneOS forum hash exports against data.yml and file missing submissions."""

from __future__ import annotations

import argparse
import json
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

# parse_forum_hashes lives in the submission lookup action.
_LOOKUP_DIR = Path(__file__).resolve().parents[1] / "actions" / "lookup-grapheneos-forum"
sys.path.insert(0, str(_LOOKUP_DIR))
from lookup import parse_forum_hashes  # noqa: E402


def find_missing_entries(
    forum_packages: dict[str, list[str]],
    data_packages: dict[str, list[str]],
) -> list[dict[str, object]]:
    missing: list[dict[str, object]] = []

    for package_name in sorted(forum_packages):
        forum_fps = forum_packages[package_name]
        data_blocks = data_packages.get(package_name, [])
        uncovered: list[str] = []

        for forum_fp in forum_fps:
            if any(fingerprint_covered(forum_fp, block) for block in data_blocks):
                continue
            uncovered.append(forum_fp)

        if uncovered:
            missing.append({"package": package_name, "fingerprints": uncovered})

    return missing


def format_issue_title(package_name: str) -> str:
    leaf = package_name.rsplit(".", 1)[-1]
    if not leaf:
        leaf = package_name
    return f"[New]: {leaf[0].upper()}{leaf[1:]}"


def format_issue_body(
    package_name: str,
    fingerprints: list[str],
    *,
    hashes_url: str,
) -> str:
    verification = "\n".join([package_name, *fingerprints])
    return (
        f"{VERIFICATION_HEADER}\n\n"
        f"```text\n{verification}\n```\n\n"
        "### Direct download link\n\n"
        "_No response_\n\n"
        "### Custom F-Droid Repository\n\n"
        "_No response_\n\n"
        "### Signing key citation\n\n"
        f"GrapheneOS forum submissions export: {hashes_url}\n\n"
        "### Submitted app source\n\n"
        "Other\n\n"
        "### Verifying app\n\n"
        "Other\n\n"
        "### Verifying app source\n\n"
        "Other download source"
    )


def create_issues(
    repo: str,
    entries: list[dict[str, object]],
    *,
    hashes_url: str,
    dry_run: bool,
    max_issues: int = 0,
) -> list[dict[str, object]]:
    created: list[dict[str, object]] = []
    filed = 0

    for entry in entries:
        if max_issues > 0 and filed >= max_issues:
            print(
                f"Reached --max-issues limit ({max_issues}); "
                "remaining packages were not filed.",
                file=sys.stderr,
            )
            break

        package_name = str(entry["package"])
        fingerprints = [str(fp) for fp in entry["fingerprints"]]
        if submission_already_open(repo, package_name, fingerprints):
            print(
                f"skip {package_name}: open issue already lists the same fingerprint(s)",
                file=sys.stderr,
            )
            continue

        title = format_issue_title(package_name)
        body = format_issue_body(
            package_name, fingerprints, hashes_url=hashes_url
        )

        if dry_run:
            print(f"dry-run issue: {title}", file=sys.stderr)
            created.append(
                {
                    "package": package_name,
                    "fingerprints": fingerprints,
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
                    "Import GOS",
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
                "title": title,
                "url": url,
            }
        )

        filed += 1

    return created


def cmd_compare(args: argparse.Namespace) -> int:
    forum_text = Path(args.hashes_file).read_text(encoding="utf-8")
    forum_packages = parse_forum_hashes(forum_text)
    data_packages = load_data_yml_fingerprints(Path(args.data_yml))
    missing = find_missing_entries(forum_packages, data_packages)

    Path(args.output).write_text(
        json.dumps(missing, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"forum packages: {len(forum_packages)}, missing submissions: {len(missing)}",
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
        hashes_url=args.hashes_url,
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
    compare.add_argument("--hashes-file", required=True)
    compare.add_argument("--data-yml", required=True)
    compare.add_argument("--output", required=True)
    compare.set_defaults(func=cmd_compare)

    create = subparsers.add_parser("create-issues")
    create.add_argument("--missing-file", required=True)
    create.add_argument("--repo", required=True)
    create.add_argument("--hashes-url", required=True)
    create.add_argument("--dry-run", action="store_true")
    create.add_argument(
        "--max-issues",
        type=int,
        default=0,
        help=(
            "Stop after filing this many eligible packages (0 = no limit). "
            "Packages skipped because an open issue already exists do not count."
        ),
    )
    create.add_argument("--report")
    create.set_defaults(func=cmd_create_issues)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
