# Shared helpers for domain-based app verification.
# A developer proves control of the domain in their app's package ID by publishing the
# app's signing key(s) for that package either:
#   - HTTPS: a Digital Asset Links file at https://<domain>/.well-known/assetlinks.json
#            (the standard Android format). A statement is accepted when (relation is
#            ignored): target.namespace == "android_app", target.package_name == the app
#            being verified, and target.sha256_cert_fingerprints contains the app's key.
#   - DNS:   TXT records at _pgappverify.<domain> (one key set per record).
# Both methods derive their candidate domains from the package ID (reverse labels), most
# specific first down to the 2-label root, so a record on a more specific subdomain wins.
#
# Sourced by composite actions alongside signatures.lib.sh:
#   source "${GITHUB_ACTION_PATH}/domains.lib.sh"
# It pulls in signatures.lib.sh (for normalization/comparison + domain_source_name) when
# not already loaded.

_DOMAIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f signatures_format_block >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${_DOMAIN_LIB_DIR}/../signature-lib/signatures.lib.sh"
fi

DOMAIN_WELLKNOWN_PATH=".well-known/assetlinks.json"
DOMAIN_DNS_PREFIX="_pgappverify"
DOMAIN_VERIFIED_FILE="data-verified-domains.yml"
DOMAIN_VERIFIED_SCHEMA=2
# Relation advertised in the assetlinks.json instructions example. Any relation is accepted
# when verifying; this is only what we tell developers to publish. The standard predefined
# relation also enables Android App Links URL handling, so we also offer an inert custom
# relation (Java-scoped detail string, permitted by the Digital Asset Links spec) for
# developers who don't want to publish a predefined one, this way it has no side effects.
DOMAIN_DAL_RELATION="delegate_permission/common.handle_all_urls"
DOMAIN_DAL_RELATION_INERT="delegate_permission/org.privacyguides.verifiedapps"
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

# Read the Package Name field (the app's package ID), trimmed and validated. Returns 1 when
# absent or not a valid Android application ID.
domain_parse_package_name() {
  local body="$1" value
  value=$(_domain_issue_section "Package Name" "$body" | awk 'NF {print; exit}')
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ -z "$value" || "$value" == "_No response_" ]] && return 1
  is_valid_package_name "$value" || return 1
  printf '%s' "$value"
}

# --- Instructions comment -----------------------------------------------------

# Render the developer-facing setup instructions for both methods from the package ID and
# parsed keys. Candidate domains are derived from the package ID, most specific first.
domain_render_instructions() {
  local package="$1" keys_json="$2"
  local fps_flat assetlinks dns_lines https_locs dns_locs count i key oneline domain

  # assetlinks.json statement carries every submitted fingerprint for this package.
  fps_flat=$(jq -c -n --argjson keys "$keys_json" '[ $keys[] | split("\n")[] | select(length > 0) ] | unique')
  assetlinks=$(jq --indent 4 -n \
    --arg rel "$DOMAIN_DAL_RELATION" --arg pkg "$package" --argjson fps "$fps_flat" \
    '[ { relation: [$rel],
         target: { namespace: "android_app", package_name: $pkg, sha256_cert_fingerprints: $fps } } ]')

  # DNS TXT line(s): one record per submitted key set (multi-cert sets space-joined).
  dns_lines=""
  count=$(jq 'length' <<< "$keys_json")
  for ((i = 0; i < count; i++)); do
    key=$(jq -r ".[$i]" <<< "$keys_json")
    oneline=$(printf '%s' "$key" | tr '\n' ' ')
    dns_lines+="$(printf '%s.<domain>.   IN   TXT   "%s"' "$DOMAIN_DNS_PREFIX" "$oneline")"$'\n'
  done

  https_locs=""
  dns_locs=""
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    https_locs+="- \`https://${domain}/${DOMAIN_WELLKNOWN_PATH}\`"$'\n'
    dns_locs+="- \`${DOMAIN_DNS_PREFIX}.${domain}\`"$'\n'
  done < <(domain_candidates_from_package "$package")

  cat <<EOF
