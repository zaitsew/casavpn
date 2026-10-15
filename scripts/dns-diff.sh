#!/usr/bin/env bash
#
# dns-diff.sh: prove a DNS cutover is safe by comparing answers.
#
#   dns-diff.sh <old-ns> <new-ns> [--allow-ds] [--domain <zone>]
#       Ask both nameservers for every name and type in config/dns/inventory.txt
#       and print a table. Run before delegating (old = your current
#       nameserver, new = the Cloudflare nameserver assigned to the zone)
#       until it is clean.
#
#   dns-diff.sh --resolvers [<ref-ns>] [--domain <zone>]
#       Post-cutover watch. Ask 1.1.1.1, 8.8.8.8 and 9.9.9.9 for the key
#       records and compare them with the authoritative answer. <ref-ns>
#       defaults to the first nameserver the TLD parent delegates to.
#
# The zone is --domain, $DNSDIFF_DOMAIN, or the registered domain of
# CASAVPN_DOMAIN (the last two labels; set DNSDIFF_DOMAIN for a zone such
# as example.co.uk).
#
# Both modes check DNSSEC: if a DS record exists at the TLD parent, the zone
# is signed, and switching to an unsigned zone makes validating resolvers
# (1.1.1.1, 8.8.8.8, 9.9.9.9 all validate) return SERVFAIL for the whole
# domain, mail included. In the nameserver mode that is a blocker.
#
# Exit codes: 0 clean | 1 differences | 2 DS present (blocker) | 3 usage or
# query error (a timeout, SERVFAIL or REFUSED is never treated as an answer, on
# either side). Differences in config/dns/allowlist.txt do not count.
#
# Environment (for tests and other zones):
#   DNSDIFF_DOMAIN, DNSDIFF_INVENTORY, DNSDIFF_ALLOWLIST, DNSDIFF_KEY_RECORDS,
#   DNSDIFF_PARENT, DNSDIFF_RESOLVERS (space separated; DNSDIFF_PARENT likewise)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${DNSDIFF_DOMAIN:-}"
INVENTORY="${DNSDIFF_INVENTORY:-$ROOT/config/dns/inventory.txt}"
ALLOWLIST="${DNSDIFF_ALLOWLIST:-$ROOT/config/dns/allowlist.txt}"
KEY_FILE="${DNSDIFF_KEY_RECORDS:-$ROOT/config/dns/key-records.txt}"
# Parent (TLD) servers asked about the DS; the first one also gives the
# delegation. Empty means "discover them from the TLD's NS set" (see main).
PARENTS="${DNSDIFF_PARENT:-}"
PARENT=""
RESOLVERS="${DNSDIFF_RESOLVERS:-1.1.1.1 8.8.8.8 9.9.9.9}"

# Records worth watching on public resolvers: "name type", one per line, from
# config/dns/key-records.txt. The default is the apex and www.
KEY_RECORDS=""
load_key_records() {
  if [ -f "$KEY_FILE" ]; then
    KEY_RECORDS="$(sed -e 's/#.*//' "$KEY_FILE" | awk 'NF >= 2 { print $1, $2 }')"
  fi
  [ -n "$KEY_RECORDS" ] || KEY_RECORDS="@ A
@ MX
@ TXT
@ NS
www A"
}

# default_domain: the registered domain of CASAVPN_DOMAIN (its last two labels).
default_domain() {
  local host="${CASAVPN_DOMAIN:-}" envfile="${CASAVPN_ENV:-/etc/casavpn/casavpn.env}" line
  if [ -z "$host" ] && [ -r "$envfile" ]; then
    line="$(grep -E '^CASAVPN_DOMAIN=' "$envfile" | tail -n1)"
    host="${line#CASAVPN_DOMAIN=}"; host="${host//\"/}"; host="${host//\'/}"
  fi
  [ -n "$host" ] || return 1
  awk -F. '{ n = NF; if (n < 2) { print $0 } else { print $(n-1) "." $n } }' <<<"$host"
}

