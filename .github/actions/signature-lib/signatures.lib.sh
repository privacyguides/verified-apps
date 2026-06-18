# Shared helpers for colon-separated SHA-256 certificate fingerprints.
# Sourced by composite actions: source "${GITHUB_ACTION_PATH}/signatures.lib.sh"
# or sibling actions: source "${GITHUB_ACTION_PATH}/../signature-lib/signatures.lib.sh"

# Write a potentially multiline value to GITHUB_OUTPUT without leaving a half-open heredoc.
gha_write_multiline_output() {
  local name="$1"
  local value="${2-}"
  local delim

  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

  if [[ "$value" != *$'\n'* ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
    return 0
  fi

  delim="GHA_DELIM_${RANDOM}_${RANDOM}"
  while [[ "$value" == *"$delim"* ]]; do
    delim="GHA_DELIM_${RANDOM}_${RANDOM}"
  done
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$GITHUB_OUTPUT"
}

# Canonical data.yml issue ref for a GitHub issue number (GH-123).
signatures_github_issue_ref() {
  local number="$1"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf 'GH-%s' "$number"
}

# Parse a GitHub issue number from a ref (GH-123 or legacy bare 123).
signatures_github_issue_number() {
  local ref="$1"
  if [[ "$ref" =~ ^GH-([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    printf '%s' "$ref"
  else
    return 1
  fi
}

# Normalize legacy or canonical GitHub issue refs to GH-123 for storage/display.
signatures_normalize_github_issue_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^GH-[0-9]+$ ]]; then
    printf '%s' "$ref"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    signatures_github_issue_ref "$ref"
  else
    return 1
  fi
}

# True when data.yml uses a supported schema version.
signatures_data_schema_supported() {
  case "$1" in
    3|4) return 0 ;;
    *) return 1 ;;
  esac
}

# data.yml source names for a key vouched for by the package's verified domain. The
# method (https/dns) determines the label so the database records how the domain was
# proven. Defined here (the lower-level lib) so both domains.lib.sh and the submission
# entry builder can reach them without a circular source.
DOMAIN_SOURCE_NAME_HTTPS="HTTPS Verified Domain"
DOMAIN_SOURCE_NAME_DNS="DNS Verified Domain"
domain_source_name() {
  case "$1" in
    https) printf '%s' "$DOMAIN_SOURCE_NAME_HTTPS" ;;
    dns) printf '%s' "$DOMAIN_SOURCE_NAME_DNS" ;;
    *) printf 'Verified Domain' ;;
  esac
}

# Canonical Codeberg issue ref for data.yml and commit messages (CB-123).
signatures_codeberg_issue_ref() {
  local number="$1"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf 'CB-%s' "$number"
}

