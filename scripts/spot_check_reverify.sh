#!/usr/bin/env bash
#
# Spot-check re-verification sweep.
#
# Re-runs the full verification suite on a random sample of data.yml packages, sequentially
# (one pass per store/repo so each tool/index is set up once and stores are never hit in
# parallel), then reconciles each package:
#
#   - ADD    a source that now verifies a recorded fingerprint but isn't listed for that
#            store yet (e.g. Google Play scannable again, or an old entry predating the
#            domain-verification check). Only for mainstream/authoritative stores
#            (Google Play, F-Droid, IzzyOnDroid, AppVerifier, verified domain) and only
#            when the current signature equals an EXISTING recorded fingerprint.
#   - DELETE a recorded source only on a definitive signature MISMATCH (the store still
#            serves the app but with a signature that no longer matches the recorded
#            fingerprint). App-not-found, download/tool errors and never-before-seen keys
#            are reported informationally and left untouched.
#
# The script only mutates the data files and writes a report; the workflow opens the PR.
# It reuses the existing libraries (signature extraction/compare, domain check, entry
# merge, AppVerifier lookup) and the shared download libs, so version/path/logic live in
# one place.
#
# Environment:
#   PERCENT            Random % of packages to check (0-100). Default 5. Ignored if PACKAGES set.
#   PACKAGES           Optional comma/space-separated package IDs to check instead of a sample.
#   DRY_RUN            "true" to compute + report without mutating the data files.
#   GPLAY_EMAIL,
#   GPLAY_AAS_TOKEN    Google Play credentials (apkeep). Google Play is skipped if unset.
#   DATA_FILE          data.yml path (default: data.yml).
#   DOMAIN_FILE        data-verified-domains.yml path (default: data-verified-domains.yml).
#   RUNNER_TEMP        Scratch dir (default: a mktemp dir).
#   DOH_RESOLVERS,
#   ICANN_ROOT_TRUST_ANCHOR  Consumed by domains.lib.sh for the domain check (set by the workflow).
#   GITHUB_OUTPUT,
#   GITHUB_STEP_SUMMARY      Standard GitHub Actions sinks (optional locally).
#   SPOT_CHECK_MOCK    Optional fixtures dir for offline tests; when set, no network/tools are
#                      used and per-store results are read from fixture files (see README below).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the repo and source the shared libraries.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/actions/signature-lib/signatures.lib.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/actions/domain-verify/domains.lib.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/actions/download-fdroid/fdroid.lib.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/actions/download-apk-apkeep/apkeep.lib.sh"

# ---------------------------------------------------------------------------
# Configuration.
# ---------------------------------------------------------------------------
DATA_FILE="${DATA_FILE:-data.yml}"
DOMAIN_FILE="${DOMAIN_FILE:-data-verified-domains.yml}"
PERCENT="${PERCENT:-5}"
DRY_RUN="${DRY_RUN:-false}"
PACKAGES="${PACKAGES:-}"
MOCK_DIR="${SPOT_CHECK_MOCK:-}"
WORK="${RUNNER_TEMP:-$(mktemp -d)}/spot-check"
mkdir -p "$WORK" "$WORK/model"

FDROID_OFFICIAL_URL="https://f-droid.org/repo"
IZZY_URL="https://apt.izzysoft.de/fdroid/repo"
LOOKUP_PY="${REPO_ROOT}/.github/actions/lookup-appverifier-database/lookup.py"

# Canonical source names (must match data.yml exactly).
SRC_GPLAY="Google Play"
SRC_FDROID="F-Droid"
SRC_IZZY="F-Droid (IzzyOnDroid)"
SRC_APPVERIFIER="AppVerifier"
SRC_APKPURE="Custom (APKPure)"
SRC_DIRECT="Direct APK Link"

log() { printf '%s\n' "$*" >&2; }

is_mock() { [[ -n "$MOCK_DIR" ]]; }

# ---------------------------------------------------------------------------
# Reconciliation output sinks (JSONL) + result store.
# ---------------------------------------------------------------------------
ADDITIONS="${WORK}/additions.jsonl"; : > "$ADDITIONS"
DELETIONS="${WORK}/deletions.jsonl"; : > "$DELETIONS"
INFO="${WORK}/info.jsonl"; : > "$INFO"
DOMAIN_ADDS="${WORK}/domain-adds.jsonl"; : > "$DOMAIN_ADDS"
EVICTIONS="${WORK}/evictions.txt"; : > "$EVICTIONS"  # packages a real apply would remove entirely

declare -A R_STATUS R_SIG R_SHA

result_set() { # pkg store fpkey status sig sha
  local key="$1|$2|$3"
  R_STATUS["$key"]="$4"; R_SIG["$key"]="$5"; R_SHA["$key"]="$6"
}
result_status() { printf '%s' "${R_STATUS["$1|$2|$3"]:-}"; }
result_sig() { printf '%s' "${R_SIG["$1|$2|$3"]:-}"; }
result_sha() { printf '%s' "${R_SHA["$1|$2|$3"]:-}"; }

