#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "${ACTION_PATH}/lib.sh"

: "${APKEEP_BIN:?}"
: "${PACKAGE_NAME:?}"
: "${FDROID_REPO_URL:?}"
: "${RUNNER_TEMP:?}"

OFFICIAL_FDROID_REPO="https://f-droid.org/repo"
CLOUDFLARE_FDROID_REPO="https://cloudflare.f-droid.org/repo"

work_dir="${RUNNER_TEMP}/apkeep-download"
cache_dir="${RUNNER_TEMP}/apkeep-apk-cache"
index_config_dir="${RUNNER_TEMP}/apkeep-index-config"
download_log="${RUNNER_TEMP}/apkeep-download.log"

mkdir -p "$cache_dir" "$work_dir" "$index_config_dir"
export XDG_CONFIG_HOME="$index_config_dir"

repo_url="${FDROID_REPO_URL:-$OFFICIAL_FDROID_REPO}"
repo_hash=$(apkeep_fdroid_repo_hash "$repo_url")

: "${GITHUB_OUTPUT:?}"

echo "found=false" >> "$GITHUB_OUTPUT"
echo "apkPath=" >> "$GITHUB_OUTPUT"
echo "indexCacheSave=false" >> "$GITHUB_OUTPUT"
echo "indexCacheKey=" >> "$GITHUB_OUTPUT"

if [[ "${CACHE_HIT:-}" == "true" ]]; then
  apkPath=$(find "$cache_dir" -type f -name '*.apk' | head -n1)
  if [[ -n "$apkPath" && -f "$apkPath" ]]; then
    echo "found=true" >> "${GITHUB_OUTPUT}"
    echo "apkPath=$apkPath" >> "${GITHUB_OUTPUT}"
    exit 0
  fi
fi

rm -rf "${work_dir:?}/"*
mkdir -p "$work_dir"

declare -a attempts=()

if apkeep_is_official_fdroid_repo "$repo_url"; then
  attempts+=("${OFFICIAL_FDROID_REPO}|true|official entry.jar")
  attempts+=("${CLOUDFLARE_FDROID_REPO}|true|cloudflare entry.jar")
  attempts+=("${OFFICIAL_FDROID_REPO}|false|official index-v1.jar")
  attempts+=("${CLOUDFLARE_FDROID_REPO}|false|cloudflare index-v1.jar")
else
  attempts+=("${repo_url}|false|use_entry=false")
  attempts+=("${repo_url}|true|use_entry=true")
fi

index_ok=false
winning_repo=""
attempt_idx=0

for spec in "${attempts[@]}"; do
  IFS='|' read -r attempt_repo use_entry attempt_label <<<"$spec"
  echo "Trying F-Droid download (${attempt_label}) from ${attempt_repo}..." >&2

  if (( attempt_idx > 0 )); then
    rm -rf "${index_config_dir:?}/"*
    mkdir -p "$index_config_dir"
  fi
  rm -rf "${work_dir:?}/"*
  mkdir -p "$work_dir"
  attempt_idx=$((attempt_idx + 1))

  if apkeep_fdroid_attempt "$APKEEP_BIN" "$PACKAGE_NAME" "$attempt_repo" "$work_dir" "$download_log" "$use_entry"; then
    index_ok=true
    winning_repo="$attempt_repo"
    echo "F-Droid index OK via ${attempt_label}." >&2
    break
  fi

  cat "$download_log" >&2 || true
  echo "F-Droid attempt failed (${attempt_label})." >&2
done

if [[ "$index_ok" != "true" ]]; then
  echo "All F-Droid download attempts failed for ${repo_url}." >&2
  exit 0
fi

if apkPath=$(apkeep_find_apk "$work_dir"); then
  rm -f "$cache_dir"/*.apk 2>/dev/null || true
  cp "$apkPath" "$cache_dir/$(basename "$apkPath")"
  apkPath="$cache_dir/$(basename "$apkPath")"
  echo "found=true" >> "${GITHUB_OUTPUT}"
  echo "apkPath=$apkPath" >> "${GITHUB_OUTPUT}"
else
  cat "$download_log" >&2 || true
  echo "F-Droid index loaded but APK for ${PACKAGE_NAME} was not downloaded." >&2
fi

if [[ -n "$winning_repo" ]]; then
  cache_key=$(apkeep_fdroid_index_cache_key "$winning_repo")
  if [[ "$cache_key" != *-unknown ]]; then
    echo "indexCacheSave=true" >> "${GITHUB_OUTPUT}"
    echo "indexCacheKey=$cache_key" >> "${GITHUB_OUTPUT}"
  fi
fi
