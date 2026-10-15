#!/usr/bin/env bash
#
# cf-api.sh: a small Cloudflare API helper for moving a domain's DNS to Cloudflare.
#
# The token comes from the environment and is never printed:
#   export CF_API_TOKEN="$(security find-generic-password -a "$USER" -s casavpn-cf-dns-token -w)"   # macOS keychain
#   export CF_API_TOKEN="$(pass show casavpn/cf-dns-token)"                                         # or any secret store
#
# Commands (<zone> is the registered domain, e.g. example.com):
#   verify-token                        is the token valid and active?
#   zone-id <zone>                      print the zone id
#   zone-status <zone>                  pending/active and the assigned nameservers
#   list-records <zone>                 name, type, content, proxied, ttl
#   ensure-grey <zone> [--apply]        set proxied=false on every proxied record
#   set-ttl <zone> <name> <ttl> [--apply]
#                                       set the TTL (60..86400, or 1 = auto)
#
# Write commands only show what they would change unless --apply is given.
# Needs: curl, jq. Cloudflare answers every call with {"success": bool, ...};
# anything but success=true exits 1 with the API's error messages.

set -uo pipefail

API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

die() { echo "cf-api: $*" >&2; exit 1; }

usage() {
  awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2
  exit 2
}

need() {
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  [ -n "${CF_API_TOKEN:-}" ] || die "CF_API_TOKEN is not set (see the header of this script)"
}

# cf <METHOD> <path> [json-body]: prints the response body, exits 1 on failure.
# The token goes to curl on stdin (`--config -`) so it never shows in `ps`; a
# process substitution would be closed before curl opens it.
cf() {
  local method="$1" path="$2" body="${3:-}" resp args
  args=(--silent --show-error --max-time 30 --request "$method"
        --config -
        --header "Content-Type: application/json")
  [ -n "$body" ] && args+=(--data "$body")
  resp="$(printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" |
    curl "${args[@]}" "$API$path")" || die "request failed: $method $path"
  if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "cf-api: $method $path failed:" >&2
    printf '%s' "$resp" | jq -r '(.errors // [])[] | "  \(.code): \(.message)"' >&2 2>/dev/null ||
      echo "  (unparseable response)" >&2
    exit 1
  fi
  printf '%s' "$resp"
}

zone_json() {
  local resp
  resp="$(cf GET "/zones?name=$1")" || exit 1
  printf '%s' "$resp" | jq -e '.result[0]' 2>/dev/null || die "zone not found in this account: $1"
}
zone_id() { zone_json "$1" | jq -r '.id'; }

cmd_verify_token() {
  local resp
  resp="$(cf GET /user/tokens/verify)" || exit 1
  printf '%s' "$resp" | jq -r '"token status: \(.result.status)" + (if .result.expires_on then "  expires: \(.result.expires_on)" else "" end)'
  echo "(this call proves the token is valid; zone-id proves it can see the zone)"
}

cmd_zone_status() {
  zone_json "$1" | jq -r '"zone:        \(.name)\nid:          \(.id)\nstatus:      \(.status)\nplan:        \(.plan.name // "?")\nnameservers: \(.name_servers | join(" "))\noriginal NS: \((.original_name_servers // []) | join(" "))"'
}

records() { cf GET "/zones/$1/dns_records?per_page=500"; }