emit_add() { # pkg fp name issue sha link repo
  jq -cn --arg p "$1" --arg fp "$2" --arg n "$3" --arg i "$4" --arg sha "$5" --arg link "$6" --arg repo "$7" \
    '{package:$p, fingerprint:$fp, name:$n, issue:$i, sha:$sha, link:$link, repo:$repo}' >> "$ADDITIONS"
}
emit_del() { # pkg fp name reason
  jq -cn --arg p "$1" --arg fp "$2" --arg n "$3" --arg r "$4" \
    '{package:$p, fingerprint:$fp, name:$n, reason:$r}' >> "$DELETIONS"
}
emit_info() { # pkg source note
  jq -cn --arg p "$1" --arg s "$2" --arg n "$3" '{package:$p, source:$s, note:$n}' >> "$INFO"
}

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
# Normalized fingerprint key (strip whitespace, uppercase) so multi-cert blocks key stably.
fpkey() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'; }
first_line() { printf '%s' "$1" | head -n1; }

_model() { printf '%s/model/%s.json' "$WORK" "$1"; }
model_sig_count() { jq '.signature | length' "$(_model "$1")"; }
model_fp() { jq -r --argjson i "$2" '.signature[$i].fingerprint' "$(_model "$1")"; }
model_issue() { jq -r --argjson i "$2" '.signature[$i].sources[0].issue // ""' "$(_model "$1")"; }
model_has_name() { jq -e --argjson i "$2" --arg n "$3" '.signature[$i].sources | map(.name) | index($n)' "$(_model "$1")" >/dev/null 2>&1; }
model_link() { jq -r --argjson i "$2" --arg n "$3" 'first(.signature[$i].sources[] | select(.name==$n) | .apk.link) // ""' "$(_model "$1")"; }
model_repo() { jq -r --argjson i "$2" --arg n "$3" 'first(.signature[$i].sources[] | select(.name==$n) | .apk.repo) // ""' "$(_model "$1")"; }
model_direct_indices() { jq -r '.signature | to_entries[] | select(.value.sources | map(.name) | index("Direct APK Link")) | .key' "$(_model "$1")"; }
model_customfdroid() { # echoes "<index>\t<exact source name>" lines
  jq -r '.signature | to_entries[] | .key as $i | .value.sources[]
         | select((.name|test("^F-Droid \\(")) and .name != "F-Droid (IzzyOnDroid)")
         | "\($i)\t\(.name)"' "$(_model "$1")"
}
pkg_has_source() { jq -e --arg n "$2" '[.signature[].sources[].name] | index($n)' "$(_model "$1")" >/dev/null 2>&1; }

# Parse a single key from a GITHUB_OUTPUT-format file (handles key=val and key<<DELIM blocks).
gha_out_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v key="$key" '
    mode==1 { if ($0==delim){mode=0} else { val=val (seen?"\n":"") $0; seen=1 } ; next }
    $0 ~ ("^" key "<<") { delim=substr($0, length(key)+3); mode=1; val=""; seen=0; found=1; next }
    index($0, key "=")==1 { val=substr($0, length(key)+2); found=1 }
    END { if (found) printf "%s", val }
  ' "$file"
}

# ---------------------------------------------------------------------------
# APK signature extraction (mirrors the get-signature action) -> sets SC_*.
# ---------------------------------------------------------------------------
SC_STATUS=""; SC_SIG=""; SC_SHA=""
_finish_apk() { # pkg apk_path
  local pkg="$1" apk="$2" cur sha
  SC_STATUS="unavailable"; SC_SIG=""; SC_SHA=""
  [[ -n "$apk" && -f "$apk" ]] || return 0
  if ! signatures_verify_apk_package "$pkg" "$apk" >/dev/null 2>&1; then
    SC_STATUS="error"; return 0
  fi
  if ! cur=$(signatures_extract_from_apk "$apk" 2>/dev/null); then
    SC_STATUS="error"; return 0
  fi
  sha=$(sha256sum "$apk" | awk '{print $1}')
  SC_STATUS="ok"; SC_SIG="$cur"; SC_SHA="$sha"
}

# Mock store result from fixtures: <pkg>__<store>[__<fpkey>].sig / .error, else unavailable.
mock_apk_check() { # pkg store fpkey
  local base="${MOCK_DIR}/${1}__${2}${3:+__$3}"
  SC_STATUS="unavailable"; SC_SIG=""; SC_SHA=""
  if [[ -f "${base}.sig" ]]; then
    SC_SIG="$(cat "${base}.sig")"
    SC_SHA="$(printf '%s' "$SC_SIG" | sha256sum | awk '{print $1}')"
    SC_STATUS="ok"
  elif [[ -f "${base}.error" ]]; then
    SC_STATUS="error"
  fi
}

