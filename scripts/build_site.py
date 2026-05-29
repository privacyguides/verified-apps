#!/usr/bin/env python3
"""Build the Verified Apps browse site from data.yml."""

from __future__ import annotations

import html
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DATA_FILE = ROOT / "data.yml"
SITE_SRC = ROOT / "site"
SITE_OUT = ROOT / "_site"
GITHUB_REPO = "privacyguides/verified-apps"
ISSUE_URL = f"https://github.com/{GITHUB_REPO}/issues/{{issue}}"


def normalize_fingerprint(fp: str) -> list[str]:
    """Return one or more colon-separated fingerprint lines."""
    lines = [line.strip() for line in fp.strip().splitlines() if line.strip()]
    return lines or [fp.strip()]


def appverifier_text(package: str, fingerprint: str) -> str:
    lines = [package, *normalize_fingerprint(fingerprint)]
    return "\n".join(lines)


def collect_issues(sources: list[dict]) -> list[int]:
    seen: set[int] = set()
    issues: list[int] = []
    for source in sources:
        issue = source.get("issue")
        if issue is not None and issue not in seen:
            seen.add(issue)
            issues.append(int(issue))
    return issues


def build_rows(data: dict) -> list[dict]:
    rows: list[dict] = []
    for pkg in data.get("packages", []):
        package = pkg["package"]
        for sig in pkg.get("signature", []):
            fingerprint = sig["fingerprint"]
            sources = sig.get("sources", [])
            source_entries = [
                {
                    "name": s["name"],
                    "sha256": (s.get("apk") or {}).get("sha256"),
                }
                for s in sources
                if s["name"] != "AppVerifier"
            ]
            rows.append(
                {
                    "package": package,
                    "appverifier": appverifier_text(package, fingerprint),
                    "fingerprints": normalize_fingerprint(fingerprint),
                    "source_entries": source_entries,
                    "issues": collect_issues(sources),
                    "search": " ".join(
                        [
                            package,
                            " ".join(normalize_fingerprint(fingerprint)),
                            " ".join(e["name"] for e in source_entries),
                            " ".join(
                                e["sha256"] for e in source_entries if e["sha256"]
                            ),
                        ]
                    ).lower(),
                }
            )
    rows.sort(key=lambda r: r["package"].lower())
    return rows


def render_rows(rows: list[dict]) -> str:
    parts: list[str] = []
    for row in rows:
        av_display = html.escape(row["appverifier"])
        copy_source = av_display

        source_items = []
        for entry in row["source_entries"]:
            name = html.escape(entry["name"])
            sha = entry.get("sha256")
            if sha:
                source_items.append(
                    f'<li><span class="source-name">{name}</span> — '
                    f'<code class="source-hash">{html.escape(sha)}</code></li>'
                )
            else:
                source_items.append(f'<li>{name}</li>')
        sources_html = (
            '<ul class="source-list">' + "".join(source_items) + "</ul>"
            if source_items
            else "—"
        )

        issue_items = []
        for issue in row["issues"]:
            url = html.escape(ISSUE_URL.format(issue=issue), quote=True)
            issue_items.append(
                f'<a href="{url}" rel="noopener noreferrer">#{issue}</a>'
            )
        issues_html = ", ".join(issue_items) if issue_items else "—"

        parts.append(
            f"""<tr data-search="{html.escape(row["search"], quote=True)}">
  <td class="appverifier-cell">
    <div class="appverifier-block" tabindex="0" title="Click to select all">
      <pre class="appverifier-text">{av_display}</pre>
    </div>
    <textarea class="copy-source" readonly hidden aria-hidden="true">{copy_source}</textarea>
    <button type="button" class="copy-btn" aria-label="Copy AppVerifier entry for {html.escape(row["package"])}">Copy</button>
  </td>
  <td class="issues-cell">{issues_html}</td>
  <td class="sources-cell">{sources_html}</td>
</tr>"""
        )
    return "\n".join(parts)


def main() -> None:
    with DATA_FILE.open(encoding="utf-8") as f:
        data = yaml.safe_load(f)

    rows = build_rows(data)
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    css_version = datetime.now(timezone.utc).strftime("%Y%m%d%H%M")

    template = (SITE_SRC / "index.html").read_text(encoding="utf-8")
    html_out = (
        template.replace("__ROWS__", render_rows(rows))
        .replace("__ROW_COUNT__", str(len(rows)))
        .replace("__SCHEMA__", str(data.get("schema", "")))
        .replace("__GENERATED_AT__", generated_at)
        .replace("__CSS_VERSION__", css_version)
        .replace("__GITHUB_REPO__", GITHUB_REPO)
    )

    if SITE_OUT.exists():
        shutil.rmtree(SITE_OUT)
    SITE_OUT.mkdir(parents=True)
    (SITE_OUT / "index.html").write_text(html_out, encoding="utf-8")
    shutil.copy2(SITE_SRC / "style.css", SITE_OUT / "style.css")

    meta = {
        "schema": data.get("schema"),
        "generated_at": generated_at,
        "row_count": len(rows),
    }
    (SITE_OUT / "meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )

    print(f"Built {len(rows)} rows into {SITE_OUT}")


if __name__ == "__main__":
    main()