# Parse Codeberg issue number from CB-123 (or legacy bare 123).
signatures_codeberg_issue_number() {
  local ref="$1"
  if [[ "$ref" =~ ^CB-([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# Parse ### Submission Source from a GitHub issue body.
# Sets SUBMISSION_EXTERNAL_REF (e.g. CB-123) on success.
signatures_parse_submission_source() {
  local body="$1"
  local section line external

  section=$(printf '%s\n' "$body" | awk '
    $0 == "### Submission Source" { found=1; next }
    found && /^### / { exit }
    found { print }
  ')

  external=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[Ee]xternal:[[:space:]]*(.+)$ ]]; then
      external="${BASH_REMATCH[1]}"
      break
    fi
  done <<< "$section"

  external=$(printf '%s' "$external" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [[ "$external" =~ ^CB-[0-9]+$ ]] || return 1
  SUBMISSION_EXTERNAL_REF="$external"
  return 0
}

# Issue ref for data.yml / "from …" lines: External ref when present, else GH-N.
signatures_submission_issue_ref() {
  local github_issue_number="$1"
  local issue_body="$2"

  if signatures_parse_submission_source "$issue_body"; then
    printf '%s' "$SUBMISSION_EXTERNAL_REF"
    return 0
  fi

  signatures_github_issue_ref "$github_issue_number"
}

# Author login of a Codeberg issue via the Forgejo API.
codeberg_get_issue_author() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local issue_index="$4"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local response http_code response_body login

  [[ -n "$token" && "$issue_index" =~ ^[0-9]+$ ]] || return 1

  response=$(curl -sS -w '\n%{http_code}' \
    -H "Authorization: token ${token}" \
    -H "Accept: application/json" \
    "${api_base}/repos/${owner}/${repo}/issues/${issue_index}") || return 1

  http_code=$(printf '%s' "$response" | tail -n 1)
  response_body=$(printf '%s' "$response" | sed '$d')
  [[ "$http_code" == "200" ]] || return 1

  login=$(jq -r '.user.login // .user.username // empty' <<< "$response_body")
  [[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$login"
}

# Codeberg submitter login for a GitHub issue mirrored from Codeberg (### Submission Source:
# External: CB-N), resolved live via the Forgejo API so it is never stored on the GitHub issue.
# Fails (non-zero, no output) when the submission is not from Codeberg or the lookup fails.
signatures_codeberg_submission_author() {
  local token="$1"
  local github_issue_body="$2"
  local owner="${CODEBERG_REPO_OWNER:-privacyguides}"
  local repo="${CODEBERG_REPO_NAME:-verified-apps}"
  local cb_issue_num

  [[ -n "$token" ]] || return 1
  signatures_parse_submission_source "$github_issue_body" || return 1
  cb_issue_num=$(signatures_codeberg_issue_number "$SUBMISSION_EXTERNAL_REF") || return 1
  codeberg_get_issue_author "$token" "$owner" "$repo" "$cb_issue_num"
}

# Hidden marker identifying the single bot-managed "rolling status" comment on a Codeberg
# issue. HTML comments are stripped by the Forgejo markdown renderer, so it is invisible to
# readers but lets us find (and edit) our comment without knowing the bot's login.
codeberg_status_marker() { printf '<!-- pg-mirror:v1 -->'; }

# Perform a Codeberg/Forgejo API request with retry + backoff on rate-limit (HTTP 429),
# transient server errors (5xx) and network failures. Honors the Retry-After response
# header when present, otherwise backs off exponentially (2,4,8…s). Each sleep is capped at
# CODEBERG_RETRY_CAP (default 60s) so a job never blocks on the full rate-limit window; once
# CODEBERG_MAX_RETRIES (default 5) is exhausted the last response is returned and the caller
# decides how to report it (the daily reconciliation backfills anything still missing).
# Usage: codeberg_api_call <token> <method> <url> [data_file]
# Echoes the response body followed by a final line containing the HTTP status code, matching
# the curl `-w '\n%{http_code}'` contract used by the callers (tail -n1 = code, sed '$d' = body).
codeberg_api_call() {
  local token="$1"
  local method="$2"
  local url="$3"
  local data_file="${4:-}"
  local max_retries="${CODEBERG_MAX_RETRIES:-5}"
  local retry_cap="${CODEBERG_RETRY_CAP:-60}"
  local attempt=0 http_code response_body header_file response retry_after delay
  local curl_args

  while :; do
    header_file=$(mktemp)
    curl_args=(-sS -D "$header_file" -w '\n%{http_code}' -X "$method"
      -H "Authorization: token ${token}"
      -H "Accept: application/json")
    if [[ -n "$data_file" ]]; then
      curl_args+=(-H "Content-Type: application/json" --data-binary @"$data_file")
    fi

    if response=$(curl "${curl_args[@]}" "$url"); then
      http_code=$(printf '%s' "$response" | tail -n 1)
      response_body=$(printf '%s' "$response" | sed '$d')
    else
      http_code="000"
      response_body=""
    fi

    if [[ "$http_code" == "429" || "$http_code" == "000" || "$http_code" =~ ^5[0-9][0-9]$ ]] \
       && (( attempt < max_retries )); then
      retry_after=$(grep -i '^Retry-After:' "$header_file" 2>/dev/null | tail -n 1 | tr -dc '0-9')
      if [[ "$retry_after" =~ ^[0-9]+$ ]] && (( retry_after > 0 )); then
        delay="$retry_after"
      else
        delay=$(( 2 ** attempt ))
        (( delay < 2 )) && delay=2
      fi
      (( delay > retry_cap )) && delay="$retry_cap"
      rm -f "$header_file"
      attempt=$((attempt + 1))
      echo "Codeberg API ${method} ${url##*/} -> HTTP ${http_code}; retry ${attempt}/${max_retries} in ${delay}s" >&2
      sleep "$delay"
      continue
    fi

    rm -f "$header_file"
    printf '%s\n%s' "$response_body" "$http_code"
    return 0
  done
}

# List every comment on a Codeberg issue (paginated) as a single JSON array.
codeberg_list_issue_comments() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local issue_index="$4"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local page=1 limit=50 response http_code page_json count combined='[]'

  [[ -n "$token" && "$issue_index" =~ ^[0-9]+$ ]] || return 1

  while :; do
    response=$(codeberg_api_call "$token" GET \
      "${api_base}/repos/${owner}/${repo}/issues/${issue_index}/comments?limit=${limit}&page=${page}")
    http_code=$(printf '%s' "$response" | tail -n 1)
    page_json=$(printf '%s' "$response" | sed '$d')
    [[ "$http_code" == "200" ]] || return 1
    jq -e 'type == "array"' >/dev/null 2>&1 <<< "$page_json" || return 1
    count=$(jq 'length' <<< "$page_json")
    (( count > 0 )) || break
    combined=$(jq -c --argjson acc "$combined" '$acc + .' <<< "$page_json")
    (( count < limit )) && break
    page=$((page + 1))
  done

  printf '%s' "$combined"
}

# Id of the bot-managed rolling status comment (marker match) in a comments JSON array, or
# empty when none exists yet.
codeberg_find_status_comment_id() {
  local comments_json="$1"
  local marker
  marker=$(codeberg_status_marker)
  jq -r --arg m "$marker" \
    'map(select((.body // "") | contains($m))) | (.[0].id // empty)' <<< "$comments_json"
}

# Edit an existing Codeberg issue comment via the Forgejo API (not rate-limited like creates).
codeberg_edit_issue_comment() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local comment_id="$4"
  local body="$5"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local payload_file response http_code response_body

  [[ -n "$token" && "$comment_id" =~ ^[0-9]+$ ]] || return 1

  payload_file=$(mktemp)
  jq -n --arg body "$body" '{body: $body}' > "$payload_file"

  response=$(codeberg_api_call "$token" PATCH \
    "${api_base}/repos/${owner}/${repo}/issues/comments/${comment_id}" "$payload_file")
  rm -f "$payload_file"

  http_code=$(printf '%s' "$response" | tail -n 1)
  response_body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "Codeberg issue comment edit failed (HTTP ${http_code}):" >&2
    printf '%s\n' "$response_body" >&2
    return 1
  fi
}

# Post a comment on a Codeberg issue via the Forgejo API.
codeberg_post_issue_comment() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local issue_index="$4"
  local body="$5"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local payload_file response http_code response_body

  [[ -n "$token" && "$issue_index" =~ ^[0-9]+$ ]] || return 1

  payload_file=$(mktemp)
  jq -n --arg body "$body" '{body: $body}' > "$payload_file"

  response=$(codeberg_api_call "$token" POST \
    "${api_base}/repos/${owner}/${repo}/issues/${issue_index}/comments" "$payload_file")
  rm -f "$payload_file"

  http_code=$(printf '%s' "$response" | tail -n 1)
  response_body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_code" != "201" ]]; then
    echo "Codeberg issue comment failed (HTTP ${http_code}):" >&2
    printf '%s\n' "$response_body" >&2
    return 1
  fi
}

# Build the canonical body for the rolling Codeberg status comment, derived deterministically
# from the GitHub issue's bot-authored (github-actions[bot]) comments in chronological order.
# Requires GH_REPO (and a logged-in gh). Fails (non-zero) when there is nothing to mirror yet,
# so callers can skip cleanly. Both the live mirror and the reconciliation job use this, which
# is what makes the mirror idempotent and self-healing.
signatures_build_status_comment_body() {
  local issue_number="$1"
  local gh_repo="${GH_REPO:-}"
  local marker pages combined body

  [[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$gh_repo" ]] || return 1
  marker=$(codeberg_status_marker)

  pages=$(gh api --paginate "repos/${gh_repo}/issues/${issue_number}/comments") || return 1
  combined=$(jq -s 'add // []' <<< "$pages") || return 1

  body=$(jq -rn --arg marker "$marker" --argjson comments "$combined" '
    ($comments
      | map(select(.user.login == "github-actions[bot]"))
      | map(.body // "")
    ) as $bodies
    | if ($bodies | length) == 0 then empty
      else $marker + "\n\n" + ($bodies | join("\n\n---\n\n"))
      end
  ') || return 1

  [[ -n "$body" ]] || return 1
  printf '%s' "$body"
}

# Mirror a GitHub submission issue's status updates to the linked Codeberg issue (### Submission
# Source: External: CB-N) as a SINGLE rolling comment that is edited in place. Forgejo rate-limits
# comment *creation* (HTTP 429: "posted N comments in 10 minutes"), so we create the managed
# comment at most once per issue and PATCH it thereafter. No-op (return 0) when the issue is not
# from Codeberg or there is nothing to mirror yet.
# Usage: signatures_mirror_issue_comment_to_codeberg <cb_token> <github_issue_number> [github_issue_body]
signatures_mirror_issue_comment_to_codeberg() {
  local token="$1"
  local github_issue_number="$2"
  local github_issue_body="${3:-}"
  local owner="${CODEBERG_REPO_OWNER:-privacyguides}"
  local repo="${CODEBERG_REPO_NAME:-verified-apps}"
  local gh_repo="${GH_REPO:-}"
  local cb_issue_num body comments_json comment_id

  [[ -n "$token" ]] || return 0
  [[ "$github_issue_number" =~ ^[0-9]+$ ]] || return 0

  if [[ -z "$github_issue_body" ]]; then
    github_issue_body=$(gh issue view "$github_issue_number" --repo "$gh_repo" --json body -q .body) || return 0
  fi

  if ! signatures_parse_submission_source "$github_issue_body"; then
    return 0
  fi
  if ! cb_issue_num=$(signatures_codeberg_issue_number "$SUBMISSION_EXTERNAL_REF"); then
    return 0
  fi

  # Nothing to mirror yet (no bot comments) — skip quietly.
  body=$(signatures_build_status_comment_body "$github_issue_number") || return 0

  if ! comments_json=$(codeberg_list_issue_comments "$token" "$owner" "$repo" "$cb_issue_num"); then
    echo "::warning::Could not mirror comment to ${SUBMISSION_EXTERNAL_REF} on Codeberg." >&2
    return 0
  fi
  comment_id=$(codeberg_find_status_comment_id "$comments_json")

  if [[ -n "$comment_id" ]]; then
    if ! codeberg_edit_issue_comment "$token" "$owner" "$repo" "$comment_id" "$body"; then
      echo "::warning::Could not mirror comment to ${SUBMISSION_EXTERNAL_REF} on Codeberg." >&2
    fi
  else
    if ! codeberg_post_issue_comment "$token" "$owner" "$repo" "$cb_issue_num" "$body"; then
      echo "::warning::Could not mirror comment to ${SUBMISSION_EXTERNAL_REF} on Codeberg." >&2
    fi
  fi
}

# Set a Codeberg issue state via the Forgejo API (open or closed).
codeberg_set_issue_state() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local issue_index="$4"
  local state="$5"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local payload_file response http_code response_body

  [[ -n "$token" && "$issue_index" =~ ^[0-9]+$ ]] || return 1
  case "$state" in
    open|closed) ;;
    *) return 1 ;;
  esac

  payload_file=$(mktemp)
  jq -n --arg state "$state" '{state: $state}' > "$payload_file"

  response=$(codeberg_api_call "$token" PATCH \
    "${api_base}/repos/${owner}/${repo}/issues/${issue_index}" "$payload_file")
  rm -f "$payload_file"

  http_code=$(printf '%s' "$response" | tail -n 1)
  response_body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
    echo "Codeberg issue state update failed (HTTP ${http_code}):" >&2
    printf '%s\n' "$response_body" >&2
    return 1
  fi
}

# Sync Codeberg issue open/closed state from a GitHub issue event action.
signatures_sync_codeberg_issue_state() {
  local token="$1"
  local github_issue_body="$2"
  local github_action="$3"
  local owner="${CODEBERG_REPO_OWNER:-privacyguides}"
  local repo="${CODEBERG_REPO_NAME:-verified-apps}"
  local cb_issue_num target_state

  [[ -n "$token" ]] || return 0

  case "$github_action" in
    opened|reopened) target_state="open" ;;
    closed) target_state="closed" ;;
    *) return 0 ;;
  esac

  if ! signatures_parse_submission_source "$github_issue_body"; then
    echo "Could not parse External issue ref from GitHub issue body." >&2
    return 1
  fi

  if ! cb_issue_num=$(signatures_codeberg_issue_number "$SUBMISSION_EXTERNAL_REF"); then
    echo "Invalid External issue ref: ${SUBMISSION_EXTERNAL_REF}" >&2
    return 1
  fi

  if ! codeberg_set_issue_state "$token" "$owner" "$repo" "$cb_issue_num" "$target_state"; then
    echo "::warning::Could not set ${SUBMISSION_EXTERNAL_REF} to ${target_state} on Codeberg." >&2
    return 1
  fi

  echo "Set ${SUBMISSION_EXTERNAL_REF} to ${target_state} on Codeberg."
}

# Fetch every label on a Codeberg repo as a compact name->id JSON map ({"Name": id, ...}).
codeberg_fetch_label_id_map() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local page=1 limit=50 response http_code page_json count combined='[]'

  while :; do
    response=$(codeberg_api_call "$token" GET \
      "${api_base}/repos/${owner}/${repo}/labels?limit=${limit}&page=${page}")
    http_code=$(printf '%s' "$response" | tail -n 1)
    page_json=$(printf '%s' "$response" | sed '$d')
    [[ "$http_code" == "200" ]] || return 1
    jq -e 'type == "array"' >/dev/null 2>&1 <<< "$page_json" || return 1
    count=$(jq 'length' <<< "$page_json")
    (( count > 0 )) || break
    combined=$(jq -c --argjson acc "$combined" '$acc + .' <<< "$page_json")
    (( count < limit )) && break
    page=$((page + 1))
  done

  jq -c 'reduce .[] as $l ({}; .[$l.name] = $l.id)' <<< "$combined"
}

