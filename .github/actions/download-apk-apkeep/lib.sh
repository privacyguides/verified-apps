#!/usr/bin/env bash
# Shared helpers for download-apk-apkeep (sourced, not executed directly).

apkeep_fdroid_repo_hash() {
  printf '%s' "${1%/}" | sha256sum | awk '{print $1}'
}

apkeep_is_official_fdroid_repo() {
  local url="${1%/}"
  [[ "$url" == "https://f-droid.org/repo" ]]
}

apkeep_fdroid_head_etag() {
  local repo="${1%/}"
  local jar_name="$2"
  local etag=""
  etag=$(curl -fsSI --retry 3 --retry-delay 2 "${repo}/${jar_name}" 2>/dev/null | awk -F': ' 'tolower($1) == "etag" { print $2 }' | tr -d '\r\n' | head -n1)
  if [[ -n "$etag" ]]; then
    printf '%s' "$etag"
    return 0
  fi
  return 1
}

# Cache key from repo identity plus ETags of entry.jar and index-v1.jar (any repo may publish both).
apkeep_fdroid_index_cache_key() {
  local repo_url="${1%/}"
  local repo_hash jar etag parts="" fingerprint

  repo_hash=$(apkeep_fdroid_repo_hash "$repo_url")
  for jar in entry.jar index-v1.jar; do
    if etag=$(apkeep_fdroid_head_etag "$repo_url" "$jar"); then
      parts+="${jar}=${etag};"
    fi
  done

  if [[ -z "$parts" ]]; then
    printf 'apkeep-index-%s-unknown' "$repo_hash"
    return 0
  fi

  fingerprint=$(printf '%s' "$parts" | sha256sum | awk '{print $1}')
  printf 'apkeep-index-%s-%s' "$repo_hash" "$fingerprint"
}

apkeep_log_indicates_index_failure() {
  local log_file="$1"
  [[ -f "$log_file" ]] && grep -qE \
    'could not be extracted|Could not verify F-Droid package index|Could not download F-Droid package repository|Could not create temporary directory for F-Droid|Could not find a config directory for apkeep|Could not create a config directory for apkeep|Could not decode JSON for F-Droid|Could not write F-Droid package index' \
    "$log_file"
}

apkeep_find_apk() {
  local work_dir="$1"
  local apkPath=""
  apkPath=$(find "$work_dir" -type f -name '*.apk' ! -name '*config*' | head -n1)
  if [[ -z "$apkPath" ]]; then
    apkPath=$(find "$work_dir" -type f -name '*.apk' | head -n1)
  fi
  if [[ -n "$apkPath" && -f "$apkPath" ]]; then
    printf '%s' "$apkPath"
    return 0
  fi
  return 1
}

apkeep_fdroid_attempt() {
  local apkeep_bin="$1"
  local package="$2"
  local repo_url="$3"
  local work_dir="$4"
  local log_file="$5"
  local use_entry="$6"

  local repo_opt="repo=${repo_url}"
  if [[ "$use_entry" == "false" ]]; then
    repo_opt="${repo_opt},use_entry=false"
  fi

  rm -f "$log_file"
  if "$apkeep_bin" -a "$package" -d f-droid -o "$repo_opt" "$work_dir" >"$log_file" 2>&1; then
    if apkeep_log_indicates_index_failure "$log_file"; then
      return 1
    fi
    return 0
  fi
  return 1
}