cmd_list_records() {
  local id; id="$(zone_id "$1")" || exit 1
  {
    printf 'NAME\tTYPE\tPROXIED\tTTL\tCONTENT\n'
    records "$id" | jq -r '.result | sort_by(.name, .type)[] |
      [.name, .type, (.proxied // false | tostring), (.ttl | if . == 1 then "auto" else tostring end),
       (if .type == "MX" then "\(.priority) \(.content)" else .content end)] | @tsv'
  } | column -t -s "$(printf '\t')"
}

cmd_ensure_grey() {
  local zone="$1" apply="$2" id list n
  id="$(zone_id "$zone")" || exit 1
  list="$(records "$id" | jq -c '[.result[] | select(.proxied == true)]')" || exit 1
  n="$(printf '%s' "$list" | jq 'length')"
  if [ "$n" -eq 0 ]; then echo "all records are DNS only (grey cloud): nothing to do"; return 0; fi
  printf '%s' "$list" | jq -r '.[] | "proxied: \(.type) \(.name) -> \(.content)"'
  if [ "$apply" != 1 ]; then echo "dry run: $n record(s) would be set to DNS only. Re-run with --apply."; return 0; fi
  patch_all "$id" "$list" '{"proxied":false}' 'set grey'
}

# patch_all <zone-id> <records-json> <body> <label>: PATCH every record, keep going
# after a failure, and return non-zero if any PATCH failed.
patch_all() {
  local id="$1" list="$2" body="$3" label="$4" rid out failed=0 ids
  ids="$(printf '%s' "$list" | jq -r '.[].id')"
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    if out="$(cf PATCH "/zones/$id/dns_records/$rid" "$body")"; then
      printf '%s' "$out" | jq -r --arg l "$label" '"\($l): \(.result.type) \(.result.name) ttl=\(.result.ttl) proxied=\(.result.proxied)"'
    else
      echo "cf-api: FAILED to update record $rid" >&2
      failed=$((failed + 1))
    fi
  done <<<"$ids"
  if [ "$failed" -gt 0 ]; then echo "cf-api: $failed update(s) failed" >&2; return 1; fi
}

cmd_set_ttl() {
  local zone="$1" name="$2" ttl="$3" apply="$4" id fq list n
  case "$ttl" in ''|*[!0-9]*) die "ttl must be a number" ;; esac
  if [ "$ttl" -ne 1 ] && { [ "$ttl" -lt 60 ] || [ "$ttl" -gt 86400 ]; }; then
    die "ttl must be 1 (auto) or 60..86400"
  fi
  case "$name" in *."$zone"|"$zone") fq="$name" ;; "@") fq="$zone" ;; *) fq="$name.$zone" ;; esac
  id="$(zone_id "$zone")" || exit 1
  list="$(records "$id" | jq -c --arg fq "$fq" --argjson ttl "$ttl" \
    '[.result[] | select(.name == $fq and .ttl != $ttl and (.type == "A" or .type == "AAAA" or .type == "CNAME" or .type == "TXT"))]')" || exit 1
  n="$(printf '%s' "$list" | jq 'length')"
  if [ "$n" -eq 0 ]; then echo "$fq: no record needs a TTL change to $ttl (or none exists)"; return 0; fi
  printf '%s' "$list" | jq -r --arg ttl "$ttl" '.[] | "\(.type) \(.name): ttl \(.ttl) -> \($ttl)"'
  if [ "$apply" != 1 ]; then echo "dry run: re-run with --apply."; return 0; fi
  patch_all "$id" "$list" "{\"ttl\":$ttl}" updated
}

main() {
  local cmd="${1:-}" apply=0 args=() a
  [ -n "$cmd" ] || usage
  shift
  for a in "$@"; do
    case "$a" in
      --apply) apply=1 ;;
      --dry-run) apply=0 ;;
      -h|--help) usage ;;
      *) args+=("$a") ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}
  case "$cmd" in
    -h|--help) usage ;;
    verify-token) need; cmd_verify_token ;;
    zone-id)      [ $# -eq 1 ] || usage; need; zone_id "$1" ;;
    zone-status)  [ $# -eq 1 ] || usage; need; cmd_zone_status "$1" ;;
    list-records) [ $# -eq 1 ] || usage; need; cmd_list_records "$1" ;;
    ensure-grey)  [ $# -eq 1 ] || usage; need; cmd_ensure_grey "$1" "$apply" ;;
    set-ttl)      [ $# -eq 3 ] || usage; need; cmd_set_ttl "$1" "$2" "$3" "$apply" ;;
    *) usage ;;
  esac
}

main "$@"