# Replace all labels on a Codeberg issue to match the given label names (JSON array).
# Names that do not exist on the Codeberg repo are skipped; an empty array clears all labels.
codeberg_set_issue_labels() {
  local token="$1"
  local owner="$2"
  local repo="$3"
  local issue_index="$4"
  local names_json="$5"
  local api_base="${CODEBERG_API_BASE:-https://codeberg.org/api/v1}"
  local id_map ids payload_file response http_code response_body

  [[ -n "$token" && "$issue_index" =~ ^[0-9]+$ ]] || return 1

  id_map=$(codeberg_fetch_label_id_map "$token" "$owner" "$repo") || return 1
  ids=$(jq -c --argjson map "$id_map" '[ .[] | $map[.] // empty ]' <<< "$names_json")

  payload_file=$(mktemp)
  jq -n --argjson labels "$ids" '{labels: $labels}' > "$payload_file"

  response=$(codeberg_api_call "$token" PUT \
    "${api_base}/repos/${owner}/${repo}/issues/${issue_index}/labels" "$payload_file")
  rm -f "$payload_file"

  http_code=$(printf '%s' "$response" | tail -n 1)
  response_body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "Codeberg issue label update failed (HTTP ${http_code}):" >&2
    printf '%s\n' "$response_body" >&2
    return 1
  fi
}

# Mirror a GitHub issue's labels to the linked Codeberg issue (### Submission Source:
# External: CB-N). GitHub-only automation/marker labels are dropped. labels_json is a JSON
# array of the GitHub issue's current label names.
signatures_sync_codeberg_issue_labels() {
  local token="$1"
  local github_issue_body="$2"
  local labels_json="$3"
  local owner="${CODEBERG_REPO_OWNER:-privacyguides}"
  local repo="${CODEBERG_REPO_NAME:-verified-apps}"
  local cb_issue_num filtered

  [[ -n "$token" ]] || return 0

  if ! signatures_parse_submission_source "$github_issue_body"; then
    return 0
  fi
  if ! cb_issue_num=$(signatures_codeberg_issue_number "$SUBMISSION_EXTERNAL_REF"); then
    return 0
  fi

  # GitHub-only automation triggers and the Codeberg provenance marker do not belong on Codeberg.
  filtered=$(jq -c '
    [ .[] | select(
      . as $n
      | (["Import Codeberg", "Run Checks", "Create PR", "Commit As-Is", "Check APKPure"] | index($n)) | not
    ) ]
  ' <<< "$labels_json")

  if ! codeberg_set_issue_labels "$token" "$owner" "$repo" "$cb_issue_num" "$filtered"; then
    echo "::warning::Could not sync labels to ${SUBMISSION_EXTERNAL_REF} on Codeberg." >&2
    return 1
  fi

  echo "Synced labels to ${SUBMISSION_EXTERNAL_REF} on Codeberg."
}

# Compare-and-swap commit + push to a branch ref. Repeatedly: sync the working tree to the
# latest origin/<ref>, re-apply the caller's delta (a shell function named in $1 that mutates
# the tracked files against that fresh tip), stage <files>, create a signed commit, and push.
# If the push is rejected because <ref> advanced (a concurrent writer landed first), the whole
# cycle retries against the new tip. Because the delta is RE-APPLIED onto the current tip every
# attempt — never committed as a stale whole-file snapshot — concurrent writers serialize
# without ever reverting each other's entries (optimistic concurrency / CAS on the git ref).
#
# Echoes the pushed commit SHA on success (return 0). Returns 3 when the delta yields no change
# against the current tip (nothing to commit — e.g. another run already added it). Returns 1 on
# delta failure or exhausted retries.
#
# The caller must configure git identity + commit signing beforehand. apply_fn MUST be
# idempotent under re-application (the merge/upsert helpers here are: they dedupe by
# package/fingerprint/source/domain), since it runs once per attempt against a fresh tip.
# Usage: submission_cas_commit_push <apply_fn> <ref> <message_file> <author> <files> [max_attempts]
submission_cas_commit_push() {
  local apply_fn="$1" ref="$2" msg_file="$3" author="$4" files="$5" max="${6:-10}"
  local attempt=0 f sha

  while (( attempt < max )); do
    attempt=$((attempt + 1))
    if ! git fetch --quiet origin "$ref"; then
      echo "CAS: fetch origin/${ref} failed (attempt ${attempt}/${max})" >&2
      sleep 2
      continue
    fi
    # Discard any prior attempt's commit and re-sync to the freshly fetched tip.
    git reset --quiet --hard FETCH_HEAD

    if ! "$apply_fn"; then
      echo "CAS: delta function '${apply_fn}' failed" >&2
      return 1
    fi

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -e "$f" ]] && git add -- "$f"
    done <<< "$files"

    if git diff --cached --quiet; then
      echo "CAS: delta produced no change against origin/${ref}; nothing to commit." >&2
      return 3
    fi

    git commit --quiet -F "$msg_file" --author="$author"

    if git push --quiet origin "HEAD:${ref}" 2>/dev/null; then
      sha=$(git rev-parse HEAD)
      printf '%s\n' "$sha"
      return 0
    fi
    echo "CAS: push to ${ref} rejected — it advanced; re-applying onto the new tip (${attempt}/${max})" >&2
    sleep $(( (RANDOM % 3) + 1 ))
  done

  echo "CAS: exhausted ${max} attempts pushing to ${ref}" >&2
  return 1
}