# discover_parents: the TLD's own name servers, two of them.
discover_parents() {
  local tld="${DOMAIN##*.}" out
  out="$(dig +short NS "$tld." 2>/dev/null </dev/null | sed 's/\.$//' | head -n 2 | tr '\n' ' ')"
  out="${out% }"
  [ -n "$out" ] || return 1
  echo "$out"
}

usage() {
  awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2
  exit 3
}

fqdn() { if [ "$1" = "@" ]; then echo "$DOMAIN"; else echo "$1.$DOMAIN"; fi; }

# normalise <TYPE>: stdin rdata -> comparable form
normalise() {
  case "$1" in
    CNAME|NS|MX|SRV|AAAA)
      tr '[:upper:]' '[:lower:]' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/\.$//' -e 's/ *$//' ;;
    TXT)
      sed -e 's/" *"//g' -e 's/[[:space:]]*$//' ;;
    *)
      sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/ *$//' ;;
  esac
}

# query <server> <name> <TYPE> <recursive 0|1>
# Prints sorted, normalised rdata, one record per line. Prints a single
# "ERROR(...)" line when the server did not give a usable answer.
query() {
  local server="$1" name="$2" type="$3" rec="$4" out rc status
  local flags=(+noall +answer +comments +time=3 +tries=2)
  [ "$rec" = 0 ] && flags+=(+norecurse)
  out="$(dig "${flags[@]}" "$type" "$name" "@$server" 2>/dev/null </dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "ERROR(dig exit $rc)"; return; fi
  status="$(printf '%s\n' "$out" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -n1)"
  case "$status" in
    SERVFAIL|REFUSED|FORMERR|NOTIMP) echo "ERROR($status)"; return ;;
  esac
  printf '%s\n' "$out" |
    awk -v t="$type" '$1 !~ /^;/ && $4 == t {
      sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, ""); print }' |
    normalise "$type" | LC_ALL=C sort
}

# allow_flags <name> <TYPE> <mode ns|resolvers>: rc 0 and flags on stdout if listed
allow_flags() {
  [ -f "$ALLOWLIST" ] || return 1
  awk -v n="$1" -v t="$2" -v m="$3" '
    /^[ \t]*#/ || NF < 2 { next }
    $1 == n && $2 == t {
      if ($3 ~ /ns-only/ && m != "ns") next
      print $3; found = 1
    }
    END { exit !found }' "$ALLOWLIST"
}

one_line() { printf '%s' "$1" | tr '\n' '|' | sed 's/|$//; s/|/ | /g'; }

DIFFS=0
ERRORS=0
ALLOWED=0
DETAIL=""

# compare <label> <name> <TYPE> <ref-values> <new-values> <mode>
compare() {
  local label="$1" name="$2" type="$3" ref="$4" new="$5" mode="$6" status flags shown
  if [[ "$ref" == ERROR* || "$new" == ERROR* ]]; then
    # A failed query is never an answer, even if both sides failed alike.
    status="ERROR"
  elif [ "$ref" = "$new" ]; then
    status="ok"
  elif flags="$(allow_flags "$name" "$type" "$mode")"; then
    status="allowed"
    case "$flags" in
      *nonempty*)
        if [ -z "$new" ] || [[ "$new" == ERROR* ]]; then status="DIFF"; fi ;;
    esac
  else
    status="DIFF"
  fi
  if [ "$status" = "ERROR" ]; then
    ERRORS=$((ERRORS + 1))
    DETAIL="${DETAIL}  ${label:+$label: }${name} ${type}  (query error, not a comparison)
      reference: $(one_line "${ref:--}")
      other:     $(one_line "${new:--}")
"
  elif [ "$status" = "DIFF" ]; then
    DIFFS=$((DIFFS + 1))
    DETAIL="${DETAIL}  ${label:+$label: }${name} ${type}
      reference: $(one_line "${ref:--}")
      other:     $(one_line "${new:--}")
