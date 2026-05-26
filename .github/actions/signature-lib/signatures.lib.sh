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

is_valid_package_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]]
}

is_valid_sha256_colon() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]]
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

signatures_write_file() {
  local path="$1"
  local block="$2"
  printf '%s' "$block" > "$path"
}

# Write one signature map with a literal-block fingerprint when needed.
signatures_write_yaml_entry() {
  local path="$1"
  local source="$2"
  local issue="$3"
  local fp_block="$4"
  local link="${5-}"

  {
    printf 'source: "%s"\n' "$source"
    printf 'issue: %s\n' "$issue"
    if [[ "$fp_block" == *$'\n'* ]]; then
      echo 'fingerprint: |'
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        printf '  %s\n' "$line"
      done <<< "$fp_block"
    else
      printf 'fingerprint: %s\n' "$fp_block"
    fi
    if [[ -n "$link" ]]; then
      printf 'link: "%s"\n' "$link"
    fi
  } > "$path"
}

# Build a single package entry (package + signature[]) from store matches.
# Required env: PACKAGE, ISSUE, USER_SIG (raw; formatted internally)
# Optional env: SUBMITTER_SOURCE, ACC_SIG, FDROID_RESULTS_DIR, CUSTOM_FDROID_REPO_URL, GPLAY_SIG, APPVERIFIER_SIG, DIRECT_SIG, DIRECT_APK_URL
# Writes YAML object to $1. Returns 0 when at least one signature was added, 1 otherwise.
submission_build_entry_file() {
  local entry_file="$1"
  local user_sig fp_block sig_piece sig_source store_sig repo_name fdroid_source sig_link

  user_sig="$(signatures_format_block "$USER_SIG")"

  export PACKAGE ISSUE
  yq -n '.package = strenv(PACKAGE) | .signature = []' > "$entry_file"

  _submission_add_signature() {
    local src="$1"
    local block="$2"
    local link="${3-}"
    sig_piece="$(mktemp)"
    signatures_write_yaml_entry "$sig_piece" "$src" "$ISSUE" "$block" "$link"
    export SIG_PIECE="$sig_piece"
    yq -i '.signature += [load(strenv(SIG_PIECE))]' "$entry_file"
    rm -f "$sig_piece"
  }

  if [[ -n "${SUBMITTER_SOURCE:-}" ]]; then
    _submission_add_signature "$SUBMITTER_SOURCE" "$user_sig"
    return 0
  fi

  if [[ -n "${ACC_SIG:-}" ]] && signatures_equal "$ACC_SIG" "$user_sig"; then
    _submission_add_signature "Accrescent" "$user_sig" "https://accrescent.app/app/${PACKAGE}"
  fi
  if [[ -n "${FDROID_RESULTS_DIR:-}" && -d "$FDROID_RESULTS_DIR" ]]; then
    while IFS= read -r result_file; do
      [[ -z "$result_file" ]] && continue
      [[ "$(jq -r '.found' "$result_file")" != "true" ]] && continue
      repo_name=$(jq -r '.repoName' "$result_file")
      store_sig=$(jq -r '.signature' "$result_file")
      if signatures_equal "$store_sig" "$user_sig"; then
        sig_link=""
        if [[ "$repo_name" == "F-Droid" ]]; then
          fdroid_source="F-Droid"
          sig_link="https://f-droid.org/packages/${PACKAGE}/"
        elif [[ "$repo_name" == "IzzyOnDroid" ]]; then
          fdroid_source="F-Droid (${repo_name})"
          sig_link="https://apt.izzysoft.de/fdroid/index/apk/${PACKAGE}"
        elif [[ "$repo_name" == "Custom" ]]; then
          fdroid_source="F-Droid (${repo_name})"
          sig_link="${CUSTOM_FDROID_REPO_URL:-}"
        else
          fdroid_source="F-Droid (${repo_name})"
        fi
        _submission_add_signature "$fdroid_source" "$user_sig" "$sig_link"
      fi
    done < <(find "$FDROID_RESULTS_DIR" -type f -name '*.json' 2>/dev/null | sort)
  fi
  if [[ -n "${GPLAY_SIG:-}" ]] && signatures_equal "$GPLAY_SIG" "$user_sig"; then
    _submission_add_signature "Google Play" "$user_sig" "https://play.google.com/store/apps/details?id=${PACKAGE}"
  fi
  if [[ -n "${APPVERIFIER_SIG:-}" ]] && signatures_equal "$APPVERIFIER_SIG" "$user_sig"; then
    _submission_add_signature "AppVerifier" "$user_sig"
  fi
  if [[ -n "${DIRECT_SIG:-}" ]] && signatures_equal "$DIRECT_SIG" "$user_sig"; then
    _submission_add_signature "Direct APK Link" "$user_sig" "${DIRECT_APK_URL:-}"
  fi

  if [[ "$(yq '.signature | length' "$entry_file")" -eq 0 ]]; then
    return 1
  fi
  return 0
}

# Merge entry file into data.yml (or alternate path in $2).
submission_merge_entry_into_data_yml() {
  local entry_file="$1"
  local data_file="${2:-data.yml}"

  export PACKAGE
  PACKAGE=$(yq -r '.package' "$entry_file")
  export ENTRY="$entry_file"
  if [[ -f "$data_file" ]] && [[ -s "$data_file" ]]; then
    schema=$(yq -r '.schema // 0' "$data_file")
    if [[ "$schema" != "2" ]]; then
      echo "Unsupported data.yml schema (expected 2): $schema" >&2
      return 1
    fi
    if yq -e '.packages[] | select(.package == strenv(PACKAGE))' "$data_file" >/dev/null 2>&1; then
      yq -i 'with(.packages[] | select(.package == strenv(PACKAGE)); .signature += load(strenv(ENTRY)).signature)' "$data_file"
      yq -i 'with(.packages[] | select(.package == strenv(PACKAGE)); .signature |= unique_by(.source + "|" + .fingerprint))' "$data_file"
    else
      yq -i '.packages += [load(strenv(ENTRY))]' "$data_file"
    fi
    yq -i '.packages |= sort_by(.package)' "$data_file"
  else
    yq -n '.schema = 2 | .packages = [load(strenv(ENTRY))]' > "$data_file"
  fi
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
    yq -n '.schema = 2 | .packages = []' > "$work_data"
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