# Configure git identity + SSH commit signing as the Privacy Guides bot (the same identity
# bot-commit uses, so commits read "Verified"). $1 is the SSH private key contents. Echoes the
# temp key file path so the caller can remove it (e.g. trap 'rm -f "$kf"' EXIT).
submission_configure_git_signing() {
  local ssh_key="$1" key_file
  git config user.name "Privacy Guides [bot]"
  git config user.email "github-bot@privacyguides.net"
  key_file="$(mktemp)"
  printf '%s\n' "$ssh_key" > "$key_file"
  chmod 600 "$key_file"
  git config gpg.format ssh
  git config user.signingkey "$key_file"
  git config commit.gpgsign true
  printf '%s' "$key_file"
}

# Write a submission commit message; always closes the synced GitHub issue (GH-N).
submission_write_commit_message_file() {
  local msg_file="$1"
  local first_line="$2"
  local github_issue_number="$3"
  local co_author_trailer="${4:-}"

  {
    printf '%s\n\n' "$first_line"
    printf 'Closes %s\n' "$(signatures_github_issue_ref "$github_issue_number")"
    if [[ -n "$co_author_trailer" ]]; then
      printf '\n%s\n' "$co_author_trailer"
    fi
  } > "$msg_file"
}

# GitHub noreply Co-authored-by trailer for a user (login + numeric id).
submission_coauthor_trailer_for_user() {
  local login="$1"
  local user_id="$2"
  local display_name

  display_name=$(gh api "users/${login}" --jq 'if .name then .name else .login end')
  printf 'Co-authored-by: %s <%s+%s@users.noreply.github.com>' "$display_name" "$user_id" "$login"
}

# GitHub noreply author identity ("Name <id+login@users.noreply.github.com>") for a user.
submission_author_identity_for_user() {
  local login="$1"
  local user_id="$2"
  local display_name

  display_name=$(gh api "users/${login}" --jq 'if .name then .name else .login end')
  printf '%s <%s+%s@users.noreply.github.com>' "$display_name" "$user_id" "$login"
}

# Codeberg noreply author identity for a Codeberg username.
submission_codeberg_author_identity_for_user() {
  local username="$1"
  [[ -n "$username" ]] || return 1
  printf '%s <%s@noreply.codeberg.org>' "$username" "$username"
}

# Co-authored-by trailer crediting the GitHub Actions bot.
submission_github_actions_coauthor_trailer() {
  printf 'Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
}

# Commit author identity (the submitter). A Codeberg author ($3) wins when present (submissions
# mirrored from Codeberg, where the GitHub submitter is the sync bot); otherwise the GitHub issue
# author is used.
submission_resolve_commit_author() {
  local submitter_login="$1"
  local submitter_id="$2"
  local codeberg_author="${3:-}"

  if [[ -n "$codeberg_author" ]]; then
    submission_codeberg_author_identity_for_user "$codeberg_author"
  else
    submission_author_identity_for_user "$submitter_login" "$submitter_id"
  fi
}

# Co-author trailers for a submission commit whose author is the submitter: the reviewer
# (labeler) first, then the GitHub Actions bot. The labeler trailer is omitted when the labeler
# is also the submitter (already credited as the commit author). For Codeberg-mirrored
# submissions the author is the Codeberg user, so the GitHub labeler is always a distinct
# co-author. The submitter arguments ($3/$4) are kept for the labeler==submitter check.
submission_resolve_coauthor_trailers() {
  local labeler_login="$1"
  local labeler_id="$2"
  local submitter_login="$3"
  local submitter_id="$4"
  local codeberg_author="${5:-}"
  local trailers=""

  if [[ -n "$codeberg_author" || "$labeler_login" != "$submitter_login" ]]; then
    trailers=$(submission_coauthor_trailer_for_user "$labeler_login" "$labeler_id")
  fi

  if [[ -n "$trailers" ]]; then
    trailers+=$'\n'
  fi
  trailers+=$(submission_github_actions_coauthor_trailer)

  printf '%s' "$trailers"
}

is_valid_package_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]]
}

is_valid_sha256_colon() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]]
}

# Locate apksigner or keytool under ANDROID_SDK_ROOT / ANDROID_HOME build-tools.
signatures_find_android_sdk_tool() {
  local tool_name="$1"
  local sdk_root="${2:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
  local tool_path

  [[ -n "$sdk_root" ]] || return 1
  tool_path=$(find "$sdk_root/build-tools" -maxdepth 2 -name "$tool_name" -type f 2>/dev/null | sort -V | tail -n1)
  [[ -n "$tool_path" && -x "$tool_path" ]] || return 1
  printf '%s' "$tool_path"
}

# Read the application package name from aapt/aapt2 dump badging output.
signatures_package_name_from_badging() {
  local badging="$1"
  local pkg

  pkg=$(printf '%s\n' "$badging" | awk -F"'" '/^package: name=/ { print $2; exit }')
  [[ -n "$pkg" ]] || return 1
  printf '%s' "$pkg"
}

# Extract package name from an APK via aapt dump badging (falls back to aapt2).
signatures_apk_package_name() {
  local apk_path="$1"
  local sdk_root="${2:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
  local tool badging pkg

  [[ -f "$apk_path" ]] || return 1

  for tool in aapt aapt2; do
    local tool_path
    tool_path=$(signatures_find_android_sdk_tool "$tool" "$sdk_root") || continue
    badging=$("$tool_path" dump badging "$apk_path" 2>/dev/null) || badging=""
    if pkg=$(signatures_package_name_from_badging "$badging"); then
      printf '%s' "$pkg"
      return 0
    fi
  done

  echo "Could not read package name from APK (aapt dump badging failed): ${apk_path}" >&2
  return 1
}

# Fail unless the APK manifest package matches the submitted application ID.
signatures_verify_apk_package() {
  local expected="$1"
  local apk_path="$2"
  local sdk_root="${3:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
  local actual

  if ! is_valid_package_name "$expected"; then
    echo "Invalid expected package name: ${expected}" >&2
    return 1
  fi

  actual=$(signatures_apk_package_name "$apk_path" "$sdk_root") || return 1
  if [[ "$actual" != "$expected" ]]; then
    echo "APK package name mismatch: expected ${expected}, APK contains ${actual}" >&2
    return 1
  fi
  printf '%s' "$actual"
}

