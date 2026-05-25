# Shared helpers for colon-separated SHA-256 certificate fingerprints.
# Sourced by composite actions: source "${GITHUB_ACTION_PATH}/signatures.lib.sh"
# or sibling actions: source "${GITHUB_ACTION_PATH}/../signature-lib/signatures.lib.sh"

is_valid_package_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]+)+$ ]]
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
  } > "$path"
}