# ---------------------------------------------------------------------------
# AppVerifier internal-database lookup -> sets AV_FOUND, AV_ALL.
# ---------------------------------------------------------------------------
AV_FOUND="false"; AV_ALL=""
appverifier_lookup() { # pkg
  AV_FOUND="false"; AV_ALL=""
  if is_mock; then
    if [[ -f "${MOCK_DIR}/${1}__appverifier.all" ]]; then
      AV_FOUND="true"; AV_ALL="$(cat "${MOCK_DIR}/${1}__appverifier.all")"
    fi
    return 0
  fi
  local out; out="${WORK}/av-out"
  : > "$out"
  GITHUB_OUTPUT="$out" python3 "$LOOKUP_PY" "$APPVERIFIER_DB_FILE" "$1" "" >/dev/null 2>&1 || true
  AV_FOUND="$(gha_out_get "$out" found)"
  AV_ALL="$(gha_out_get "$out" allFingerprints)"
  [[ "$AV_FOUND" == "true" ]] || AV_FOUND="false"
}

# True when every certificate in <fp_block> is present in the AppVerifier union <all>.
appverifier_matches_fp() { # fp all
  local fp_norm all_norm line
  fp_norm=$(signatures_normalize "$1") || return 1
  [[ -n "$fp_norm" ]] || return 1
  all_norm=$(signatures_normalize "$2")
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s\n' "$all_norm" | grep -Fxq "$line" || return 1
  done <<< "$fp_norm"
  return 0
}