# Normalize a 64-char SHA-256 hex string (with or without colons) to uppercase colon form.
signatures_sha256_hex_to_colon_fp() {
  local raw="${1//:/}"
  raw=$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  [[ ${#raw} -eq 64 ]] || return 1
  printf '%s' "$raw" | sed -E 's/(..)/\1:/g; s/:$//'
}

# Parse certificate SHA-256 digests from apksigner verify/lineage --print-certs output.
signatures_parse_apksigner_certificate_digests() {
  local verification="$1"
  printf '%s\n' "$verification" | awk '
    /^Source Stamp Signer/ { next }
    /public key SHA-256 digest/ { next }
    /does not contain a valid lineage/ { next }
    /^DOES NOT VERIFY/ { next }
    /^ERROR:/ { next }
    /certificate SHA-256 digest:/ {
      sub(/^.*certificate SHA-256 digest: /, "")
      gsub(/[[:space:]]+$/, "")
      if ($0 != "") {
        print
      }
      next
    }
    /^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$/ {
      print
    }
  '
}

# Run apksigner verify and lineage; store output in caller vars (pass two variable names).
# Internal capture names must differ from typical caller names (verify_out / lineage_out) so
# printf -v does not assign into a function-local shadow of the caller variable.
signatures_gather_apksigner() {
  local apk_path="$1"
  local sdk_root="${2:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
  local verify_name="$3"
  local lineage_name="$4"
  local apksigner _captured_verify _captured_lineage

  [[ -f "$apk_path" ]] || return 1
  apksigner=$(signatures_find_android_sdk_tool apksigner "$sdk_root") || return 1

  # Active signing certificates on the APK (including rotation targets by SDK range).
  _captured_verify=$("$apksigner" verify --print-certs "$apk_path" 2>&1) || true

  # Full rotation lineage when present; -v prints every certificate in the chain.
  # APKs without lineage (e.g. com.google.android.gsf) print an error here — verify output still applies.
  _captured_lineage=$("$apksigner" lineage --in "$apk_path" --print-certs -v 2>&1) || true

  printf -v "$verify_name" '%s' "$_captured_verify"
  printf -v "$lineage_name" '%s' "$_captured_lineage"
}

# Merge verify + lineage digests (hex) from apksigner output; one entry per certificate.
signatures_digests_from_apksigner_outputs() {
  local verify_out="$1"
  local lineage_out="$2"
  {
    signatures_parse_apksigner_certificate_digests "$verify_out"
    signatures_parse_apksigner_certificate_digests "$lineage_out"
  } | awk 'NF' | sort -u
}

# Parse SHA-256 certificate fingerprints from keytool -printcert -jarfile output.
signatures_parse_keytool_certificate_digests() {
  local keytool_output="$1"
  printf '%s\n' "$keytool_output" | awk '
    /Certificate fingerprint \(SHA-256\):/ {
      sub(/^.*Certificate fingerprint \(SHA-256\):[[:space:]]*/, "")
      print
      next
    }
    /^[[:space:]]*SHA256:/ {
      sub(/^.*SHA256:[[:space:]]*/, "")
      print
    }
  '
}

signatures_first_certificate_dn_from_verification() {
  local verification="$1"
  printf '%s\n' "$verification" | awk '
    /^Source Stamp Signer/ { next }
    /certificate DN:/ {
      sub(/^.*certificate DN: /, "")
      print
      exit
    }
  '
}

# Detect google-play-app-signing or fdroid signer profile from apksigner output.
signatures_detect_signer_kind_from_verification() {
  local verification="$1"
  local google_play_dn="CN=Android, OU=Android, O=Google Inc., L=Mountain View, ST=California, C=US"
  local fdroid_dn="CN=FDroid, OU=FDroid, O=fdroid.org, L=ORG, ST=ORG, C=UK"
  local dn

  while IFS= read -r dn; do
    [[ -z "$dn" ]] && continue
    if [[ "$dn" == "$google_play_dn" ]]; then
      printf 'google-play-app-signing\n'
      return 0
    fi
    if [[ "$dn" == "$fdroid_dn" ]]; then
      printf 'fdroid\n'
      return 0
    fi
  done < <(printf '%s\n' "$verification" | awk '
    /^Source Stamp Signer/ { next }
    /certificate DN:/ {
      sub(/^.*certificate DN: /, "")
      print
    }
  ')
}

# Build newline-separated colon fingerprints from apksigner output (and optional keytool).
signatures_colon_digests_from_outputs() {
  local apk_path="${1:-}"
  local sdk_root="${2:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
  local verify_out="$3"
  local lineage_out="$4"
  local apksigner_override="${5:-}"
  local keytool keytool_out fp sha256 colon_fps

  colon_fps=""
  while IFS= read -r sha256; do
    [[ -z "$sha256" ]] && continue
    fp=$(signatures_sha256_hex_to_colon_fp "$sha256") || continue
    colon_fps+="${fp}"$'\n'
  done < <(signatures_digests_from_apksigner_outputs "$verify_out" "$lineage_out")

  if [[ -n "$apk_path" && -f "$apk_path" ]]; then
    keytool=$(signatures_find_android_sdk_tool keytool "$sdk_root" || command -v keytool 2>/dev/null || true)
    if [[ -n "$keytool" ]]; then
      keytool_out=$("$keytool" -printcert -jarfile "$apk_path" 2>&1) || true
      while IFS= read -r sha256; do
        [[ -z "$sha256" ]] && continue
        fp=$(signatures_sha256_hex_to_colon_fp "$sha256") || continue
        colon_fps+="${fp}"$'\n'
      done < <(signatures_parse_keytool_certificate_digests "$keytool_out" | sort -u)
    fi
  fi

  signatures_format_block "$colon_fps" || return 1
}

# Collect every app signing certificate fingerprint from an APK (verify + lineage + JAR).
signatures_extract_from_apk() {
  local apk_path="$1"
  local sdk_root="${2:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
  local apksigner_override="${3:-}"
  local verify_out="${4:-}"
  local lineage_out="${5:-}"
  local digest_raw formatted

  if [[ -z "$verify_out" ]]; then
    if [[ -n "$apksigner_override" ]]; then
      verify_out=$("$apksigner_override" verify --print-certs "$apk_path" 2>&1) || true
      lineage_out=$("$apksigner_override" lineage --in "$apk_path" --print-certs -v 2>&1) || true
    elif ! signatures_gather_apksigner "$apk_path" "$sdk_root" verify_out lineage_out; then
      return 1
    fi
  fi

  if ! formatted=$(signatures_colon_digests_from_outputs \
    "$apk_path" "$sdk_root" "$verify_out" "$lineage_out" "$apksigner_override"); then
    echo "Failed to extract signing certificate SHA-256 digest(s) from ${apk_path}" >&2
    printf '%s\n' "--- apksigner verify --print-certs ---" "$verify_out" >&2
    printf '%s\n' "--- apksigner lineage --print-certs -v ---" "$lineage_out" >&2
    return 1
  fi

  printf '%s' "$formatted"
}

# Download a direct-link APK to <dest> and sanity-check it is an APK (zip/android), matching
# the new-submission directApk step. Returns 1 on a download error or a non-APK file.
signatures_download_direct_apk() {
  local url="$1" dest="$2"
  # Remove any prior file first and make the curl failure explicit: callers may invoke this inside an
  # `if` (where `set -e` is suspended), so a 404 must NOT leave a stale APK from a previous download
  # that the file/grep check below would then wrongly accept.
  rm -f "$dest"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || return 1
  file "$dest"
  if ! file "$dest" | grep -qiE 'zip archive|android'; then
    echo "Downloaded file does not look like an APK: ${url}" >&2
    return 1
  fi
}

# Hostname from a custom F-Droid repository URL (e.g. app.simplex.chat).
signatures_fdroid_repo_host_from_url() {
  local url="${1-}"
  local host

  [[ -n "$url" ]] || return 1
  host=$(printf '%s\n' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@:/?#]+).*#\1#')
  host="${host#www.}"
  [[ -n "$host" ]] || return 1
  printf '%s\n' "$host"
}

signatures_fdroid_source_label() {
  local repo_name="$1"

  if [[ "$repo_name" == "F-Droid" ]]; then
    printf 'F-Droid\n'
  else
    printf 'F-Droid (%s)\n' "$repo_name"
  fi
}

signatures_is_known_fdroid_matrix_repo() {
  case "$1" in
    F-Droid | IzzyOnDroid) return 0 ;;
    *) return 1 ;;
  esac
}

append_fingerprint_tokens() {
  local line="$1"
  local token

  if is_valid_sha256_colon "$line"; then
    printf '%s\n' "$(printf '%s' "$line" | tr '[:lower:]' '[:upper:]')"
    return
  fi

  for token in $line; do
    if is_valid_sha256_colon "$token"; then
      printf '%s\n' "$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')"
    fi
  done
}

signatures_to_lines() {
  local text="${1-}"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    append_fingerprint_tokens "$line"
  done <<< "$text"
}

signatures_normalize() {
  signatures_to_lines "$1" | sort -u
}

signatures_format_block() {
  local formatted=""
  local count=0
  local fp
  while IFS= read -r fp; do
    [[ -z "$fp" ]] && continue
    count=$((count + 1))
    if [[ -n "$formatted" ]]; then
      formatted+=$'\n'
    fi
    formatted+="$fp"
  done < <(signatures_normalize "$1")

  if (( count == 0 )); then
    return 1
  fi
  printf '%s' "$formatted"
}

signatures_equal() {
  local a b
  a=$(signatures_normalize "$1")
  b=$(signatures_normalize "$2")
  [[ -n "$a" && -n "$b" && "$a" == "$b" ]]
}

signatures_overlap() {
  local a b line
  a=$(signatures_normalize "$1")
  b=$(signatures_normalize "$2")
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if printf '%s\n' "$b" | grep -Fxq "$line"; then
      return 0
    fi
  done <<< "$a"
  return 1
}

# Extract the "### Verification Info" section from an issue body, unwrapping a
# fenced code block when present. Emits the raw block for parse_verification_text.
signatures_extract_verification_block() {
  local body="$1"
  local block

  block=$(printf '%s\n' "$body" | sed -n '/^### Verification Info$/,$p' | tail -n +2)
  if printf '%s\n' "$block" | grep -q '^```'; then
    block=$(printf '%s\n' "$block" | sed -n '/^```/,/^```/p' | sed '1d;$d')
  fi
  printf '%s\n' "$block"
}

parse_verification_text() {
  local text="$1"
  local line pkg="" sigs=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^\`\`\` ]] && continue

    if is_valid_package_name "$line" && [[ -z "$pkg" ]]; then
      pkg="$line"
    elif is_valid_sha256_colon "$line"; then
      sigs+=("$(printf '%s' "$line" | tr '[:lower:]' '[:upper:]')")
    else
      local token
      for token in $line; do
        if is_valid_sha256_colon "$token"; then
          sigs+=("$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')")
        fi
      done
    fi
  done <<< "$text"

  if [[ -z "$pkg" || ${#sigs[@]} -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "$pkg"
  printf '%s\n' "${sigs[@]}" | sort -u
}

# Write JSON to a temp file (used with yq -oy to produce YAML for load()).
_submission_json_tempfile() {
  local content="$1"
  local path="${TMPDIR:-/tmp}/submission-$$-${RANDOM}.json"
  printf '%s' "$content" > "$path"
  printf '%s' "$path"
}

# yq load() on JSON assigns a JSON string scalar in YAML; convert to YAML first.
_submission_json_to_yaml_tempfile() {
  local content="$1"
  local json_file yaml_file
  json_file=$(_submission_json_tempfile "$content")
  yaml_file="${json_file%.json}.yaml"
  yq -oy '.' "$json_file" > "$yaml_file"
  # Force multiline fingerprints to render as literal blocks for readability.
  yq -i '(.[] | select(.fingerprint | type == "!!str" and contains("\n")) | .fingerprint) style="literal"' "$yaml_file" 2>/dev/null || true
  rm -f "$json_file"
  printf '%s' "$yaml_file"
}

# jq: merge sources by name (existing first). Update issue only when apk metadata changes.
_submission_jq_merge_sources_by_name() {
  cat <<'JQ'
    def apk_field_changed($base_val; $over_val):
      ($over_val // "") != "" and ($base_val // "") != ($over_val // "");

    def apk_has_changes($base_apk; $over):
      if $over.apk == null then false
      elif $base_apk == null then
        (($over.apk.sha256 // "") != "")
        or (($over.apk.link // "") != "")
        or (($over.apk.repo // "") != "")
      else
        apk_field_changed($base_apk.sha256; $over.apk.sha256)
        or apk_field_changed($base_apk.link; $over.apk.link)
        or apk_field_changed($base_apk.repo; $over.apk.repo)
      end;

    def apk_apply_changes($base_apk; $over_apk):
      if $over_apk == null then $base_apk
      elif $base_apk == null then $over_apk
      else
        $base_apk
        | if (($over_apk.sha256 // "") != "") then .sha256 = $over_apk.sha256 else . end
        | if (($over_apk.link // "") != "") then .link = $over_apk.link else . end
        | if (($over_apk.repo // "") != "") then .repo = $over_apk.repo else . end
      end;

    def merge_one_source($base; $over):
      if apk_has_changes($base.apk; $over) then
        $base
        | (if (($over.issue // null) != null) then .issue = $over.issue else . end)
        | .apk = apk_apply_changes($base.apk; $over.apk)
        | if .apk == null then del(.apk) else . end
      else
        $base
      end;

    def merge_sources_by_name:
      group_by(.name)
      | map(reduce .[] as $s (.[0]; merge_one_source(.; $s)));
JQ
}

# Merge schema-3 signature arrays (grouped by fingerprint, sources deduped by name).
submission_merge_signature_arrays() {
  local existing_json="$1"
  local incoming_json="$2"
  jq -s "$(_submission_jq_merge_sources_by_name)
    def fp_key(\$f):
      (\$f | if type == \"string\" then (split(\"\\n\") | join(\"\") | gsub(\" \"; \"\")) else \"\" end);
    .[0] as \$existing | .[1] as \$incoming |
    (\$existing + \$incoming)
    | group_by(fp_key(.fingerprint))
    | map({
        fingerprint: .[0].fingerprint,
        sources: ([.[].sources[]] | merge_sources_by_name)
      })
  " <<< "$(printf '%s\n%s' "$existing_json" "$incoming_json")"
}

# Append one source proposal (JSON line) to the proposals file.
_submission_add_proposal() {
  local proposals_file="$1"
  local fp_block="$2"
  local name="$3"
  local issue_ref="$4"
  local apk_sha256="${5-}"
  local apk_link="${6-}"
  local apk_repo="${7-}"

  jq -cn \
    --arg fp "$fp_block" \
    --arg name "$name" \
    --arg issue "$issue_ref" \
    --arg sha "$apk_sha256" \
    --arg link "$apk_link" \
    --arg repo "$apk_repo" \
    '{
      fingerprint: $fp,
      name: $name,
      issue: $issue,
      apk: (
        if $sha == "" and $link == "" and $repo == "" then null
        else (
          {}
          | if $sha != "" then .sha256 = $sha else . end
          | if $link != "" then .link = $link else . end
          | if $repo != "" then .repo = $repo else . end
        )
        end
      )
    }' >> "$proposals_file"
}

# Assemble schema-3 package entry YAML from JSONL proposals.
_submission_assemble_entry_from_proposals() {
  local proposals_file="$1"
  local entry_file="$2"
  local package="$3"
  local assembled

  if [[ ! -s "$proposals_file" ]]; then
    return 1
  fi

  assembled=$(
    jq -s "$(_submission_jq_merge_sources_by_name)
      group_by(.fingerprint | (split(\"\\n\") | join(\"\") | gsub(\" \"; \"\")))
      | map({
          fingerprint: .[0].fingerprint,
          sources: (
            [.[] | {name, issue} + (if .apk then {apk: .apk} else {} end)]
            | merge_sources_by_name
          )
        })
    " "$proposals_file"
  )

  local entry_json
  entry_json=$(_submission_json_tempfile "$(jq -cn --arg package "$package" --argjson signature "$assembled" \
    '{package: $package, signature: $signature}')")
  yq -oy '.' "$entry_json" > "$entry_file"
  # Force multiline fingerprints to render as literal blocks for readability.
  yq -i '(.signature[] | select(.fingerprint | type == "!!str" and contains("\n")) | .fingerprint) style="literal"' "$entry_file" 2>/dev/null || true
  rm -f "$entry_json"
}

# Build a single package entry (schema 4: fingerprint groups with sources[]) from store matches.
submission_build_entry_file() {
  local entry_file="$1"
  local user_sig fp_block store_sig repo_name fdroid_source proposals_file
  local apk_sha apk_link apk_repo submission_issue_ref

  user_sig="$(signatures_format_block "$USER_SIG")"
  proposals_file="$(mktemp)"

  if [[ -n "${SUBMISSION_ISSUE_REF:-}" ]]; then
    submission_issue_ref="$SUBMISSION_ISSUE_REF"
  else
    submission_issue_ref=$(signatures_github_issue_ref "$ISSUE")
  fi

  _submission_add_source() {
    local fp="$1"
    local name="$2"
    local sha="${3-}"
    local link="${4-}"
    local repo="${5-}"
    _submission_add_proposal "$proposals_file" "$fp" "$name" "$submission_issue_ref" "$sha" "$link" "$repo"
  }

  if [[ -n "${SUBMITTER_SOURCE:-}" ]]; then
    _submission_add_source "$user_sig" "$SUBMITTER_SOURCE"
    _submission_assemble_entry_from_proposals "$proposals_file" "$entry_file" "$PACKAGE"
    rm -f "$proposals_file"
    return 0
  fi

  if [[ -n "${ACC_SIG:-}" ]] && signatures_equal "$ACC_SIG" "$user_sig"; then
    _submission_add_source "$user_sig" "Accrescent" "${ACC_APK_SHA256:-}"
  fi
  if [[ -n "${FDROID_RESULTS_DIR:-}" && -d "$FDROID_RESULTS_DIR" ]]; then
    while IFS= read -r result_file; do
      [[ -z "$result_file" ]] && continue
      [[ "$(jq -r '.found' "$result_file")" != "true" ]] && continue
      repo_name=$(jq -r '.repoName' "$result_file")
      store_sig=$(jq -r '.signature' "$result_file")
      apk_sha=$(jq -r '.apkSha256 // ""' "$result_file")
      if signatures_equal "$store_sig" "$user_sig"; then
        apk_link=""
        apk_repo=""
        fdroid_source=$(signatures_fdroid_source_label "$repo_name")
        if ! signatures_is_known_fdroid_matrix_repo "$repo_name"; then
          apk_repo="${CUSTOM_FDROID_REPO_URL:-}"
          apk_sha="${apk_sha:-${CUSTOM_FDROID_APK_SHA256:-}}"
        fi
        fp_block="$(signatures_format_block "$store_sig")"
        _submission_add_source "$fp_block" "$fdroid_source" "$apk_sha" "$apk_link" "$apk_repo"
      fi
    done < <(find "$FDROID_RESULTS_DIR" -type f -name '*.json' 2>/dev/null | sort)
  fi
  if [[ -n "${GPLAY_SIG:-}" ]] && signatures_equal "$GPLAY_SIG" "$user_sig"; then
    fp_block="$(signatures_format_block "$GPLAY_SIG")"
    _submission_add_source "$fp_block" "Google Play" "${GPLAY_APK_SHA256:-}"
  fi
  if [[ -n "${APKPURE_SIG:-}" ]] && signatures_equal "$APKPURE_SIG" "$user_sig"; then
    fp_block="$(signatures_format_block "$APKPURE_SIG")"
    _submission_add_source "$fp_block" "Custom (APKPure)" "${APKPURE_APK_SHA256:-}"
  fi
  if [[ -n "${APPVERIFIER_SIG:-}" ]] && signatures_equal "$APPVERIFIER_SIG" "$user_sig"; then
    fp_block="$(signatures_format_block "$APPVERIFIER_SIG")"
    _submission_add_source "$fp_block" "AppVerifier"
  fi
  if [[ -n "${DIRECT_SIG:-}" ]] && signatures_equal "$DIRECT_SIG" "$user_sig"; then
    fp_block="$(signatures_format_block "$DIRECT_SIG")"
    _submission_add_source "$fp_block" "Direct APK Link" "${DIRECT_APK_SHA256:-}" "${DIRECT_APK_URL:-}"
  fi
  # A signing key vouched for by the package's own verified domain qualifies on its own,
  # even when no app store matched the submission. DOMAIN_VERIFIED_METHOD (https/dns)
  # selects the method-specific source label.
  if [[ -n "${DOMAIN_VERIFIED_SIG:-}" ]] && signatures_equal "$DOMAIN_VERIFIED_SIG" "$user_sig"; then
    _submission_add_source "$user_sig" "$(domain_source_name "${DOMAIN_VERIFIED_METHOD:-https}")"
  fi

  if [[ ! -s "$proposals_file" ]]; then
    rm -f "$proposals_file"
    return 1
  fi
  _submission_assemble_entry_from_proposals "$proposals_file" "$entry_file" "$PACKAGE"
  rm -f "$proposals_file"
  return 0
}

# Merge entry file into data.yml (or alternate path in $2).
submission_merge_entry_into_data_yml() {
  local entry_file="$1"
  local data_file="${2:-data.yml}"
  local existing_json incoming_json merged_json

  export PACKAGE
  PACKAGE=$(yq -r '.package' "$entry_file")
  incoming_json=$(yq -o=json -I0 '.signature' "$entry_file")

  if [[ -f "$data_file" ]] && [[ -s "$data_file" ]]; then
    schema=$(yq -r '.schema // 0' "$data_file")
    if ! signatures_data_schema_supported "$schema"; then
      echo "Unsupported data.yml schema (expected 3 or 4): $schema" >&2
      return 1
    fi
    if yq -e '.packages[] | select(.package == strenv(PACKAGE))' "$data_file" >/dev/null 2>&1; then
      existing_json=$(yq -o=json -I0 '.packages[] | select(.package == strenv(PACKAGE)) | .signature' "$data_file")
      merged_json=$(submission_merge_signature_arrays "$existing_json" "$incoming_json")
      merged_file=$(_submission_json_to_yaml_tempfile "$merged_json")
      export MERGED_FILE="$merged_file"
      yq -i 'with(.packages[] | select(.package == strenv(PACKAGE)); .signature = load(strenv(MERGED_FILE)))' "$data_file"
      rm -f "$merged_file"
    else
      export ENTRY="$entry_file"
      yq -i '.packages += [load(strenv(ENTRY))]' "$data_file"
    fi
    yq -i '.packages |= sort_by(.package)' "$data_file"
  else
    export ENTRY="$entry_file"
    yq -n '.schema = 4 | .packages = [load(strenv(ENTRY))]' > "$data_file"
  fi
}

# Remove the source named <source_name> from the signature group of <package> whose fingerprint
# matches <fingerprint> (set-equal, so multi-cert blocks match regardless of order/formatting).
# Used by the spot-check re-verification sweep to drop a source that no longer verifies. Does not
# prune emptied groups/packages — call signatures_prune_empty afterwards. The library is otherwise
# additive; this and signatures_prune_empty are the only removal helpers.
signatures_remove_source() {
  local data_file="$1" package="$2" fingerprint="$3" source_name="$4"
  [[ -f "$data_file" && -s "$data_file" ]] || return 0
  export SR_PKG="$package" SR_NAME="$source_name"
  local sig_count i fp
  sig_count=$(yq -r '.packages[] | select(.package == strenv(SR_PKG)) | .signature | length' "$data_file" 2>/dev/null)
  [[ "$sig_count" =~ ^[0-9]+$ ]] || return 0
  for ((i = 0; i < sig_count; i++)); do
    fp=$(yq -r ".packages[] | select(.package == strenv(SR_PKG)) | .signature[$i].fingerprint" "$data_file")
    signatures_equal "$fp" "$fingerprint" || continue
    yq -i "(.packages[] | select(.package == strenv(SR_PKG)) | .signature[$i].sources) |= map(select(.name != strenv(SR_NAME)))" "$data_file"
  done
}

# Drop fingerprint groups whose sources became empty, then packages whose signature list became
# empty, so a removal that empties an entry cleans it up entirely. Idempotent.
signatures_prune_empty() {
  local data_file="$1"
  [[ -f "$data_file" && -s "$data_file" ]] || return 0
  yq -i '(.packages[].signature) |= map(select((.sources // []) | length > 0))' "$data_file"
  yq -i '.packages |= map(select((.signature // []) | length > 0))' "$data_file"
}

# Merge into <dest_data> every package whose stanza in <src_data> is new or differs from
# <dest_data> (additive: each differing package's signature is merged in and deduped by
# fingerprint/source — dest-only entries are never removed). This re-applies a submission PR's
# proposed additions onto the latest main without overwriting concurrent entries; pairing it
# with git's 3-way merge at merge time keeps concurrent submissions from clobbering each other.
# Echoes the number of packages merged. Idempotent: re-running merges nothing new.
submission_merge_data_delta() {
  local src="$1" dest="$2"
  local src_json dest_json changed pkg entry merged=0

  src_json=$(yq -o=json -I0 '[.packages[]?]' "$src" 2>/dev/null) || src_json="[]"
  [[ -n "$src_json" ]] || src_json="[]"
  if [[ -f "$dest" && -s "$dest" ]]; then
    dest_json=$(yq -o=json -I0 '[.packages[]?]' "$dest" 2>/dev/null) || dest_json="[]"
  else
    dest_json="[]"
  fi
  [[ -n "$dest_json" ]] || dest_json="[]"

  # Package names present in src whose stanza is absent from / differs from dest (jq compares
  # objects by content, key-order-insensitive).
  changed=$(jq -rn --argjson a "$dest_json" --argjson b "$src_json" '
    ($a | map({key: .package, value: .}) | from_entries) as $A
    | $b[] | select(. != ($A[.package] // null)) | .package')

  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    export _SMD_PKG="$pkg"
    entry="$(mktemp)"
    yq -o=yaml '.packages[] | select(.package == strenv(_SMD_PKG))' "$src" > "$entry"
    submission_merge_entry_into_data_yml "$entry" "$dest"
    rm -f "$entry"
    merged=$((merged + 1))
  done <<< "$changed"

  printf '%s' "$merged"
}

# Write one package stanza as it appears under packages: in data.yml.
_submission_write_package_list_item() {
  local data_file="$1"
  local dest="$2"

  if [[ -f "$data_file" ]] && yq -e ".packages[] | select(.package == strenv(PACKAGE))" "$data_file" >/dev/null 2>&1; then
    yq -o=yaml ".packages[] | select(.package == strenv(PACKAGE))" "$data_file" \
      | sed '1s/^/  - /; 2,$s/^/    /' > "$dest"
  else
    : > "$dest"
  fi
}

# Line exists in a package list-item file (exact match).
_submission_line_in_file() {
  local line="$1"
  local file="$2"
  [[ -n "$line" ]] && grep -Fxq -- "$line" "$file" 2>/dev/null
}

# Remove the first exact occurrence of line from pool file; return 0 if one was removed.
_submission_consume_line_from_pool() {
  local line="$1"
  local pool="$2"
  local tmp found=false pool_line

  tmp="$(mktemp)"
  while IFS= read -r pool_line || [[ -n "$pool_line" ]]; do
    if [[ "$found" == false && "$pool_line" == "$line" ]]; then
      found=true
      continue
    fi
    printf '%s\n' "$pool_line" >> "$tmp"
  done < "$pool"
  mv "$tmp" "$pool"
  [[ "$found" == true ]]
}

# GFM ```diff with the full after stanza; unchanged lines use ' ', new lines use '+'.
_submission_emit_append_only_package_diff() {
  local before_file="$1"
  local after_file="$2"
  local before_pool before_count after_count line

  before_count=$(wc -l < "$before_file" | tr -d '[:space:]')
  after_count=$(wc -l < "$after_file" | tr -d '[:space:]')
  before_pool="$(mktemp)"
  cp "$before_file" "$before_pool"

  printf '%s\n' "--- data.yml (current)" "+++ data.yml (after commit)" "@@ -1,${before_count} +1,${after_count} @@"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if _submission_consume_line_from_pool "$line" "$before_pool"; then
      printf ' %s\n' "$line"
    else
      printf '+%s\n' "$line"
    fi
  done < "$after_file"
  rm -f "$before_pool"
}

# GFM ```diff for a package that is not in data.yml yet (all lines added).
_submission_emit_new_package_diff() {
  local after_file="$1"
  local after_count line

  after_count=$(wc -l < "$after_file" | tr -d '[:space:]')
  printf '%s\n' "--- data.yml (current)" "+++ data.yml (after commit)" "@@ -0,0 +1,${after_count} @@"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '+%s\n' "$line"
  done < "$after_file"
}

# True when every non-empty line in before_file appears unchanged in after_file.
_submission_before_is_subset_of_after() {
  local before_file="$1"
  local after_file="$2"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if ! _submission_line_in_file "$line" "$after_file"; then
      return 1
    fi
  done < "$before_file"
  return 0
}

# Unified diff (GFM ```diff) of the package entry before vs after merging store matches.
submission_format_package_merge_diff() {
  local entry_file="$1"
  local before_file after_file work_data diff_out

  export PACKAGE
  PACKAGE=$(yq -r '.package' "$entry_file")

  before_file="$(mktemp)"
  after_file="$(mktemp)"
  work_data="$(mktemp)"

  _submission_write_package_list_item "data.yml" "$before_file"

  if [[ -f data.yml ]] && [[ -s data.yml ]]; then
    cp data.yml "$work_data"
  else
    yq -n '.schema = 4 | .packages = []' > "$work_data"
  fi
  submission_merge_entry_into_data_yml "$entry_file" "$work_data"
  _submission_write_package_list_item "$work_data" "$after_file"

  if diff -q "$before_file" "$after_file" >/dev/null 2>&1; then
    rm -f "$before_file" "$after_file" "$work_data"
    printf '%s\n' "_No changes: every matching store signature is already listed for this package in \`data.yml\`._"
    return 0
  fi

  if [[ ! -s "$before_file" ]]; then
    diff_out=$(_submission_emit_new_package_diff "$after_file")
  elif _submission_before_is_subset_of_after "$before_file" "$after_file"; then
    diff_out=$(_submission_emit_append_only_package_diff "$before_file" "$after_file")
  else
    local context_lines
    context_lines=$(wc -l < "$after_file" | tr -d '[:space:]')
    diff_out=$(diff -u -U "$context_lines" --label "data.yml (current)" --label "data.yml (after commit)" "$before_file" "$after_file" || true)
  fi
  rm -f "$before_file" "$after_file" "$work_data"
  printf '%s\n' "$diff_out"
}
