#!/usr/bin/env bash
#
# gen-client-links.sh: regenerate VLESS/Reality client links from the live
# 3x-ui database, pointed at an address of your choosing.
#
# Usage:
#   gen-client-links.sh [--ssh <user@host> | --local] [--out <file>] [<address>]
#
#   --ssh <user@host>   read the database over SSH (default: $CASAVPN_SSH_TARGET)
#   --local             read /etc/x-ui/x-ui.db on this machine (run it on the Pi)
#   --out <file>        where to write the links (default CLIENT-LINKS.local.txt)
#   <address>           host in the links (default: CASAVPN_DOMAIN). Pass the
#                       numeric public IP only to get around a DNS outage.
#
# Prefer hostname links: a link that carries an IP breaks the day the address
# changes, a hostname link follows casavpn-ddns.
#
# The output contains client UUIDs, which ARE credentials. The file is created
# mode 600 and its name is git-ignored. Do not commit or share it.
#
# Settings come from /etc/casavpn/casavpn.env (or $CASAVPN_ENV) or the
# environment: CASAVPN_DOMAIN, CASAVPN_SSH_TARGET.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CASAVPN_ENV:-/etc/casavpn/casavpn.env}"
OUT="CLIENT-LINKS.local.txt"
MODE=""
TARGET=""
ADDRESS=""

usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2; exit 2; }

# env_get <NAME>: environment wins, then the env file (parsed, never sourced).
env_get() {
  local name="$1" line val
  if [ -n "${!name:-}" ]; then printf '%s' "${!name}"; return; fi
  [ -r "$ENV_FILE" ] || return 0
  line="$(grep -E "^${name}=" "$ENV_FILE" | tail -n1 || true)"
  val="${line#"${name}="}"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh)   [ $# -ge 2 ] || usage; MODE=ssh; TARGET="$2"; shift 2 ;;
    --local) MODE=local; shift ;;
    --out)   [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) ADDRESS="$1"; shift ;;
  esac
done

if [ -z "$ADDRESS" ]; then ADDRESS="$(env_get CASAVPN_DOMAIN)"; fi
[ -n "$ADDRESS" ] || { echo "No address: pass one, or set CASAVPN_DOMAIN." >&2; exit 2; }

if [ -z "$MODE" ]; then
  TARGET="$(env_get CASAVPN_SSH_TARGET)"
  if [ -n "$TARGET" ]; then MODE=ssh
  elif [ -r /etc/x-ui/x-ui.db ] || [ "$(id -u)" -eq 0 ]; then MODE=local
  else echo "Say where the database is: --ssh <user@host> or --local." >&2; exit 2; fi
fi

QUERY='select port, settings, stream_settings from inbounds where enable=1;'

# -json keeps the embedded config blobs intact; they are multi-line JSON, so a
# line-oriented separator would tear them apart.
if [ "$MODE" = ssh ]; then
  command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }
  echo "Reading inbound configuration from $TARGET ..." >&2
  ssh -o BatchMode=yes "$TARGET" "sudo sqlite3 -json /etc/x-ui/x-ui.db \"$QUERY\"" |
    python3 "$HERE/lib/render_links.py" "$ADDRESS" "$OUT"
else
  command -v sqlite3 >/dev/null || { echo "sqlite3 not found (apt install sqlite3)" >&2; exit 1; }
  echo "Reading inbound configuration from /etc/x-ui/x-ui.db ..." >&2
  if [ "$(id -u)" -eq 0 ]; then sqlite3 -json /etc/x-ui/x-ui.db "$QUERY"; else sudo sqlite3 -json /etc/x-ui/x-ui.db "$QUERY"; fi |
    python3 "$HERE/lib/render_links.py" "$ADDRESS" "$OUT"
fi
chmod 600 "$OUT" 2>/dev/null || true
