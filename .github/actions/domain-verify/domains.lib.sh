# Shared helpers for domain-based app verification.
# A developer proves control of a domain by publishing the app's signing key(s) either:
#   - HTTPS: https://<domain>/.well-known/org.privacyguides.verified-apps.json
#            { "version": 1, "signingkeys": { "allowed": [...], "revoked": [...] } }
#   - DNS:   TXT records at _pgappverify.<domain> (one key set per record; allowed only)
#
# Sourced by composite actions alongside signatures.lib.sh:
#   source "${GITHUB_ACTION_PATH}/domains.lib.sh"
# It pulls in signatures.lib.sh (for normalization/comparison) when not already loaded.

_DOMAIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f signatures_format_block >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${_DOMAIN_LIB_DIR}/../signature-lib/signatures.lib.sh"
fi

DOMAIN_WELLKNOWN_PATH=".well-known/org.privacyguides.verified-apps.json"
DOMAIN_DNS_PREFIX="_pgappverify"
DOMAIN_VERIFIED_FILE="data-verified-domains.yml"
DOMAIN_VERIFIED_SCHEMA=1
DOMAIN_SOURCE_NAME="Verified Domain"
# DNS-over-HTTPS query helper (RFC 8484 wire format via curl/HTTP2) and interpreter.
# The list of resolvers it queries is controlled by the DOH_RESOLVERS env var, set
# (hard-coded) in the calling workflows; all of them must agree on the TXT record.
DOMAIN_PYTHON="${DOMAIN_PYTHON:-python3}"
DOMAIN_DOH_HELPER="${DOMAIN_DOH_HELPER:-${_DOMAIN_LIB_DIR}/doh_query.py}"

# --- Namespace helpers --------------------------------------------------------

# Reverse dot-separated labels: org.privacyguides.app <-> app.privacyguides.org
domain_reverse_labels() {
  printf '%s' "$1" | awk -F. '{ for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? "." : "") }'
}

# Candidate domains to probe for a package, most specific first, down to a 2-label root.
# org.privacyguides.app -> app.privacyguides.org, privacyguides.org
domain_candidates_from_package() {
  local pkg="$1"
  local rev labels
  rev=$(domain_reverse_labels "$pkg")
  while [[ -n "$rev" ]]; do
    labels=$(printf '%s' "$rev" | awk -F. '{print NF}')
    [[ "$labels" -ge 2 ]] || break
    printf '%s\n' "$rev"
    [[ "$rev" == *.* ]] || break
    rev="${rev#*.}"
  done
}

# True when reverse(domain) equals the package or is a dot-boundary prefix of it.
domain_covers_package() {
  local domain="$1" pkg="$2"
  local ns
  ns=$(domain_reverse_labels "$domain")
  [[ -n "$ns" ]] || return 1
  [[ "$pkg" == "$ns" || "$pkg" == "$ns".* ]]
}

# --- Issue form parsing -------------------------------------------------------

# Collapse a block of text to newline-joined fingerprints in their original order.
# Strips code fences and "_No response_"; returns 1 when no fingerprint is present.
_domain_fingerprint_block_from_text() {
  local text="$1" line tok out=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == '```'* ]] && continue
    [[ "$line" == "_No response_" ]] && continue
    while IFS= read -r tok; do
      [[ -z "$tok" ]] && continue
      [[ -n "$out" ]] && out+=$'\n'
      out+="$tok"
    done < <(append_fingerprint_tokens "$line")
  done <<< "$text"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# Extract a "### <header>" section body from an issue form body (until the next "### ").
_domain_issue_section() {
  local header="$1" body="$2"
  printf '%s\n' "$body" | awk -v h="### ${header}" '
    $0 == h { found = 1; next }
    found && /^### / { exit }
    found { print }
  '
}

# Parse the four Signing Key fields into a JSON array of key-set strings (one per field,
# multi-cert sets keep their internal newlines). Reuses the issue form section headers.
domain_parse_signing_keys() {
  local body="$1"
  local keys_json="[]"
  local header section block
  for header in "Signing Key" "Signing Key 2" "Signing Key 3" "Signing Key 4"; do
    section=$(_domain_issue_section "$header" "$body")
    block=$(_domain_fingerprint_block_from_text "$section") || continue
    [[ -z "$block" ]] && continue
    keys_json=$(jq -c --arg k "$block" '. + [$k]' <<< "$keys_json")
  done
  printf '%s' "$keys_json"
}

