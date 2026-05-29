#!/usr/bin/env python3
"""Delete stale artifact attestations for data.yml, keeping the newest.

Attestations whose subject digest matches a data.yml published on any GitHub
release are never deleted.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

# GitHub API bundle_url may be a blob path (.../YYYY/MM/DD/{id}.json.sn) or legacy .../bundle.
ATTESTATION_ID_PATTERNS = (
    re.compile(r"/attestations/(\d+)/bundle(?:\?|$)"),
    re.compile(r"/attestations/\d+/\d{4}/\d{2}/\d{2}/(\d+)\.json(?:\.sn)?(?:\?|$)"),
)
BULK_BATCH_SIZE = 100
RELEASES_PAGE_SIZE = 100


def subprocess_stream_text(stream: str | bytes | None) -> str:
    if not stream:
        return ""
    if isinstance(stream, str):
        return stream
    return stream.decode("utf-8", errors="replace")


@dataclass(frozen=True)
class AttestationRecord:
    attestation_id: int
    subject_digest: str
    created_at: dt.datetime
    repository_id: int


def sha256_digest(content: bytes) -> str:
    return f"sha256:{hashlib.sha256(content).hexdigest()}"


def run_git(args: list[str], *, cwd: Path, binary: bool = False) -> bytes | str:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
    )
    if binary:
        return result.stdout
    return result.stdout.decode("utf-8")


def collect_data_yml_digests(repo_root: Path) -> list[str]:
    commits = run_git(["log", "--follow", "--format=%H", "--", "data.yml"], cwd=repo_root)
    digests: set[str] = set()

    for commit in commits.splitlines():
        commit = commit.strip()
        if not commit:
            continue
        try:
            blob = run_git(["rev-parse", f"{commit}:data.yml"], cwd=repo_root).strip()
            content = run_git(["cat-file", "blob", blob], cwd=repo_root, binary=True)
        except subprocess.CalledProcessError:
            continue
        digests.add(sha256_digest(content))

    return sorted(digests)


def gh_api_bytes(endpoint: str) -> bytes:
    result = subprocess.run(
        ["gh", "api", endpoint, "-H", "Accept: application/octet-stream"],
        check=True,
        capture_output=True,
    )
    return result.stdout


def collect_release_data_yml_digests(org: str, repo: str) -> set[str]:
    digests: set[str] = set()
    page = 1

    while True:
        releases = gh_api(
            f"repos/{org}/{repo}/releases?per_page={RELEASES_PAGE_SIZE}&page={page}",
        )
        if not isinstance(releases, list) or not releases:
            break

        for release in releases:
            tag_name = release.get("tag_name") or release.get("id")
            for asset in release.get("assets") or []:
                if asset.get("name") != "data.yml":
                    continue
                asset_id = asset.get("id")
                if asset_id is None:
                    continue
                content = gh_api_bytes(
                    f"repos/{org}/{repo}/releases/assets/{asset_id}",
                )
                digest = sha256_digest(content)
                digests.add(digest)
                print(
                    f"  release {tag_name}: data.yml -> {digest}",
                )

        if len(releases) < RELEASES_PAGE_SIZE:
            break
        page += 1

    return digests


def gh_api(
    endpoint: str,
    *,
    method: str = "GET",
    body: dict | None = None,
) -> dict | list:
    command = ["gh", "api", endpoint, "--method", method]
    if body is not None:
        # gh ignores stdin unless --input - is set; otherwise the API gets no body.
        completed = subprocess.run(
            [*command, "--input", "-"],
            input=json.dumps(body),
            text=True,
            check=True,
            capture_output=True,
        )
    else:
        completed = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    if not completed.stdout.strip():
        return {}
    return json.loads(completed.stdout)


def get_repository_id(org: str, repo: str) -> int:
    payload = gh_api(f"repos/{org}/{repo}")
    return int(payload["id"])


def parse_attestation_id(bundle_url: str) -> int | None:
    for pattern in ATTESTATION_ID_PATTERNS:
        match = pattern.search(bundle_url)
        if match:
            return int(match.group(1))
    return None


def parse_created_at(bundle: dict) -> dt.datetime | None:
    verification_material = bundle.get("verificationMaterial") or {}
    tlog_entries = verification_material.get("tlogEntries") or []
    timestamps: list[int] = []
    for entry in tlog_entries:
        raw = entry.get("integratedTime")
        if raw is None:
            continue
        timestamps.append(int(raw))
    if not timestamps:
        return None
    return dt.datetime.fromtimestamp(max(timestamps), tz=dt.timezone.utc)


def iter_bulk_list_entries(payload: dict) -> tuple[str, list[dict]]:
    mapping = payload.get("attestations_subject_digests")
    if isinstance(mapping, dict):
        for digest, entries in mapping.items():
            yield digest, entries or []
        return

    if isinstance(mapping, list):
        for item in mapping:
            if not isinstance(item, dict):
                continue
            for digest, entries in item.items():
                yield digest, entries or []


def fetch_attestations(
    org: str,
    digests: list[str],
    *,
    repo_id: int,
) -> list[AttestationRecord]:
    records: list[AttestationRecord] = []

    for offset in range(0, len(digests), BULK_BATCH_SIZE):
        batch = digests[offset : offset + BULK_BATCH_SIZE]
        after: str | None = None

        while True:
            endpoint = f"orgs/{org}/attestations/bulk-list?per_page=100"
            if after:
                endpoint = f"{endpoint}&after={after}"

            payload = gh_api(
                endpoint,
                method="POST",
                body={"subject_digests": batch},
            )

            for digest, entries in iter_bulk_list_entries(payload):
                for entry in entries:
                    if entry.get("repository_id") != repo_id:
                        continue
                    attestation_id = parse_attestation_id(entry.get("bundle_url", ""))
                    created_at = parse_created_at(entry.get("bundle") or {})
                    if attestation_id is None or created_at is None:
                        continue
                    records.append(
                        AttestationRecord(
                            attestation_id=attestation_id,
                            subject_digest=digest,
                            created_at=created_at,
                            repository_id=repo_id,
                        )
                    )

            page_info = payload.get("page_info") or {}
            if not page_info.get("has_next"):
                break
            after = page_info.get("next")
            if not after:
                break

    records.sort(key=lambda record: record.created_at, reverse=True)
    deduped: dict[int, AttestationRecord] = {}
    for record in records:
        deduped.setdefault(record.attestation_id, record)
    return sorted(deduped.values(), key=lambda record: record.created_at, reverse=True)


def select_deletions(
    records: list[AttestationRecord],
    *,
    max_age_days: int,
    protected_digests: set[str],
    now: dt.datetime | None = None,
) -> tuple[list[AttestationRecord], list[dict[str, object]], int]:
    if not records:
        return [], [], 0

    current = now or dt.datetime.now(tz=dt.timezone.utc)
    cutoff = current - dt.timedelta(days=max_age_days)
    newest = records[0]
    stale = [record for record in records[1:] if record.created_at < cutoff]
    to_delete = [
        record
        for record in stale
        if record.subject_digest not in protected_digests
    ]
    skipped_release = len(stale) - len(to_delete)
    to_delete_ids = {record.attestation_id for record in to_delete}

    kept: list[dict[str, object]] = []
    for record in records:
        if record.attestation_id in to_delete_ids:
            continue
        reasons: list[str] = []
        if record.attestation_id == newest.attestation_id:
            reasons.append("newest")
        if record.subject_digest in protected_digests:
            reasons.append("release")
        if record.created_at >= cutoff:
            reasons.append("within_max_age")
        entry = serialize_record(record)
        entry["reasons"] = reasons
        kept.append(entry)

    return to_delete, kept, skipped_release


def delete_attestation(org: str, attestation_id: int, *, dry_run: bool) -> None:
    if dry_run:
        return
    gh_api(f"orgs/{org}/attestations/{attestation_id}", method="DELETE")


def serialize_record(record: AttestationRecord) -> dict[str, object]:
    payload = asdict(record)
    payload["created_at"] = record.created_at.isoformat()
    return payload


def format_attestation_row(
    record: dict[str, object] | None,
    *,
    with_reason: bool = False,
) -> str:
    if not record:
        if with_reason:
            return "| — | — | — | — |"
        return "| — | — | — |"
    digest = str(record["subject_digest"])
    if len(digest) > 24:
        digest = f"{digest[:21]}..."
    row = (
        f"| `{record['attestation_id']}` "
        f"| `{record['created_at']}` "
        f"| `{digest}` |"
    )
    if with_reason:
        reasons = ", ".join(record.get("reasons") or [])
        row += f" `{reasons or '—'}` |"
    return row


def format_summary_markdown(report: dict[str, object]) -> str:
    org = report["org"]
    repo = report["repo"]
    dry_run = report["dry_run"]
    deleted = report["deleted"]
    action = "Would delete" if dry_run else "Deleted"

    lines = [
        "# Attestation cleanup",
        "",
        "| | |",
        "| --- | --- |",
        f"| Repository | `{org}/{repo}` |",
        f"| Max age | {report['max_age_days']} day(s) |",
        f"| Mode | {'Dry run' if dry_run else 'Live delete'} |",
        f"| Digests scanned | {report['digests_scanned']} |",
        f"| Release data.yml digests (protected) | {report['release_digests']} |",
        f"| Attestations found | {report['attestations_found']} |",
        f"| Kept | {report['kept_count']} |",
        f"| Stale kept (release match) | {report['skipped_for_release']} |",
        "",
        f"## Kept ({report['kept_count']})",
        "",
        "| ID | Created (UTC) | Subject digest | Reason(s) |",
        "| --- | --- | --- | --- |",
    ]

    kept = report["kept"]
    if kept:
        lines.extend(format_attestation_row(record, with_reason=True) for record in kept)
    else:
        lines.append(format_attestation_row(None, with_reason=True))
    lines.append("")

    if deleted:
        lines.extend(
            [
                f"## {action}",
                "",
                "| ID | Created (UTC) | Subject digest |",
                "| --- | --- | --- |",
                *(format_attestation_row(record) for record in deleted),
                "",
            ]
        )
    else:
        lines.extend(["## Result", "", "No stale attestations to delete.", ""])

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Delete stale data.yml attestations while keeping the newest.",
    )
    parser.add_argument("--org", default="privacyguides")
    parser.add_argument("--repo", default="verified-apps")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--max-age-days", type=int, default=7)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--summary",
        type=Path,
        help="Write a Markdown summary to this file (e.g. $GITHUB_STEP_SUMMARY)",
    )
    args = parser.parse_args()

    git_digests = set(collect_data_yml_digests(args.repo_root))
    print(f"Collected {len(git_digests)} unique data.yml digest(s) from git history.")

    print("Collecting data.yml digest(s) from GitHub releases:")
    release_digests = collect_release_data_yml_digests(args.org, args.repo)
    print(
        f"Collected {len(release_digests)} unique data.yml digest(s) from releases "
        "(never deleted)."
    )

    digests = sorted(git_digests | release_digests)

    repo_id = get_repository_id(args.org, args.repo)
    records = fetch_attestations(args.org, digests, repo_id=repo_id)
    print(f"Found {len(records)} attestation(s) for {args.org}/{args.repo}.")

    to_delete, kept, skipped_release = select_deletions(
        records,
        max_age_days=args.max_age_days,
        protected_digests=release_digests,
    )
    if skipped_release:
        print(
            f"Skipping {skipped_release} stale attestation(s) that match "
            "release data.yml digest(s)."
        )

    print(f"Keeping {len(kept)} attestation(s):")
    for entry in kept:
        reasons = ", ".join(entry["reasons"])
        print(
            f"  - id={entry['attestation_id']} "
            f"created={entry['created_at']} "
            f"digest={entry['subject_digest']} "
            f"reasons={reasons}"
        )

    if not to_delete:
        print("No stale attestations to delete.")
    else:
        print(
            f"{'Would delete' if args.dry_run else 'Deleting'} "
            f"{len(to_delete)} attestation(s) older than {args.max_age_days} day(s):"
        )
        for record in to_delete:
            print(
                f"  - id={record.attestation_id} "
                f"created={record.created_at.isoformat()} "
                f"digest={record.subject_digest}"
            )
            delete_attestation(args.org, record.attestation_id, dry_run=args.dry_run)

    report = {
        "org": args.org,
        "repo": args.repo,
        "max_age_days": args.max_age_days,
        "dry_run": args.dry_run,
        "digests_scanned": len(digests),
        "git_digests": len(git_digests),
        "release_digests": len(release_digests),
        "attestations_found": len(records),
        "skipped_for_release": skipped_release,
        "kept_count": len(kept),
        "kept": kept,
        "deleted": [serialize_record(record) for record in to_delete],
    }

    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if args.summary:
        args.summary.write_text(format_summary_markdown(report), encoding="utf-8")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        stderr = subprocess_stream_text(exc.stderr)
        stdout = subprocess_stream_text(exc.stdout)
        print(stderr or stdout or str(exc), file=sys.stderr)
        raise SystemExit(exc.returncode or 1) from exc