"
  elif [ "$status" = "allowed" ]; then
    ALLOWED=$((ALLOWED + 1))
  fi
  if [ -z "$ref" ] && [ -z "$new" ]; then shown="-"; else shown="$(printf '%s' "$ref" | grep -c .)"; fi
  printf '  %-18s %-6s %-8s %s\n' "$name" "$type" "$status" "$shown"
}

# ds_state: prints "present <ds>" | "absent" | "unknown".
# "absent" needs a NOERROR answer with no DS from every parent server asked; a
# timeout, SERVFAIL or REFUSED is "unknown", never proof that the DS is gone.
ds_state() {
  local srv out rc status ds found="" unknown=0
  for srv in $PARENTS; do
    out="$(dig +noall +comments +answer +time=3 +tries=2 DS "$DOMAIN" "@$srv" 2>/dev/null </dev/null)"
    rc=$?
    status="$(printf '%s\n' "$out" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -n1)"
    if [ "$rc" -ne 0 ] || [ "$status" != "NOERROR" ]; then unknown=1; continue; fi
    ds="$(printf '%s\n' "$out" | awk '$1 !~ /^;/ && $4 == "DS" {
      sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, ""); print; exit }')"
    [ -n "$ds" ] && found="$ds"
  done
  if [ -n "$found" ]; then echo "present $found"
  elif [ "$unknown" -eq 1 ]; then echo "unknown"
  else echo "absent"; fi
}

banner_ds() {
  cat <<EOF

  ##########################################################################
  #  DNSSEC IS ON: a DS record exists at the TLD parent for $DOMAIN
  #
  #  $1
  #
  #  DO NOT change the nameservers yet. The new Cloudflare zone is unsigned,
  #  so every validating resolver would answer SERVFAIL for the whole domain
  #  (website, VPN hostname AND mail) until the old DS expires from caches.
  #
  #  Fix: remove the DS first (at your registrar: Domain -> DNSSEC -> off),
  #  wait until this script reports "DS absent", then wait out the DS TTL
  #  (24 hours for most TLDs) and only then switch nameservers.
  #  See docs/DNS-MIGRATION.md, step 0.
  ##########################################################################

EOF
}

mode_ns() {
  local old="$1" new="$2" allow_ds="$3" line name type a b ds
  echo "Comparing $DOMAIN: reference (old) $old  vs  new $new"
  echo
  printf '  %-18s %-6s %-8s %s\n' "NAME" "TYPE" "STATUS" "RECORDS"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    # shellcheck disable=SC2086
    set -- $line
    [ $# -ge 2 ] || continue
    name="$1"; shift
    for type in "$@"; do
      a="$(query "$old" "$(fqdn "$name")" "$type" 0)"
      b="$(query "$new" "$(fqdn "$name")" "$type" 0)"
      compare "" "$name" "$type" "$a" "$b" ns
    done
  done < "$INVENTORY"
  echo
  report_diffs

  echo "DNSSEC check at the TLD parent ($PARENTS):"
  ds="$(ds_state)"
  case "$ds" in
    present*)
      if [ "$allow_ds" = 1 ]; then
        echo "  DS present (${ds#present }), --allow-ds given: continuing."
        echo "  Make sure the new zone is signed with a matching key, or this breaks resolution."
      else
        banner_ds "DS: ${ds#present }"
        return 2
      fi ;;
    absent) echo "  DS absent (NOERROR with no DS from every parent server): the zone is unsigned at the parent." ;;
    *) echo "  Could not get a clean NOERROR answer about the DS from every parent server. Do not delegate until this works."
       ERRORS=$((ERRORS + 1)) ;;
  esac
  if [ "$ERRORS" -gt 0 ]; then
    echo "NOT CLEAN: $ERRORS query error(s); a failed query is not an answer. Fix and rerun."
    return 3
  fi
  [ "$DIFFS" -eq 0 ] || return 1
  echo
  echo "CLEAN: no differences (allow-listed: $ALLOWED)."
  return 0
}

