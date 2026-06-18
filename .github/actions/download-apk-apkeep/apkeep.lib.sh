# shellcheck shell=bash
# Shared helpers for downloading APKs with EFF apkeep (Google Play / APKPure).
# Sourced by .github/actions/download-apk-apkeep/action.yml AND scripts/spot_check_reverify.sh
# so the apkeep version, install path and the .xapk-resolution logic live in one place.
#   source "${GITHUB_ACTION_PATH}/apkeep.lib.sh"               # from the action
#   source ".github/actions/download-apk-apkeep/apkeep.lib.sh"  # from the sweep
#
# The Rust toolchain must already be set up by the caller (actions-rust-lang/setup-rust-toolchain)
# before apkeep_install is invoked.

# Pinned apkeep crate version — source of truth for the sweep; the action exposes it as an
# input (default kept in sync) so existing callers keep working.
APKEEP_VERSION="${APKEEP_VERSION:-1.0.0}"

# Install the pinned apkeep via cargo when the matching version is not already present; echo
# the binary path. Pass an explicit version to override (the action forwards its input here).
apkeep_install() {
  local version="${1:-$APKEEP_VERSION}"
  local bin="${HOME}/.cargo/bin/apkeep"
  [[ -n "$version" ]] || version="$APKEEP_VERSION"
  if ! "$bin" --version 2>/dev/null | grep -qF "$version"; then
    cargo install apkeep --version "$version" --locked --force
  fi
  "$bin" --version >&2 || true
  printf '%s' "$bin"
}

# Resolve a scannable base APK from a directory. APKPure often ships .xapk bundles; unzip and
# use the main APK (not split config.*.apk files). Echo the APK path, return 1 when none found.
apkeep_resolve_scannable_apk() {
  local dir="$1"
  local package="$2"

  if [[ -f "${dir}/${package}.apk" ]]; then
    echo "${dir}/${package}.apk"
    return 0
  fi

  local apk
  apk=$(find "$dir" -maxdepth 1 -type f -name '*.apk' ! -name 'config.*' | head -n1)
  if [[ -n "$apk" && -f "$apk" ]]; then
    echo "$apk"
    return 0
  fi

  local xapk
  xapk=$(find "$dir" -maxdepth 1 -type f -name '*.xapk' | head -n1)
  if [[ -z "$xapk" ]]; then
    xapk=$(find "$dir" -type f -name '*.xapk' | head -n1)
  fi
  if [[ -z "$xapk" || ! -f "$xapk" ]]; then
    return 1
  fi

  local extract_dir="${dir}/.xapk-extract"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  echo "Extracting XAPK bundle: $(basename "$xapk")" >&2
  unzip -q -o "$xapk" -d "$extract_dir"

  if [[ -f "${extract_dir}/${package}.apk" ]]; then
    echo "${extract_dir}/${package}.apk"
    return 0
  fi

  local largest=0 main=""
  while IFS= read -r -d '' candidate; do
    local size
    size=$(stat -c%s "$candidate")
    if (( size > largest )); then
      largest=$size
      main=$candidate
    fi
  done < <(find "$extract_dir" -type f -name '*.apk' ! -name 'config.*' -print0)

  if [[ -n "$main" && -f "$main" ]]; then
    echo "$main"
    return 0
  fi
  return 1
}

# Download <package> from <source> (google-play|apk-pure) into <work_dir> with apkeep, then
# resolve a scannable APK and echo its path. Returns 1 when the download fails or no APK
# resolves. Google Play requires <email> and <token>.
apkeep_download() {
  local bin="$1" package="$2" source="$3" work_dir="$4" email="${5:-}" token="${6:-}"
  local log apk_path

  rm -rf "$work_dir"
  mkdir -p "$work_dir"
  log=$(mktemp)

  case "$source" in
    google-play)
      if [[ -z "$email" || -z "$token" ]]; then
        echo "apkeep google-play requires email and token." >&2
        rm -f "$log"
        return 1
      fi
      if ! "$bin" -a "$package" -d google-play -e "$email" -t "$token" "$work_dir" >"$log" 2>&1; then
        cat "$log" >&2 || true
        rm -f "$log"
        return 1
      fi
      ;;
    apk-pure)
      if ! "$bin" -a "$package" -d apk-pure "$work_dir" >"$log" 2>&1; then
        cat "$log" >&2 || true
        rm -f "$log"
        return 1
      fi
      ;;
    *)
      echo "Unsupported apkeep source: ${source}" >&2
      rm -f "$log"
      return 1
      ;;
  esac

  if apk_path=$(apkeep_resolve_scannable_apk "$work_dir" "$package"); then
    rm -f "$log"
    printf '%s' "$apk_path"
    return 0
  fi
  cat "$log" >&2 || true
  rm -f "$log"
  return 1
}
