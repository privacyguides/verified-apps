#!/usr/bin/env bash
#
# Find "Add <package> from <issue>" commits that REMOVED entries.
#
# Submission commits are supposed to be purely additive. A stale-snapshot race (since fixed)
# could make one commit revert package/domain entries that landed concurrently. Committing an
# old whole-file snapshot over a main that had advanced. This script walks every matching
# commit and reports the ones whose append-only data files LOST lines, and precisely which
# package (data.yml) or domain (data-verified-domains.yml) entries disappeared vs the parent.
#
# Usage:
#   scripts/audit_additive_commits.sh [git-range] [subject-regex]
#
#   git-range       What to scan (default: HEAD = full history reachable from HEAD).
#   subject-regex   Bash ERE the commit SUBJECT must match
#                   (default: '^Add .+ from (GH|CB)-[0-9]+$').
#                   Domain-verification commits use a different subject; to audit those too:
#                     scripts/audit_additive_commits.sh HEAD '^(Add|Verify) .+ from (GH|CB)-[0-9]+'
#
# Output: one block per flagged commit, oldest first —
#   <committer-date>  <short-sha>  +<added>/-<deleted>  <subject>
#       removed package: <id>            (entries gone from data.yml)
#       removed domain:  <domain>        (entries gone from data-verified-domains.yml)
# followed by a summary. Exit status is 1 when any commit removed entries, else 0.

set -u

RANGE="${1:-HEAD}"
SUBJECT_RE="${2:-^Add .+ from (GH|CB)-[0-9]+$}"
DATA_FILE="data.yml"
DOMAINS_FILE="data-verified-domains.yml"

cd "$(git rev-parse --show-toplevel)"

# Sorted, unique entry keys ("  - <key>: <value>") in <file> at <rev>; empty if file absent.
entries_at() {  # $1 rev  $2 file  $3 key
  git show "${1}:${2}" 2>/dev/null | sed -n "s/^  - ${3}: //p" | sort -u
}

scanned=0 matched=0 flagged=0 entry_removals=0

emit() {  # flush the just-parsed commit (globals: cur_hash/cur_date/cur_subj/add/del)
  [[ -z "${cur_hash:-}" ]] && return 0
  scanned=$((scanned + 1))
  [[ "$cur_subj" =~ $SUBJECT_RE ]] || return 0
  matched=$((matched + 1))
  [[ "${del:-0}" -gt 0 ]] || return 0
  flagged=$((flagged + 1))

  local parent rp="" rd=""
  parent=$(git rev-parse --verify --quiet "${cur_hash}^") || parent=""
  if [[ -n "$parent" ]]; then
    rp=$(comm -23 <(entries_at "$parent" "$DATA_FILE" package) \
                  <(entries_at "$cur_hash" "$DATA_FILE" package) 2>/dev/null || true)
    rd=$(comm -23 <(entries_at "$parent" "$DOMAINS_FILE" domain) \
                  <(entries_at "$cur_hash" "$DOMAINS_FILE" domain) 2>/dev/null || true)
  fi
  [[ -n "${rp}${rd}" ]] && entry_removals=$((entry_removals + 1))

  printf '%s  %s  +%s/-%s  %s\n' \
    "$cur_date" "${cur_hash:0:12}" "${add:-0}" "${del:-0}" "$cur_subj"
  while IFS= read -r p; do [[ -n "$p" ]] && printf '      removed package: %s\n' "$p"; done <<< "$rp"
  while IFS= read -r d; do [[ -n "$d" ]] && printf '      removed domain:  %s\n' "$d"; done <<< "$rd"
  if [[ -z "${rp}${rd}" ]]; then
    printf '      (lines deleted but no whole entry removed — likely a reverted source or a\n'
    printf '       reformat; inspect with: git show %s)\n' "$cur_hash"
  fi
}

cur_hash="" cur_date="" cur_subj="" add=0 del=0
while IFS= read -r line; do
  if [[ "$line" == __C__$'\t'* ]]; then
    emit
    IFS=$'\t' read -r _ cur_hash cur_date cur_subj <<< "$line"
    add=0 del=0
  elif [[ -n "$line" ]]; then
    # numstat line: "<added>\t<deleted>\t<file>" (binary files show "-").
    a=${line%%$'\t'*}
    rest=${line#*$'\t'}
    d=${rest%%$'\t'*}
    [[ "$a" =~ ^[0-9]+$ ]] && add=$((add + a))
    [[ "$d" =~ ^[0-9]+$ ]] && del=$((del + d))
  fi
done < <(git log "$RANGE" --reverse --no-merges --numstat \
           --format='__C__%x09%H%x09%cI%x09%s' -- "$DATA_FILE" "$DOMAINS_FILE")
emit  # flush the final commit

echo
printf 'Scanned %d commit(s) touching %s/%s.\n' "$scanned" "$DATA_FILE" "$DOMAINS_FILE"
printf '%d matched "%s".\n' "$matched" "$SUBJECT_RE"
printf '%d of those deleted lines from the data files; %d removed at least one whole entry (package/domain).\n' \
  "$flagged" "$entry_removals"

[[ "$flagged" -eq 0 ]] || exit 1
exit 0
