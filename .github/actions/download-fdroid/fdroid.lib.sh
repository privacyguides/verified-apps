# shellcheck shell=bash
# Shared helpers for downloading APKs from F-Droid repositories with fdroidcl.
# Sourced by .github/actions/download-fdroid/action.yml AND scripts/spot_check_reverify.sh,
# so the fdroidcl version, binary location, and the repo-setup/download commands live in
# exactly one place (change the version or download path here and both callers follow).
#   source "${GITHUB_ACTION_PATH}/fdroid.lib.sh"            # from the action
#   source ".github/actions/download-fdroid/fdroid.lib.sh"  # from the sweep

# Pinned fdroidcl release — the single source of truth for the version and download URL.
FDROIDCL_VERSION="${FDROIDCL_VERSION:-v0.8.1}"

# Download the pinned fdroidcl binary into <dir> (default: current directory) and echo its
# absolute path. Idempotent: skips the download when the binary is already present.
fdroid_install_cli() {
  local dir="${1:-$PWD}"
  local name="fdroidcl_${FDROIDCL_VERSION}_linux_amd64"
  local bin="${dir%/}/${name}"
  if [[ ! -x "$bin" ]]; then
    wget -q -O "$bin" "https://github.com/Hoverth/fdroidcl/releases/download/${FDROIDCL_VERSION}/${name}"
    chmod +x "$bin"
  fi
  printf '%s' "$bin"
}

# Cache-key fragment for an F-Droid repo URL (sha256 of the URL), matching the action's
# per-repo cache scope so the action and any tooling agree on the key.
fdroid_repo_cache_key() {
  printf 'fDroid-%s' "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
}

# Configure fdroidcl to use exactly one repo named "action": drop the bundled f-droid repos
# (and any previously configured "action" repo, so this is safe to call repeatedly when the
# sweep switches between F-Droid, IzzyOnDroid and custom repos), add <url>, refresh the index.
# A result is then attributable to the single configured repo, exactly as the action expects.
fdroid_configure_single_repo() {
  local cli="$1" url="$2"
  "$cli" repo remove f-droid >/dev/null 2>&1 || true
  "$cli" repo remove f-droid-archive >/dev/null 2>&1 || true
  "$cli" repo remove action >/dev/null 2>&1 || true
  "$cli" repo add action "$url"
  "$cli" update
}

# Download <package> from the configured repo(s); echo the resulting APK path, or return 1
# when the package is not available. Mirrors the action's "APK available in <path>" log parse.
fdroid_download_apk() {
  local cli="$1" package="$2" log apk_path
  log=$(mktemp)
  if ! "$cli" download "$package" >"$log" 2>&1; then
    cat "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  apk_path=$(grep '^APK available in ' "$log" | sed 's/^APK available in //' | tail -n1)
  if [[ -z "$apk_path" || ! -f "$apk_path" ]]; then
    cat "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  printf '%s' "$apk_path"
}