Thanks for your verification request! To prove you control the domain behind \`${package}\`, set up **one** of the two methods below using your app's signing key(s). Reply to this issue once the record is live and we'll verify it (we also re-check open requests automatically every day).

We look for the record starting at the most specific domain matching your package ID and walk up to the root, so you can publish it at whichever of these you control:

${https_locs}
### Option 1 — Digital Asset Links file (recommended)

Upload a standard \`assetlinks.json\` file to \`/.well-known/assetlinks.json\` on one of the domains above, containing this statement (you may keep other statements in the array):

\`\`\`json
${assetlinks}
\`\`\`

We require \`namespace\` to be \`android_app\`, \`package_name\` to match \`${package}\`, and \`sha256_cert_fingerprints\` to contain your key(s).

We accept **any** \`relation\`. The example uses \`${DOMAIN_DAL_RELATION}\` (the standard predefined relation, which also grants your app Android App Links URL handling). If you'd rather not publish a predefined relation, use the inert custom relation \`${DOMAIN_DAL_RELATION_INERT}\` instead. This verifies the same way but has no other effect.

### Option 2 — DNS TXT record(s)

Alternatively, add the following TXT record(s), replacing \`<domain>\` with one of:

${dns_locs}
\`\`\`
$(printf '%s' "$dns_lines")
\`\`\`

DNS records are less securely protected than HTTPS web servers. While your verification will be supported and added to the database, some consumers of this dataset may not trust the verification to the same degree, e.g. you may not be eligible for badges indicating higher tier verification in some database viewer apps.

When you've created the record (either method), leave a comment here and we'll check it.
EOF
}

# --- Record discovery ---------------------------------------------------------

# Fetch an HTTPS resource for Digital Asset Links and echo its body only on a hard HTTP 200.
# The DAL spec requires statement files to be served with a 200 response: redirects are NOT
# followed (no curl -L) and any non-200 status fails. Only https URLs are allowed, the body
# size is capped, and transient errors (timeouts/5xx) are retried. Returns 1 on any failure.
_domain_https_fetch_200() {
  local url="$1" tmp code
  [[ "$url" == https://* ]] || return 1
  tmp=$(mktemp)
  code=$(curl -sS --max-time 20 --max-filesize 1048576 --retry 2 --retry-delay 1 \
    -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null) || { rm -f "$tmp"; return 1; }
  if [[ "$code" != "200" ]]; then
    echo "HTTPS: ${url} returned HTTP ${code} (Digital Asset Links requires 200; redirects are not followed)" >&2
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# Fetch and parse the HTTPS Digital Asset Links record for a package on a domain. Collects
# the sha256_cert_fingerprints of every android_app statement whose package_name matches
# the app being verified (relation is ignored), normalized to uppercase colon form. The
# resulting .allowed array is a flat list of individual certificate fingerprints the domain
# vouches for this package.
#
# `include` statements ({"include": "https://.../other.json"}) are followed: the referenced
# statement list is fetched (also 200-only) and its matching statements are merged in. Follows
# are bounded (DOMAIN_HTTPS_MAX_DOCS documents) and de-duplicated to guard against cycles and
# runaway chains; an include that is unreachable or non-200 is skipped, but the top-level
# well-known file must itself return a usable 200. Returns 1 when the top-level file is
# missing/unusable or no matching statement carries a valid fingerprint.
domain_fetch_https_record() {
  local domain="$1" package="$2"
  local url="https://${domain}/${DOMAIN_WELLKNOWN_PATH}"
  local max_docs="${DOMAIN_HTTPS_MAX_DOCS:-10}"
  local allowed="[]" visited="" found_top=0 docs=0 head=0
  local -a queue=("$url")
  local cur body norm_body matching includes inc count i raw norm

  while [[ "$head" -lt "${#queue[@]}" && "$docs" -lt "$max_docs" ]]; do
    cur="${queue[$head]}"
    head=$((head + 1))
    printf '%s\n' "$visited" | grep -Fxq "$cur" && continue
    visited+="${cur}"$'\n'

    if ! body=$(_domain_https_fetch_200 "$cur"); then
      # The top-level well-known file must exist; a missing/non-200 include is just skipped.
      [[ "$cur" == "$url" ]] && return 1
      continue
    fi
    docs=$((docs + 1))

    # A statement list is a JSON array; tolerate a bare {"include": ...} / statement object.
    norm_body=$(jq -c 'if type == "array" then . elif type == "object" then [.] else empty end' <<< "$body" 2>/dev/null) || continue
    [[ -n "$norm_body" ]] || continue
    [[ "$cur" == "$url" ]] && found_top=1

    matching=$(jq -c --arg pkg "$package" '
      [ .[]
        | select(type == "object")
        | select((.target.namespace // "") == "android_app")
        | select((.target.package_name // "") == $pkg)
        | (.target.sha256_cert_fingerprints // [])[]
        | select(type == "string")
      ]' <<< "$norm_body" 2>/dev/null) || matching="[]"
    count=$(jq 'length' <<< "$matching")
    for ((i = 0; i < count; i++)); do
      raw=$(jq -r ".[$i]" <<< "$matching")
      norm=$(signatures_sha256_hex_to_colon_fp "$raw") || continue
      allowed=$(jq -c --arg n "$norm" '. + [$n]' <<< "$allowed")
    done

    # Queue any include targets (https only) for fetching.
    includes=$(jq -c '[ .[] | select(type == "object") | .include // empty | select(type == "string") ]' <<< "$norm_body" 2>/dev/null) || includes="[]"
    count=$(jq 'length' <<< "$includes")
    for ((i = 0; i < count; i++)); do
      inc=$(jq -r ".[$i]" <<< "$includes")
      [[ "$inc" == https://* ]] || continue
      queue+=("$inc")
    done
  done

  [[ "$found_top" -eq 1 ]] || return 1
  allowed=$(jq -c 'unique' <<< "$allowed")
  [[ "$(jq 'length' <<< "$allowed")" -gt 0 ]] || return 1
  jq -n --arg method "https" --arg domain "$domain" --arg source "$url" --arg pkg "$package" \
    --argjson allowed "$allowed" \
    '{found: true, method: $method, domain: $domain, source: $source, package: $pkg, allowed: $allowed}'
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
# every configured resolver to agree, then attach a DNSSEC validation status. The .allowed
# array holds the key set(s) published in the TXT record(s); each entry is one key set
# (a multi-cert set keeps its members on separate lines). Echoes a record for <package>.
domain_fetch_dns_record() {
  local domain="$1" package="$2"
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
  jq -n --arg domain "$domain" --arg source "$name" --arg pkg "$package" --arg dnssec "$dnssec" \
    --argjson allowed "$allowed" \
    '{found: true, method: "dns", domain: $domain, source: $source, package: $pkg, allowed: $allowed, dnssec: ($dnssec == "true")}'
}

# Probe a single explicit domain for <package> (HTTPS first, then DNS). Echoes the record JSON.
domain_find_record_for_domain() {
  local domain="$1" package="$2" rec
  if rec=$(domain_fetch_https_record "$domain" "$package"); then printf '%s' "$rec"; return 0; fi
  if rec=$(domain_fetch_dns_record "$domain" "$package"); then printf '%s' "$rec"; return 0; fi
  return 1
}

# Probe every candidate domain for a package, most specific first, collecting every
# record found.
# Returns 1 when no candidate domain has a record.
domain_find_records_for_package() {
  local pkg="$1" domain rec records="[]"
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    rec=$(domain_find_record_for_domain "$domain" "$pkg") || continue
    records=$(jq -c --argjson r "$rec" '. + [$r]' <<< "$records")
  done < <(domain_candidates_from_package "$pkg")
  [[ "$(jq 'length' <<< "$records")" -gt 0 ]] || return 1
  printf '%s' "$records"
}

# --- Key status / rendering ---------------------------------------------------

# True when a normalized signature equals any entry in a JSON array of key sets (set
# equality; used for DNS records, where each entry is a whole published key set).
_domain_array_contains_sig() {
  local arr="$1" sig="$2" count i entry
  count=$(jq 'length' <<< "$arr")
  for ((i = 0; i < count; i++)); do
    entry=$(jq -r ".[$i]" <<< "$arr")
    signatures_equal "$entry" "$sig" && return 0
  done
  return 1
}

# True when every fingerprint in a normalized key set block is present in a flat JSON array
# of individual fingerprints (subset; used for HTTPS Digital Asset Links records, where
# sha256_cert_fingerprints lists individual certs and must "contain" the app's key).
_domain_array_contains_block() {
  local arr="$1" block="$2" norm line
  norm=$(signatures_normalize "$block") || return 1
  [[ -n "$norm" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    jq -e --arg l "$line" 'index($l)' >/dev/null 2>&1 <<< "$arr" || return 1
  done <<< "$norm"
  return 0
}

# Echo allowed | none for a signature against a record. HTTPS records match by subset
# (the record's fingerprints must contain every cert in the submitted key); DNS records
# match by set equality against a published key set.
domain_key_status() {
  local rec="$1" sig="$2" method norm
  norm=$(signatures_format_block "$sig") || { printf 'none'; return 0; }
  method=$(jq -r '.method' <<< "$rec")
  if [[ "$method" == "https" ]]; then
    if _domain_array_contains_block "$(jq -c '.allowed' <<< "$rec")" "$norm"; then printf 'allowed'; return 0; fi
  else
    if _domain_array_contains_sig "$(jq -c '.allowed' <<< "$rec")" "$norm"; then printf 'allowed'; return 0; fi
  fi
  printf 'none'
}

# Human label for a method.
domain_method_label() {
  case "$1" in
    https) printf 'Digital Asset Links (assetlinks.json)' ;;
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

# The key sets/fingerprints present in a record, as one <br>-joined HTML table cell.
_domain_record_keys_html() {
  local rec="$1" out="" entry count i
  count=$(jq '.allowed | length' <<< "$rec")
  for ((i = 0; i < count; i++)); do
    entry=$(jq -r ".allowed[$i]" <<< "$rec")
    [[ -n "$out" ]] && out+="<br>"
    out+="${entry//$'\n'/<br>}"
  done
  printf '%s' "$out"
}

# A single markdown table row (| Source | Matches | Verification |) for a record + signature.
# The Verification column lists where the record was actually found (the DNS name or
# assetlinks URL, which may be on a more specific domain than the package's root) above the
# keys it contains; the Matches column reports whether the submitted signature is among
# them. An optional third argument overrides the Matches mark (used for records shadowed by
# a more specific domain).
domain_table_row() {
  local rec="$1" sig="$2" mark="${3:-}"
  local method domain source status
  method=$(jq -r '.method' <<< "$rec")
  domain=$(jq -r '.domain' <<< "$rec")
  source=$(jq -r '.source' <<< "$rec")
  if [[ -z "$mark" ]]; then
    status=$(domain_key_status "$rec" "$sig")
    case "$status" in
      allowed) mark=":white_check_mark:" ;;
      *) mark=":x:" ;;
    esac
  fi
  printf '| %s (`%s` via %s) | %s | `%s`<br>%s |\n' \
    "$(domain_source_name "$method")" "$domain" "$(domain_method_display "$rec")" "$mark" "$source" "$(_domain_record_keys_html "$rec")"
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

# --- data-verified-domains.yml (schema 2) ------------------------------------

# Insert or update a domain row (by domain) and, within it, the verified package row.
#   $1 file  $2 domain  $3 method (https/dns)  $4 package  $5 issue_ref  $6 checked (ISO8601)
#   $7 dnssec       ("true"/"false"/"" - records a .dnssec boolean for DNS records)
#   $8 fingerprints (JSON array of the key set(s)/fingerprints the domain vouches for this
#                    package; default []). For HTTPS these are individual certificate
#                    fingerprints; for DNS each entry is a published key set.
# The .issue field is a *list*: a new issue_ref is appended (deduped) rather than
# overwriting prior ones, so every request that proved/refreshed the domain is kept.
# Verified packages are stored under .packages[] keyed by package name.
domain_verified_upsert() {
  local file="$1" domain="$2" method="$3" package="$4" issue="$5" checked="$6" dnssec="${7:-}"
  local fps_json="${8:-[]}"
  export DV_DOMAIN="$domain" DV_METHOD="$method" DV_PKG="$package" DV_ISSUE="$issue" DV_CHECKED="$checked"
  export DV_FPS="$fps_json"
  if [[ ! -f "$file" || ! -s "$file" ]]; then
    yq -n '.schema = '"$DOMAIN_VERIFIED_SCHEMA"' | .domains = [{"domain": strenv(DV_DOMAIN), "method": strenv(DV_METHOD), "issue": [strenv(DV_ISSUE)], "checked": strenv(DV_CHECKED), "packages": []}]' > "$file"
  else
    local schema
    schema=$(yq -r '.schema // 0' "$file")
    if [[ "$schema" != "$DOMAIN_VERIFIED_SCHEMA" ]]; then
      echo "Unsupported ${DOMAIN_VERIFIED_FILE} schema (expected ${DOMAIN_VERIFIED_SCHEMA}): $schema" >&2
      return 1
    fi
    if yq -e '.domains[] | select(.domain == strenv(DV_DOMAIN))' "$file" >/dev/null 2>&1; then
      yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .method = strenv(DV_METHOD) | .issue = ((.issue // []) + [strenv(DV_ISSUE)] | unique) | .checked = strenv(DV_CHECKED) | .packages = (.packages // []))' "$file"
    else
      yq -i '.domains += [{"domain": strenv(DV_DOMAIN), "method": strenv(DV_METHOD), "issue": [strenv(DV_ISSUE)], "checked": strenv(DV_CHECKED), "packages": []}]' "$file"
    fi
  fi
  # Record DNSSEC for DNS records; otherwise drop the field.
  if [[ "$method" == "dns" && -n "$dnssec" ]]; then
    export DV_DNSSEC="$dnssec"
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .dnssec = (strenv(DV_DNSSEC) == "true"))' "$file"
  else
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); del(.dnssec))' "$file"
  fi
  # Upsert the verified package row within this domain.
  if yq -e '.domains[] | select(.domain == strenv(DV_DOMAIN)) | .packages[] | select(.package == strenv(DV_PKG))' "$file" >/dev/null 2>&1; then
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)) | .packages[] | select(.package == strenv(DV_PKG)); .fingerprints = (strenv(DV_FPS) | from_json))' "$file"
  else
    yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .packages += [{"package": strenv(DV_PKG), "fingerprints": (strenv(DV_FPS) | from_json)}])' "$file"
  fi
  # Render the fingerprints as a block list (clear the flow style from_json produces); a
  # multi-cert key set keeps its members in one literal block scalar so it reads like the
  # rest of the file.
  yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)) | .packages[] | select(.package == strenv(DV_PKG)); .fingerprints style="" | .fingerprints[] style="")' "$file"
  yq -i '(.domains[] | select(.domain == strenv(DV_DOMAIN)) | .packages[] | select(.package == strenv(DV_PKG)) | .fingerprints[] | select(type == "!!str" and contains("\n"))) style="literal"' "$file" 2>/dev/null || true
  yq -i 'with(.domains[] | select(.domain == strenv(DV_DOMAIN)); .packages |= sort_by(.package))' "$file"
  yq -i '.domains |= sort_by(.domain)' "$file"
}

# Remove <package> entirely from every domain in <file>, then drop domains left with no packages.
domain_verified_remove_package() { # file package
  local file="$1" package="$2"
  [[ -f "$file" && -s "$file" ]] || return 0
  export DV_RM_PKG="$package"
  yq -i '(.domains[].packages) |= map(select(.package != strenv(DV_RM_PKG)))' "$file"
  yq -i '.domains |= map(select((.packages // []) | length > 0))' "$file"
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

# Add a method-specific {name, issue} source (HTTPS/DNS Verified Domain) to every fingerprint
# group of <package> in data.yml whose key set is vouched for by the verified record <rec>.
# Dedups by source name. Returns 0; sets DOMAIN_ANNOTATE_CHANGED=1 when anything changed.
domain_annotate_data_yml() {
  local data_file="$1" package="$2" rec="$3" issue_ref="$4"
  DOMAIN_ANNOTATE_CHANGED=0
  [[ -f "$data_file" && -s "$data_file" ]] || return 0
  local schema method source_name
  schema=$(yq -r '.schema // 0' "$data_file")
  if ! signatures_data_schema_supported "$schema"; then
    echo "Unsupported data.yml schema (expected 3 or 4): $schema" >&2
    return 1
  fi
  method=$(jq -r '.method' <<< "$rec")
  source_name=$(domain_source_name "$method")
  export DA_NAME="$source_name" DA_ISSUE="$issue_ref" DA_PKG="$package"
  local sig_count i fp fp_norm has
  sig_count=$(yq -r '.packages[] | select(.package == strenv(DA_PKG)) | .signature | length' "$data_file")
  [[ "$sig_count" =~ ^[0-9]+$ ]] || return 0
  for ((i = 0; i < sig_count; i++)); do
    fp=$(yq -r ".packages[] | select(.package == strenv(DA_PKG)) | .signature[$i].fingerprint" "$data_file")
    fp_norm=$(signatures_format_block "$fp") || continue
    [[ "$(domain_key_status "$rec" "$fp_norm")" == "allowed" ]] || continue
    has=$(yq -r ".packages[] | select(.package == strenv(DA_PKG)) | .signature[$i].sources[] | select(.name == strenv(DA_NAME)) | .name" "$data_file" | head -1)
    [[ "$has" == "$source_name" ]] && continue
    yq -i "(.packages[] | select(.package == strenv(DA_PKG)) | .signature[$i].sources) += [{\"name\": strenv(DA_NAME), \"issue\": strenv(DA_ISSUE)}]" "$data_file"
    DOMAIN_ANNOTATE_CHANGED=1
  done
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

# Default DNS-over-HTTPS resolvers and ICANN trust anchors when callers do not set them.
domains_apply_default_env() {
  if [[ -z "${DOH_RESOLVERS:-}" ]]; then
    export DOH_RESOLVERS=$'https://dns.google/dns-query\nhttps://cloudflare-dns.com/dns-query\nhttps://dns.quad9.net/dns-query\nhttps://freedns.controld.com/p0'
  fi
  if [[ -z "${ICANN_ROOT_TRUST_ANCHOR:-}" ]]; then
    export ICANN_ROOT_TRUST_ANCHOR=$'trust-anchors {\n    . static-ds 20326 8 2 "E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D";\n    . static-ds 38696 8 2 "683D2D0ACB8C9B712A1948B27F741219298D0A450D612C483AF444A4C0FB2B16";\n};'
  fi
}

domains_apply_default_env