# ---------------------------------------------------------------------------
# Domain records for a package (array JSON), or non-zero when none.
# ---------------------------------------------------------------------------
domain_records() { # pkg
  if is_mock; then
    [[ -f "${MOCK_DIR}/${1}__domain.json" ]] && cat "${MOCK_DIR}/${1}__domain.json" || return 1
    return 0
  fi
  domain_find_records_for_package "$1"
}

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------
select_packages() {
  if [[ -n "$PACKAGES" ]]; then
    read -ra SELECTED <<< "${PACKAGES//,/ }"
    return 0
  fi
  if ! [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
    log "PERCENT must be an integer 0-100 (got '${PERCENT}')."; exit 1
  fi
  (( PERCENT > 100 )) && PERCENT=100
  local total count
  total=$(yq '.packages | length' "$DATA_FILE")
  count=$(awk -v t="$total" -v p="$PERCENT" 'BEGIN{ c=int((t*p + 99)/100); if (c>t) c=t; print c }')
  if (( count <= 0 )); then
    SELECTED=()
    return 0
  fi
  if ! command -v shuf >/dev/null 2>&1; then
    log "shuf is required for random selection (or pass PACKAGES)."; exit 1
  fi
  mapfile -t SELECTED < <(yq -r '.packages[].package' "$DATA_FILE" | shuf -n "$count")
}

write_models() {
  local pkg
  for pkg in "${SELECTED[@]}"; do
    export MPKG="$pkg"
    yq -o=json -I0 '.packages[] | select(.package == strenv(MPKG))' "$DATA_FILE" > "$(_model "$pkg")" 2>/dev/null || true
    if [[ ! -s "$(_model "$pkg")" || "$(jq -r '.package // ""' "$(_model "$pkg")" 2>/dev/null)" != "$pkg" ]]; then
      log "warning: ${pkg} not found in ${DATA_FILE}; skipping."
      rm -f "$(_model "$pkg")"
    fi
  done
  # Keep only packages that actually resolved to a model.
  local kept=() p
  for p in "${SELECTED[@]}"; do [[ -s "$(_model "$p")" ]] && kept+=("$p"); done
  SELECTED=("${kept[@]}")
}

# ---------------------------------------------------------------------------
# Tool setup.
# ---------------------------------------------------------------------------
GP_ENABLED="false"
APKEEP_BIN=""
FDROIDCL_BIN=""
APPVERIFIER_DB_FILE=""
NEED_APKEEP="false"

setup_tools() {
  if is_mock; then return 0; fi

  if [[ -n "${GPLAY_EMAIL:-}" && -n "${GPLAY_AAS_TOKEN:-}" ]]; then
    GP_ENABLED="true"; NEED_APKEEP="true"
  else
    log "Google Play credentials not set; skipping Google Play checks."
  fi

  # apkeep is also needed if any selected package has an APKPure source to re-check.
  local p
  for p in "${SELECTED[@]}"; do
    if pkg_has_source "$p" "$SRC_APKPURE"; then NEED_APKEEP="true"; break; fi
  done

  if [[ "$NEED_APKEEP" == "true" ]]; then
    APKEEP_BIN="$(apkeep_install)"
  fi
  FDROIDCL_BIN="$(fdroid_install_cli "$WORK")"

  # AppVerifier internal database (single-source the URL from the action default).
  local db_url
  db_url=$(yq -r '.inputs.databaseUrl.default' "${REPO_ROOT}/.github/actions/lookup-appverifier-database/action.yml")
  APPVERIFIER_DB_FILE="${WORK}/InternalVerificationInfoDatabase.kt"
  curl -fsSL --retry 3 --retry-delay 2 -o "$APPVERIFIER_DB_FILE" "$db_url"
}

# ---------------------------------------------------------------------------
# Store passes (sequential; each tool/repo configured once).
# ---------------------------------------------------------------------------
pass_perpkg_apk() { # store source-name downloader-fn [only-if-has-source]
  local store="$1" sname="$2" fn="$3" only_existing="${4:-false}"
  local pkg apk
  for pkg in "${SELECTED[@]}"; do
    if [[ "$only_existing" == "true" ]] && ! pkg_has_source "$pkg" "$sname"; then continue; fi
    if is_mock; then
      mock_apk_check "$pkg" "$store" ""
    else
      apk="$("$fn" "$pkg")" || apk=""
      _finish_apk "$pkg" "$apk"
    fi
    result_set "$pkg" "$store" "" "$SC_STATUS" "$SC_SIG" "$SC_SHA"
  done
}

dl_gplay() { apkeep_download "$APKEEP_BIN" "$1" google-play "${WORK}/gp" "${GPLAY_EMAIL:-}" "${GPLAY_AAS_TOKEN:-}"; }
dl_apkpure() { apkeep_download "$APKEEP_BIN" "$1" apk-pure "${WORK}/apkpure"; }
dl_fdroid() { fdroid_download_apk "$FDROIDCL_BIN" "$1"; }

run_passes() {
  if [[ "$GP_ENABLED" == "true" ]] || is_mock; then
    log "Pass: Google Play (${#SELECTED[@]} packages)"
    pass_perpkg_apk gplay "$SRC_GPLAY" dl_gplay false
  fi

  log "Pass: F-Droid (official)"
  is_mock || fdroid_configure_single_repo "$FDROIDCL_BIN" "$FDROID_OFFICIAL_URL"
  pass_perpkg_apk fdroid "$SRC_FDROID" dl_fdroid false

  log "Pass: F-Droid (IzzyOnDroid)"
  is_mock || fdroid_configure_single_repo "$FDROIDCL_BIN" "$IZZY_URL"
  pass_perpkg_apk izzy "$SRC_IZZY" dl_fdroid false

  if [[ "$NEED_APKEEP" == "true" ]] || is_mock; then
    log "Pass: APKPure (recorded sources only)"
    pass_perpkg_apk apkpure "$SRC_APKPURE" dl_apkpure true
  fi

  log "Pass: Direct APK Link (recorded sources only)"
  local pkg i fp k link dest
  for pkg in "${SELECTED[@]}"; do
    while IFS= read -r i; do
      [[ -z "$i" ]] && continue
      fp=$(model_fp "$pkg" "$i"); k=$(fpkey "$fp")
      if is_mock; then
        mock_apk_check "$pkg" direct "$k"
      else
        link=$(model_link "$pkg" "$i" "$SRC_DIRECT")
        dest="${WORK}/direct.apk"
        if [[ -n "$link" ]] && signatures_download_direct_apk "$link" "$dest" >/dev/null 2>&1; then
          _finish_apk "$pkg" "$dest"
        else
          SC_STATUS="unavailable"; SC_SIG=""; SC_SHA=""
        fi
      fi
      result_set "$pkg" direct "$k" "$SC_STATUS" "$SC_SIG" "$SC_SHA"
    done < <(model_direct_indices "$pkg")
  done

  log "Pass: custom F-Droid repos (recorded sources only)"
  # Collect tuples then group by repo URL so each custom index is fetched once.
  local tuples="${WORK}/custom-fdroid.tsv"; : > "$tuples"
  for pkg in "${SELECTED[@]}"; do
    while IFS=$'\t' read -r i name; do
      [[ -z "$i" ]] && continue
      fp=$(model_fp "$pkg" "$i"); k=$(fpkey "$fp")
      local repo; repo=$(model_repo "$pkg" "$i" "$name")
      [[ -z "$repo" ]] && continue
      printf '%s\t%s\t%s\n' "$repo" "$pkg" "$k" >> "$tuples"
    done < <(model_customfdroid "$pkg")
  done
  if [[ -s "$tuples" ]]; then
    local repo
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      is_mock || fdroid_configure_single_repo "$FDROIDCL_BIN" "$repo"
      while IFS=$'\t' read -r r p kk; do
        [[ "$r" == "$repo" ]] || continue
        if is_mock; then
          mock_apk_check "$p" customfdroid "$kk"
        else
          local apk; apk="$(dl_fdroid "$p")" || apk=""
          _finish_apk "$p" "$apk"
        fi
        result_set "$p" customfdroid "$kk" "$SC_STATUS" "$SC_SIG" "$SC_SHA"
      done < "$tuples"
    done < <(cut -f1 "$tuples" | sort -u)
  fi
}

# ---------------------------------------------------------------------------
# Reconciliation.
# ---------------------------------------------------------------------------
# True when <sig> is the SAME signing identity as ANY recorded fingerprint block of <pkg> — equal,
# or sharing >=1 certificate (rotation lineage). Used as the "matched_any" guard for the per-block
# passes (direct / custom F-Droid): a re-fetched key that matches NO recorded block is an ambiguous
# rotation/availability case and must never drive an auto-deletion (which could evict the package).
sig_recognized_for_pkg() { # pkg sig
  local pkg="$1" sig="$2" n i fp
  n=$(model_sig_count "$pkg")
  for ((i = 0; i < n; i++)); do
    fp=$(model_fp "$pkg" "$i")
    if signatures_equal "$sig" "$fp" || signatures_overlap "$sig" "$fp"; then return 0; fi
  done
  return 1
}

# Per-package store with one current signature (Google Play, F-Droid, IzzyOnDroid, APKPure).
reconcile_perpkg() { # pkg store sname allow_add
  local pkg="$1" store="$2" sname="$3" allow_add="$4"
  local st has_src; st=$(result_status "$pkg" "$store" "")
  [[ -z "$st" ]] && return 0
  has_src=0; pkg_has_source "$pkg" "$sname" && has_src=1
  if [[ "$allow_add" != "true" && "$has_src" == 0 ]]; then return 0; fi

  if [[ "$st" == "ok" ]]; then
    local sig sha n i j fp matched_any=0 exempt
    sig=$(result_sig "$pkg" "$store" ""); sha=$(result_sha "$pkg" "$store" "")
    n=$(model_sig_count "$pkg")

    # A store serves ONE signature. Classify each recorded block by whether the served set is the
    # SAME signing identity: equal, OR sharing >=1 certificate (a key-rotation lineage — apksigner
    # reports the whole lineage, so a base block and its rotated superset each "cover" the other).
    # covered[i]=1 marks blocks the store still attests; those are never deletion candidates. This
    # mirrors the repo's existing fingerprint_covered() = equal OR overlap semantics
    # (.github/scripts/_import_common.py). Strict set-equality here wrongly split lineage pairs and
    # could evict a legitimate block (verified live on com.fidelity.android) — do NOT reintroduce it.
    local -a covered=()
    for ((i = 0; i < n; i++)); do
      fp=$(model_fp "$pkg" "$i")
      if signatures_equal "$sig" "$fp"; then
        covered[i]=1; matched_any=1
        # ADD only on an EXACT fingerprint match (unchanged, conservative policy).
        if [[ "$allow_add" == "true" ]] && ! model_has_name "$pkg" "$i" "$sname"; then
          emit_add "$pkg" "$fp" "$sname" "$(model_issue "$pkg" "$i")" "$sha" "" ""
        fi
      elif signatures_overlap "$sig" "$fp"; then
        covered[i]=1; matched_any=1
      else
        covered[i]=0
      fi
    done

    # DELETE a recorded source ONLY on a genuine, lineage-unrelated substitution:
    #   (1) the served signature is recognized for this package (matched_any), so we never act on an
    #       unknown key from a transient / region-locked / freshly-rotated download; AND
    #   (2) this block shares no certificate with the served set; AND
    #   (3) no sibling block the store currently serves shares a certificate with this block
    #       (so a base<->rotated lineage pair is never split).
    # A WHOLLY unrecognized served key (matched_any==0) is left as an informational note for a human,
    # never auto-deleted — that path is exactly where benign key rotation looks like a "mismatch".
    if [[ "$matched_any" == 1 ]]; then
      for ((i = 0; i < n; i++)); do
        [[ "${covered[i]}" == 1 ]] && continue
        model_has_name "$pkg" "$i" "$sname" || continue
        fp=$(model_fp "$pkg" "$i")
        exempt=0
        for ((j = 0; j < n; j++)); do
          [[ "$j" == "$i" || "${covered[j]}" != 1 ]] && continue
          if signatures_overlap "$fp" "$(model_fp "$pkg" "$j")"; then exempt=1; break; fi
        done
        if [[ "$exempt" == 1 ]]; then
          emit_info "$pkg" "$sname" "store serves a key in the same rotation lineage; recorded block left as-is: $(first_line "$fp")"
        else
          emit_del "$pkg" "$fp" "$sname" "store serves an unrelated signature and no longer attests this recorded key"
        fi
      done
    fi
    if [[ "$has_src" == 1 && "$matched_any" == 0 ]]; then
      emit_info "$pkg" "$sname" "now serves an unrecorded signature (recorded key may have rotated); left as-is for manual review: $(first_line "$sig")"
    fi
  elif [[ "$has_src" == 1 ]]; then
    if [[ "$st" == "error" ]]; then
      emit_info "$pkg" "$sname" "re-check error; left as-is"
    else
      emit_info "$pkg" "$sname" "app not available to re-check; left as-is (not a mismatch)"
    fi
  fi
}

reconcile_direct() { # pkg
  local pkg="$1" i fp k st sig
  while IFS= read -r i; do
    [[ -z "$i" ]] && continue
    fp=$(model_fp "$pkg" "$i"); k=$(fpkey "$fp")
    st=$(result_status "$pkg" direct "$k"); [[ -z "$st" ]] && continue
    if [[ "$st" == "ok" ]]; then
      sig=$(result_sig "$pkg" direct "$k")
      if signatures_equal "$sig" "$fp" || signatures_overlap "$sig" "$fp"; then
        :  # still attests this block (lineage-tolerant); keep
      elif sig_recognized_for_pkg "$pkg" "$sig"; then
        emit_del "$pkg" "$fp" "$SRC_DIRECT" "linked APK now serves a different recorded key; no longer attests this fingerprint"
      else
        # Unrecognized key: ambiguous benign-rotation vs swapped-URL — never auto-evict; leave for a
        # human. Same matched_any guard as reconcile_perpkg (do NOT reduce to a bare delete-on-mismatch).
        emit_info "$pkg" "$SRC_DIRECT" "linked APK now serves an unrecognized signature; left as-is for manual review"
      fi
    else
      emit_info "$pkg" "$SRC_DIRECT" "could not re-download the linked APK; left as-is"
    fi
  done < <(model_direct_indices "$pkg")
}

reconcile_customfdroid() { # pkg
  local pkg="$1" i name fp k st sig
  while IFS=$'\t' read -r i name; do
    [[ -z "$i" ]] && continue
    fp=$(model_fp "$pkg" "$i"); k=$(fpkey "$fp")
    st=$(result_status "$pkg" customfdroid "$k"); [[ -z "$st" ]] && continue
    if [[ "$st" == "ok" ]]; then
      sig=$(result_sig "$pkg" customfdroid "$k")
      if signatures_equal "$sig" "$fp" || signatures_overlap "$sig" "$fp"; then
        :  # still attests this block (lineage-tolerant); keep
      elif sig_recognized_for_pkg "$pkg" "$sig"; then
        emit_del "$pkg" "$fp" "$name" "custom F-Droid repo now serves a different recorded key; no longer attests this fingerprint"
      else
        # Unrecognized key: never auto-evict; leave for a human. Same guard as reconcile_perpkg.
        emit_info "$pkg" "$name" "custom F-Droid repo now serves an unrecognized signature; left as-is for manual review"
      fi
    else
      emit_info "$pkg" "$name" "could not re-check the custom F-Droid repo; left as-is"
    fi
  done < <(model_customfdroid "$pkg")
}

reconcile_appverifier() { # pkg
  local pkg="$1" n i fp match has
  appverifier_lookup "$pkg"
  n=$(model_sig_count "$pkg")
  for ((i = 0; i < n; i++)); do
    fp=$(model_fp "$pkg" "$i")
    match=0
    if [[ "$AV_FOUND" == "true" ]] && appverifier_matches_fp "$fp" "$AV_ALL"; then match=1; fi
    has=0; model_has_name "$pkg" "$i" "$SRC_APPVERIFIER" && has=1
    if [[ "$match" == 1 && "$has" == 0 ]]; then
      emit_add "$pkg" "$fp" "$SRC_APPVERIFIER" "$(model_issue "$pkg" "$i")" "" "" ""
    elif [[ "$match" == 0 && "$has" == 1 ]]; then
      if [[ "$AV_FOUND" == "true" ]]; then
        emit_del "$pkg" "$fp" "$SRC_APPVERIFIER" "no longer listed in AppVerifier's internal database for this key"
      else
        emit_info "$pkg" "$SRC_APPVERIFIER" "package no longer in AppVerifier's internal database; left as-is"
      fi
    fi
  done
}

reconcile_domain() { # pkg
  local pkg="$1" recs auth method dsrc n i fp cnt r rec allowed_auth allowed_any srcname domain dnssec fps issue domain_added=0
  recs=$(domain_records "$pkg") || recs=""
  if [[ -z "$recs" ]]; then
    if pkg_has_source "$pkg" "HTTPS Verified Domain" || pkg_has_source "$pkg" "DNS Verified Domain"; then
      emit_info "$pkg" "Verified Domain" "no current domain verification record found; left as-is"
    fi
    return 0
  fi
  auth=$(jq -c '.[0]' <<< "$recs")
  method=$(jq -r '.method' <<< "$auth")
  dsrc=$(domain_source_name "$method")
  cnt=$(jq 'length' <<< "$recs")
  n=$(model_sig_count "$pkg")
  for ((i = 0; i < n; i++)); do
    fp=$(model_fp "$pkg" "$i")
    allowed_auth=0
    [[ "$(domain_key_status "$auth" "$fp")" == "allowed" ]] && allowed_auth=1
    allowed_any="$allowed_auth"
    if [[ "$allowed_any" == 0 ]]; then
      for ((r = 0; r < cnt; r++)); do
        rec=$(jq -c ".[$r]" <<< "$recs")
        if [[ "$(domain_key_status "$rec" "$fp")" == "allowed" ]]; then allowed_any=1; break; fi
      done
    fi
    if [[ "$allowed_auth" == 1 ]] && ! model_has_name "$pkg" "$i" "$dsrc"; then
      issue=$(model_issue "$pkg" "$i")
      emit_add "$pkg" "$fp" "$dsrc" "$issue" "" "" ""
      domain_added=1
    fi
    for srcname in "HTTPS Verified Domain" "DNS Verified Domain"; do
      if [[ "$allowed_any" == 0 ]] && model_has_name "$pkg" "$i" "$srcname"; then
        emit_del "$pkg" "$fp" "$srcname" "domain record no longer vouches for this key"
      fi
    done
  done
  if [[ "$domain_added" == 1 ]]; then
    domain=$(jq -r '.domain' <<< "$auth")
    dnssec=$(jq -r 'if .method == "dns" then (.dnssec | tostring) else "" end' <<< "$auth")
    fps=$(jq -c '.allowed' <<< "$auth")
    issue=$(model_issue "$pkg" 0)
    jq -cn --arg p "$pkg" --arg d "$domain" --arg m "$method" --arg i "$issue" --arg ds "$dnssec" --argjson fps "$fps" \
      '{package:$p, domain:$d, method:$m, issue:$i, dnssec:$ds, fps:$fps}' >> "$DOMAIN_ADDS"
  fi
}

reconcile() {
  local pkg
  for pkg in "${SELECTED[@]}"; do
    log "Reconciling ${pkg}"
    reconcile_perpkg "$pkg" gplay "$SRC_GPLAY" true
    reconcile_perpkg "$pkg" fdroid "$SRC_FDROID" true
    reconcile_perpkg "$pkg" izzy "$SRC_IZZY" true
    reconcile_perpkg "$pkg" apkpure "$SRC_APKPURE" false
    reconcile_direct "$pkg"
    reconcile_customfdroid "$pkg"
    reconcile_appverifier "$pkg"
    reconcile_domain "$pkg"
  done
}

# ---------------------------------------------------------------------------
# Apply mutations to the data files.
# ---------------------------------------------------------------------------
apply_additions() {
  [[ -s "$ADDITIONS" ]] || return 0
  local line pkg fp name issue sha link repo proposals entry
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkg=$(jq -r '.package' <<< "$line"); fp=$(jq -r '.fingerprint' <<< "$line")
    name=$(jq -r '.name' <<< "$line"); issue=$(jq -r '.issue' <<< "$line")
    sha=$(jq -r '.sha' <<< "$line"); link=$(jq -r '.link' <<< "$line"); repo=$(jq -r '.repo' <<< "$line")
    proposals=$(mktemp); entry=$(mktemp)
    _submission_add_proposal "$proposals" "$fp" "$name" "$issue" "$sha" "$link" "$repo"
    _submission_assemble_entry_from_proposals "$proposals" "$entry" "$pkg"
    submission_merge_entry_into_data_yml "$entry" "$DATA_FILE"
    rm -f "$proposals" "$entry"
  done < "$ADDITIONS"
}

apply_domain_ledger() {
  [[ -s "$DOMAIN_ADDS" ]] || return 0
  local checked line pkg domain method issue dnssec fps
  checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkg=$(jq -r '.package' <<< "$line"); domain=$(jq -r '.domain' <<< "$line")
    method=$(jq -r '.method' <<< "$line"); issue=$(jq -r '.issue' <<< "$line")
    dnssec=$(jq -r '.dnssec' <<< "$line"); fps=$(jq -c '.fps' <<< "$line")
    domain_verified_upsert "$DOMAIN_FILE" "$domain" "$method" "$pkg" "$issue" "$checked" "$dnssec" "$fps"
  done < "$DOMAIN_ADDS"
}

apply_deletions() {
  [[ -s "$DELETIONS" ]] || return 0
  local line pkg fp name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkg=$(jq -r '.package' <<< "$line"); fp=$(jq -r '.fingerprint' <<< "$line"); name=$(jq -r '.name' <<< "$line")
    signatures_remove_source "$DATA_FILE" "$pkg" "$fp" "$name"
  done < "$DELETIONS"
  signatures_prune_empty "$DATA_FILE"
}

# Record which packages the proposed deletions would remove ENTIRELY (last source gone ->
# signatures_prune_empty drops the package). Simulated on a copy so it works in dry-run too and
# must be called BEFORE the data file is mutated. Additions never offset an eviction: additions
# target equal/covered blocks while deletions only target uncovered blocks, so they are disjoint.
compute_evictions() {
  : > "$EVICTIONS"
  [[ -s "$DELETIONS" ]] || return 0
  local sim line pkg fp name
  sim="${WORK}/evict-sim.yml"
  cp "$DATA_FILE" "$sim"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkg=$(jq -r '.package' <<< "$line"); fp=$(jq -r '.fingerprint' <<< "$line"); name=$(jq -r '.name' <<< "$line")
    signatures_remove_source "$sim" "$pkg" "$fp" "$name"
  done < "$DELETIONS"
  signatures_prune_empty "$sim"
  comm -23 <(yq -r '.packages[].package' "$DATA_FILE" | sort -u) \
           <(yq -r '.packages[].package' "$sim" | sort -u) > "$EVICTIONS"
  rm -f "$sim"
}

# ---------------------------------------------------------------------------
# Reporting.
# ---------------------------------------------------------------------------
count_lines() { [[ -s "$1" ]] && wc -l < "$1" | tr -d '[:space:]' || printf '0'; }

report() {
  local add_n del_n info_n evict_n body ev
  add_n=$(count_lines "$ADDITIONS"); del_n=$(count_lines "$DELETIONS"); info_n=$(count_lines "$INFO")
  evict_n=$(count_lines "$EVICTIONS")
  body="${WORK}/pr-body.md"
  {
    echo "## Spot-check re-verification"
    echo ""
    echo "Re-checked **${#SELECTED[@]}** package(s)$( [[ -z "$PACKAGES" ]] && echo " (~${PERCENT}% random sample)" )."
    echo ""
    echo "- :heavy_plus_sign: Additions applied: **${add_n}**"
    echo "- :x: Source removals proposed: **${del_n}**$( [[ "$evict_n" -gt 0 ]] && echo " — :rotating_light: including **${evict_n}** full package eviction(s)" )"
    echo "- :information_source: Informational notes: **${info_n}**"
    echo ""
    if [[ "$add_n" -gt 0 ]]; then
      echo "### :heavy_plus_sign: Additions applied"
      echo ""
      echo "| Package | Fingerprint | Source |"
      echo "|---|---|---|"
      jq -r '"| `\(.package)` | `\(.fingerprint | split("\n")[0][0:23])…` | \(.name) |"' "$ADDITIONS"
      echo ""
    fi
    if [[ "$evict_n" -gt 0 ]]; then
      echo "### :rotating_light: Package evictions — these entries are removed ENTIRELY"
      echo ""
      echo "> The removals below take the LAST recorded source of these package(s), so the whole entry"
      echo "> disappears from \`data.yml\`. Review each as a full de-listing, not a source tweak."
      echo ""
      while IFS= read -r ev; do [[ -n "$ev" ]] && echo "- \`${ev}\`"; done < "$EVICTIONS"
      echo ""
    fi
    if [[ "$del_n" -gt 0 ]]; then
      echo "### :x: Source removals proposed"
      echo ""
      echo "> A store/source no longer attests the recorded key — it serves an unrelated signature with"
      echo "> no shared certificate. Key-rotation lineages (a base key and its rotated successor) are"
      echo "> intentionally NOT removed. The \"Evicts package\" column flags removals that delete the"
      echo "> entire entry."
      echo ""
      echo "| Package | Fingerprint | Source | Reason | Evicts package |"
      echo "|---|---|---|---|---|"
      jq -r --rawfile ev "$EVICTIONS" '
        ($ev | split("\n") | map(select(length > 0))) as $evset
        | "| `\(.package)` | `\(.fingerprint | split("\n")[0][0:23])…` | \(.name) | \(.reason) | \(if (.package | IN($evset[])) then ":rotating_light: YES — entire app removed" else "no" end) |"' "$DELETIONS"
      echo ""
    fi
    if [[ "$info_n" -gt 0 ]]; then
      echo "### :information_source: For review (informational — no changes made)"
      echo ""
      echo "| Package | Source | Note |"
      echo "|---|---|---|"
      jq -r '"| `\(.package)` | \(.source) | \(.note) |"' "$INFO"
      echo ""
    fi
    if [[ "$add_n" -eq 0 && "$del_n" -eq 0 ]]; then
      echo "_No additions or deletions; informational notes only (if any)._"
    fi
  } > "$body"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$body" >> "$GITHUB_STEP_SUMMARY"; fi

  local has_changes="false"
  [[ "$add_n" -gt 0 || "$del_n" -gt 0 ]] && has_changes="true"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "hasChanges=${has_changes}"
      echo "additions=${add_n}"
      echo "deletions=${del_n}"
      echo "evictions=${evict_n}"
      echo "infos=${info_n}"
      echo "selected=${#SELECTED[@]}"
      echo "prBody=${body}"
    } >> "$GITHUB_OUTPUT"
  fi
  log "Done: ${add_n} addition(s), ${del_n} deletion(s), ${info_n} note(s) across ${#SELECTED[@]} package(s)."
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
SELECTED=()
select_packages
if [[ "${#SELECTED[@]}" -eq 0 ]]; then
  log "No packages selected (percent=${PERCENT}); nothing to do."
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'hasChanges=false\nselected=0\n' >> "$GITHUB_OUTPUT"
  exit 0
fi
write_models
if [[ "${#SELECTED[@]}" -eq 0 ]]; then
  log "No selected packages resolved in ${DATA_FILE}; nothing to do."
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'hasChanges=false\nselected=0\n' >> "$GITHUB_OUTPUT"
  exit 0
fi

log "Selected ${#SELECTED[@]} package(s) for spot-check re-verification."
setup_tools
run_passes
reconcile
compute_evictions  # before any mutation, so dry-run and live both report full-package removals

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY_RUN=true; computed changes but not mutating data files."
else
  apply_additions
  apply_domain_ledger
  apply_deletions
fi

report