report_diffs() {
  if [ "$DIFFS" -gt 0 ] || [ "$ERRORS" -gt 0 ]; then
    echo "DIFFERENCES ($DIFFS) and QUERY ERRORS ($ERRORS):"
    printf '%s' "$DETAIL"
    echo
  fi
}

mode_resolvers() {
  local ref="${1:-}" r name type a b ds
  if [ -z "$ref" ]; then
    ref="$(dig +norecurse +noall +answer +authority NS "$DOMAIN" "@$PARENT" 2>/dev/null </dev/null |
      awk '$4 == "NS" { print $5; exit }')"
    ref="${ref%.}"
    [ -n "$ref" ] || { echo "Could not find the delegated nameservers at $PARENT" >&2; return 3; }
    echo "Reference nameserver: $ref (first delegation at $PARENT)"
  else
    echo "Reference nameserver: $ref"
  fi
  echo
  for r in $RESOLVERS; do
    echo "Resolver $r"
    printf '  %-18s %-6s %-8s %s\n' "NAME" "TYPE" "STATUS" "RECORDS"
    while IFS=' ' read -r name type; do
      [ -n "$name" ] || continue
      a="$(query "$ref" "$(fqdn "$name")" "$type" 0)"
      b="$(query "$r" "$(fqdn "$name")" "$type" 1)"
      compare "$r" "$name" "$type" "$a" "$b" resolvers
    done <<EOF
$KEY_RECORDS
EOF
    echo
  done
  report_diffs

  ds="$(ds_state)"
  case "$ds" in
    present*) echo "DNSSEC: DS present at $PARENT (${ds#present })."
              echo "  If you did not enable DNSSEC at Cloudflare and add its DS, this is the stale DS: remove it now,"
              echo "  validating resolvers return SERVFAIL while it exists (see ERROR rows above)." ;;
    absent)   echo "DNSSEC: DS absent at $PARENT (unsigned)." ;;
    *)        echo "DNSSEC: could not get a clean answer about the DS from $PARENTS."
              ERRORS=$((ERRORS + 1)) ;;
  esac
  if [ "$ERRORS" -gt 0 ]; then
    echo "NOT CLEAN: $ERRORS query error(s) (timeout, SERVFAIL or REFUSED); a failed query is not an answer."
    return 3
  fi
  [ "$DIFFS" -eq 0 ] || { echo "NOT CLEAN: $DIFFS difference(s). Propagation can take hours; rerun later."; return 1; }
  echo "CLEAN: every resolver agrees with $ref (allow-listed: $ALLOWED)."
  return 0
}

main() {
  command -v dig >/dev/null 2>&1 || { echo "dig not found (macOS: brew install bind; Debian: apt install dnsutils)" >&2; exit 3; }
  [ -f "$INVENTORY" ] || { echo "inventory not found: $INVENTORY (copy config/dns/inventory.example.txt)" >&2; exit 3; }
  local allow_ds=0 args=() a want_domain=0
  for a in "$@"; do
    if [ "$want_domain" = 1 ]; then DOMAIN="$a"; want_domain=0; continue; fi
    case "$a" in
      --allow-ds) allow_ds=1 ;;
      --domain) want_domain=1 ;;
      -h|--help) usage ;;
      *) args+=("$a") ;;
    esac
  done
  [ "$want_domain" = 0 ] || { echo "--domain needs a value" >&2; exit 3; }
  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(default_domain)" || { echo "Which zone? Pass --domain <zone> or set DNSDIFF_DOMAIN." >&2; exit 3; }
  fi
  if [ -z "$PARENTS" ]; then
    PARENTS="$(discover_parents)" || { echo "Could not discover the TLD name servers; set DNSDIFF_PARENT." >&2; exit 3; }
  fi
  PARENT="${PARENTS%% *}"
  load_key_records
  set -- ${args[@]+"${args[@]}"}
  case "${1:-}" in
    --resolvers) mode_resolvers "${2:-}"; exit $? ;;
    "") usage ;;
    *) [ $# -eq 2 ] || usage
       mode_ns "$1" "$2" "$allow_ds"; exit $? ;;
  esac
}

main "$@"