# Read the Domain Name field, trimmed and lowercased.
domain_parse_domain_name() {
  local body="$1" value
  value=$(_domain_issue_section "Domain Name" "$body" | awk 'NF {print; exit}')
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ -z "$value" || "$value" == "_No response_" ]] && return 1
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

# --- Instructions comment -----------------------------------------------------

# Render the developer-facing setup instructions for both methods from parsed keys.
domain_render_instructions() {
  local domain="$1" keys_json="$2"
  local json dns_lines count i key oneline

  json=$(jq --indent 4 -n --argjson keys "$keys_json" \
    '{version: 1, signingkeys: {allowed: $keys}}')

  dns_lines=""
  count=$(jq 'length' <<< "$keys_json")
  for ((i = 0; i < count; i++)); do
    key=$(jq -r ".[$i]" <<< "$keys_json")
    oneline=$(printf '%s' "$key" | tr '\n' ' ')
    dns_lines+="$(printf '%s.%s.   IN   TXT   "%s"' "$DOMAIN_DNS_PREFIX" "$domain" "$oneline")"$'\n'
  done

  cat <<EOF
Thanks for your domain verification request! To prove you control \`${domain}\`, set up **one** of the two methods below using your app's signing key(s). Reply to this issue once the record is live and we'll verify it (we also re-check open requests automatically every day).

### Option 1 — HTTPS file (recommended)

Upload a JSON file to:

\`https://${domain}/${DOMAIN_WELLKNOWN_PATH}\`

with exactly these contents:

\`\`\`json
${json}
\`\`\`

### Option 2 — DNS TXT record(s)

Alternatively, add the following TXT record(s) to \`${DOMAIN_DNS_PREFIX}.${domain}\`:

\`\`\`
$(printf '%s' "$dns_lines")
\`\`\`

When you've created the record (either method), leave a comment here and we'll check it.
EOF
}

# --- Record discovery ---------------------------------------------------------

# Normalize a JSON array of key-set strings into normalized fingerprint blocks.
_domain_normalize_entry_array() {
  local arr="$1"
  local out="[]" count i entry norm
  count=$(jq 'length' <<< "$arr")
  for ((i = 0; i < count; i++)); do
    entry=$(jq -r ".[$i]" <<< "$arr")
    norm=$(signatures_format_block "$entry") || continue
    out=$(jq -c --arg n "$norm" '. + [$n]' <<< "$out")
  done
  printf '%s' "$out"
}

# Build a normalized record object from a JSON document body.
_domain_record_from_json() {
  local body="$1" method="$2" domain="$3" source="$4"
  printf '%s' "$body" | jq -e . >/dev/null 2>&1 || return 1
  local allowed_raw revoked_raw allowed_norm revoked_norm total
  allowed_raw=$(printf '%s' "$body" | jq -c '.signingkeys.allowed // []' 2>/dev/null) || return 1
  revoked_raw=$(printf '%s' "$body" | jq -c '.signingkeys.revoked // []' 2>/dev/null) || revoked_raw="[]"
  allowed_norm=$(_domain_normalize_entry_array "$allowed_raw")
  revoked_norm=$(_domain_normalize_entry_array "$revoked_raw")
  total=$(jq -n --argjson a "$allowed_norm" --argjson r "$revoked_norm" '($a | length) + ($r | length)')
  [[ "$total" -gt 0 ]] || return 1
  jq -n --arg method "$method" --arg domain "$domain" --arg source "$source" \
    --argjson allowed "$allowed_norm" --argjson revoked "$revoked_norm" \
    '{found: true, method: $method, domain: $domain, source: $source, allowed: $allowed, revoked: $revoked}'
}

# Fetch and normalize the HTTPS .well-known record for a domain.
domain_fetch_https_record() {
  local domain="$1"
  local url="https://${domain}/${DOMAIN_WELLKNOWN_PATH}"
  local body
  body=$(curl -fsSL --max-time 20 --retry 2 --retry-delay 1 "$url" 2>/dev/null) || return 1
  _domain_record_from_json "$body" "https" "$domain" "$url"
}

# Validate DNSSEC for a name back to the hard-coded ICANN root trust anchor using delv.
# The anchor is supplied via DOMAIN_DNSSEC_ANCHOR (file path) or ICANN_ROOT_TRUST_ANCHOR
# (inline trust-anchors{} content, written to a temp file). delv is lazily installed on
# CI runners when missing. Echoes "true" only when delv reports the record fully validated
# to the anchor; otherwise "false" (unsigned, bogus, or tooling unavailable).
domain_dnssec_status() {
  local name="$1"
  local anchor_file="${DOMAIN_DNSSEC_ANCHOR:-}"
  local resolver="${DOMAIN_DNSSEC_RESOLVER:-1.1.1.1}"

  if [[ -z "$anchor_file" ]]; then
    if [[ -n "${ICANN_ROOT_TRUST_ANCHOR:-}" ]]; then
      anchor_file="${TMPDIR:-/tmp}/icann-root-anchor.$$.conf"
      printf '%s\n' "$ICANN_ROOT_TRUST_ANCHOR" > "$anchor_file"
    else
      echo "DNSSEC: no trust anchor configured (ICANN_ROOT_TRUST_ANCHOR unset); recording dnssec=false" >&2
      printf 'false'; return 0
    fi
  fi

  if ! command -v delv >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y -q bind9-dnsutils >/dev/null 2>&1 \
      || sudo apt-get install -y -q dnsutils >/dev/null 2>&1 || true
  fi
  if ! command -v delv >/dev/null 2>&1; then
    echo "DNSSEC: delv unavailable; recording dnssec=false for ${name}" >&2
    printf 'false'; return 0
  fi

  local out
  out=$(delv -a "$anchor_file" @"$resolver" "$name" TXT +rtrace 2>&1) || true
  if printf '%s\n' "$out" | grep -q '; fully validated'; then
    printf 'true'
  else
    echo "DNSSEC: ${name} not fully validated to ICANN root (recording dnssec=false)" >&2
    printf 'false'
  fi
}

# Fetch DNS verification records at _pgappverify.<domain> over DNS-over-HTTPS, requiring
# every configured resolver to agree, then attach a DNSSEC validation status. allowed only.
domain_fetch_dns_record() {
  local domain="$1"
  local name="${DOMAIN_DNS_PREFIX}.${domain}"
  local result agree n i rec norm allowed="[]" count dnssec

  result=$("$DOMAIN_PYTHON" "$DOMAIN_DOH_HELPER" "$name" 2>/dev/null) || {
    echo "DNS: DoH query failed or resolvers disagreed for ${name}" >&2
    return 1
  }
  agree=$(jq -r '.agree' <<< "$result")
  if [[ "$agree" != "true" ]]; then
    echo "DNS: resolvers did not agree for ${name}: $(jq -r '.reason // "unknown"' <<< "$result")" >&2
    return 1
  fi

  n=$(jq -r '.records | length' <<< "$result")
  for ((i = 0; i < n; i++)); do
    rec=$(jq -r ".records[$i]" <<< "$result")
    norm=$(signatures_format_block "$rec") || continue
    allowed=$(jq -c --arg n "$norm" '. + [$n]' <<< "$allowed")
  done
  count=$(jq 'length' <<< "$allowed")
  [[ "$count" -gt 0 ]] || return 1

  dnssec=$(domain_dnssec_status "$name")
  jq -n --arg domain "$domain" --arg source "$name" --arg dnssec "$dnssec" --argjson allowed "$allowed" \
    '{found: true, method: "dns", domain: $domain, source: $source, allowed: $allowed, revoked: [], dnssec: ($dnssec == "true")}'
}

# Probe a single explicit domain (HTTPS first, then DNS). Echoes the record JSON.
domain_find_record_for_domain() {
  local domain="$1" rec
  if rec=$(domain_fetch_https_record "$domain"); then printf '%s' "$rec"; return 0; fi
  if rec=$(domain_fetch_dns_record "$domain"); then printf '%s' "$rec"; return 0; fi
  return 1
}

# Probe every candidate domain for a package, most specific first, collecting every
# record found. Echoes a JSON array ordered most specific first; the FIRST element is
# the authoritative record — a record on a more specific domain shadows its parents,
# so later elements are reported in the summary table but never used for matching.
# Returns 1 when no candidate domain has a record.
domain_find_records_for_package() {
  local pkg="$1" domain rec records="[]"
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    rec=$(domain_find_record_for_domain "$domain") || continue
    records=$(jq -c --argjson r "$rec" '. + [$r]' <<< "$records")
  done < <(domain_candidates_from_package "$pkg")
  [[ "$(jq 'length' <<< "$records")" -gt 0 ]] || return 1
  printf '%s' "$records"
}

# --- Key status / rendering ---------------------------------------------------

# True when a normalized signature equals any entry in a JSON array of key sets.
_domain_array_contains_sig() {
  local arr="$1" sig="$2" count i entry
  count=$(jq 'length' <<< "$arr")
  for ((i = 0; i < count; i++)); do
    entry=$(jq -r ".[$i]" <<< "$arr")
    signatures_equal "$entry" "$sig" && return 0
  done
  return 1
}

# Echo allowed | revoked | none for a signature against a record (revoked wins).
domain_key_status() {
  local rec="$1" sig="$2" norm
  norm=$(signatures_format_block "$sig") || { printf 'none'; return 0; }
  if _domain_array_contains_sig "$(jq -c '.revoked' <<< "$rec")" "$norm"; then printf 'revoked'; return 0; fi
  if _domain_array_contains_sig "$(jq -c '.allowed' <<< "$rec")" "$norm"; then printf 'allowed'; return 0; fi
  printf 'none'
}

# Human label for a method.
domain_method_label() {
  case "$1" in
    https) printf 'HTTPS file' ;;
    dns) printf 'DNS TXT' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Method label including DNSSEC status for DNS records (e.g. "DNS TXT, DNSSEC :lock:").
domain_method_display() {
  local rec="$1" method ds
  method=$(jq -r '.method' <<< "$rec")
  if [[ "$method" == "dns" ]]; then
    ds=$(jq -r '.dnssec // false' <<< "$rec")
    if [[ "$ds" == "true" ]]; then
      printf 'DNS TXT, DNSSEC :lock:'
    else
      printf 'DNS TXT, no DNSSEC'
    fi
  else
    domain_method_label "$method"
  fi
}

# All key sets actually present in a record, as one <br>-joined HTML table cell.
# Revoked sets are annotated so they can't be mistaken for allowed keys.
_domain_record_keys_html() {
  local rec="$1" out="" entry count i
  count=$(jq '.allowed | length' <<< "$rec")
  for ((i = 0; i < count; i++)); do
    entry=$(jq -r ".allowed[$i]" <<< "$rec")
    [[ -n "$out" ]] && out+="<br>"
    out+="${entry//$'\n'/<br>}"
  done
  count=$(jq '.revoked // [] | length' <<< "$rec")
  for ((i = 0; i < count; i++)); do
    entry=$(jq -r ".revoked[$i]" <<< "$rec")
    [[ -n "$out" ]] && out+="<br>"
    out+="${entry//$'\n'/<br>} (revoked)"
  done
  printf '%s' "$out"
}

# A single markdown table row (| Source | Matches | Verification |) for a record + signature.
# The Verification column lists where the record was actually found (the DNS name or
# well-known URL, which may be on a more specific domain than the package's root) above
# the keys it contains; the Matches column reports whether the submitted signature is
# among them. An optional third argument overrides the Matches mark (used for records
# shadowed by a more specific domain).
domain_table_row() {
  local rec="$1" sig="$2" mark="${3:-}"
  local domain source status
  domain=$(jq -r '.domain' <<< "$rec")
  source=$(jq -r '.source' <<< "$rec")
  if [[ -z "$mark" ]]; then
    status=$(domain_key_status "$rec" "$sig")
    case "$status" in
      allowed) mark=":white_check_mark:" ;;
      revoked) mark=":rotating_light: revoked" ;;
      *) mark=":x:" ;;
    esac
  fi
  printf '| Verified Domain (`%s` via %s) | %s | `%s`<br>%s |\n' \
    "$domain" "$(domain_method_display "$rec")" "$mark" "$source" "$(_domain_record_keys_html "$rec")"
}

# Markdown table rows for every record found for a package, most specific first. Only
# the first record decides the Matches verdict; rows for records on less specific
# domains are marked superseded, since a more specific record shadows them even when
# they contain the submitted key.
domain_table_rows() {
  local records="$1" sig="$2"
  local count i rec
  count=$(jq 'length' <<< "$records")
  for ((i = 0; i < count; i++)); do
    rec=$(jq -c ".[$i]" <<< "$records")
    if ((i == 0)); then
      domain_table_row "$rec" "$sig"
    else
      domain_table_row "$rec" "$sig" ":heavy_minus_sign: superseded"
    fi
  done
}

# Prominent revoked warning (empty output when the key is not revoked).
domain_revoked_warning() {
  local rec="$1" sig="$2"
  [[ "$(domain_key_status "$rec" "$sig")" == "revoked" ]] || return 0
  local domain source
  domain=$(jq -r '.domain' <<< "$rec")
  source=$(jq -r '.source' <<< "$rec")
  cat <<EOF
> [!CAUTION]
> **This signing key is listed as REVOKED by the domain owner.** The verification record at \`${source}\` for \`${domain}\` explicitly revokes the submitted signing key. Do **not** add this submission to the database without investigating — the developer may have rotated keys or flagged this key as compromised.
EOF
}

# --- data-verified-domains.yml (schema 1) ------------------------------------

# Insert or update a domain row (by domain), keeping the file sorted by domain.
#   $1 file  $2 domain  $3 method  $4 issue_ref  $5 checked (ISO8601)
#   $6 dnssec   ("true"/"false"/"" — records a .dnssec boolean for DNS records)
#   $7 allowed  (JSON array of normalized key sets seen at this check; default [])
#   $8 revoked  (JSON array of normalized revoked key sets; default [])
# The .issue field is a *list*: a new issue_ref is appended (deduped) rather than
# overwriting prior ones, so every request that proved/refreshed the domain is kept.
# .allowed / .revoked record the key sets as of the most recent check (.revoked is
# omitted when empty, e.g. for DNS records which carry no revocation list).
domain_verified_upsert() {
  local file="$1" domain="$2" method="$3" issue="$4" checked="$5" dnssec="${6:-}"
  local allowed_json="${7:-[]}" revoked_json="${8:-[]}"
  export DV_DOMAIN="$domain" DV_METHOD="$method" DV_ISSUE="$issue" DV_CHECKED="$checked"
  export DV_ALLOWED="$allowed_json" DV_REVOKED="$revoked_json"
  if [[ ! -f "$file" || ! -s "$file" ]]; then
    yq -n '.schema = '"$DOMAIN_VERIFIED_SCHEMA"' | .domains = [{"domain": strenv(DV_DOMAIN), "method": strenv(DV_METHOD), "issue": [strenv(DV_ISSUE)], "checked": strenv(DV_CHECKED)}]' > "$file"
  else
    local schema
    schema=$(yq -r '.schema // 0' "$file")
    if [[ "$schema" != "$DOMAIN_VERIFIED_SCHEMA" ]]; then
      echo "Unsupported ${DOMAIN_VERIFIED_FILE} schema (expected ${DOMAIN_VERIFIED_SCHEMA}): $schema" >&2
      return 1
    fi
    if yq -e '.domains[] | select(.domain == strenv(DV_DOMAIN))' "$file" >/dev/null 2>&1; then
      yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .method = strenv(DV_METHOD) | .issue = ((.issue // []) + [strenv(DV_ISSUE)] | unique) | .checked = strenv(DV_CHECKED))' "$file"
    else
      yq -i '.domains += [{"domain": strenv(DV_DOMAIN), "method": strenv(DV_METHOD), "issue": [strenv(DV_ISSUE)], "checked": strenv(DV_CHECKED)}]' "$file"
    fi
  fi
  # Record allowed key sets as observed at this check (block style; multi-cert sets as
  # literal block scalars so they read like the rest of the file).
  yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .allowed = (strenv(DV_ALLOWED) | from_json) | .allowed style="" | .allowed[] style="")' "$file"
  # Record revoked key sets when present, otherwise drop the field.
  if [[ "$(jq 'length' <<< "$revoked_json")" -gt 0 ]]; then
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .revoked = (strenv(DV_REVOKED) | from_json) | .revoked style="" | .revoked[] style="")' "$file"
  else
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); del(.revoked))' "$file"
  fi
  if [[ -n "$dnssec" ]]; then
    export DV_DNSSEC="$dnssec"
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .dnssec = (strenv(DV_DNSSEC) == "true"))' "$file"
  fi
  yq -i '.domains |= sort_by(.domain)' "$file"
}

# GFM-ready unified diff between two data-verified-domains.yml files.
domain_verified_diff() {
  local before="$1" after="$2"
  if diff -q "$before" "$after" >/dev/null 2>&1; then
    printf '%s\n' "_No changes to \`${DOMAIN_VERIFIED_FILE}\`._"
    return 0
  fi
  diff -u \
    --label "${DOMAIN_VERIFIED_FILE} (current)" \
    --label "${DOMAIN_VERIFIED_FILE} (after commit)" \
    "$before" "$after" || true
}

# --- data.yml annotation ------------------------------------------------------

# Add a {name: "Verified Domain", issue: <ref>} source to every fingerprint group whose
# package is covered by <domain> and whose fingerprint matches an allowed key set.
# Dedups by source name. Returns 0; sets DOMAIN_ANNOTATE_CHANGED=1 when anything changed.
domain_annotate_data_yml() {
  local data_file="$1" domain="$2" allowed_json="$3" issue_ref="$4"
  DOMAIN_ANNOTATE_CHANGED=0
  [[ -f "$data_file" && -s "$data_file" ]] || return 0
  local schema
  schema=$(yq -r '.schema // 0' "$data_file")
  if ! signatures_data_schema_supported "$schema"; then
    echo "Unsupported data.yml schema (expected 3 or 4): $schema" >&2
    return 1
  fi
  export DA_NAME="$DOMAIN_SOURCE_NAME" DA_ISSUE="$issue_ref"
  local pkg sig_count i fp fp_norm has
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    domain_covers_package "$domain" "$pkg" || continue
    export DA_PKG="$pkg"
    sig_count=$(yq -r '.packages[] | select(.package == strenv(DA_PKG)) | .signature | length' "$data_file")
    [[ "$sig_count" =~ ^[0-9]+$ ]] || continue
    for ((i = 0; i < sig_count; i++)); do
      fp=$(yq -r ".packages[] | select(.package == strenv(DA_PKG)) | .signature[$i].fingerprint" "$data_file")
      fp_norm=$(signatures_format_block "$fp") || continue
      _domain_array_contains_sig "$allowed_json" "$fp_norm" || continue
      has=$(yq -r ".packages[] | select(.package == strenv(DA_PKG)) | .signature[$i].sources[] | select(.name == strenv(DA_NAME)) | .name" "$data_file" | head -1)
      [[ "$has" == "$DOMAIN_SOURCE_NAME" ]] && continue
      yq -i "(.packages[] | select(.package == strenv(DA_PKG)) | .signature[$i].sources) += [{\"name\": strenv(DA_NAME), \"issue\": strenv(DA_ISSUE)}]" "$data_file"
      DOMAIN_ANNOTATE_CHANGED=1
    done
  done < <(yq -r '.packages[].package' "$data_file")
  [[ "$DOMAIN_ANNOTATE_CHANGED" == "1" ]] && yq -i '.packages |= sort_by(.package)' "$data_file"
  return 0
}

# --- State markers (sweep "only on state change") -----------------------------

# Hidden marker embedded in bot comments so the daily sweep can detect state changes.
domain_state_marker() { printf '<!-- domain-verify-state: %s -->' "$1"; }

# Read the last state marker value from concatenated comment bodies on stdin.
domain_last_state_from_comments() {
  grep -oE 'domain-verify-state: [a-z]+' | tail -n1 | awk '{print $2}'
}
