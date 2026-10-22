# shellcheck shell=bash
#
# casavpn-notify.sh: the one sender behind casavpn-ddns and casavpn-alerts.
# Sourced, never executed. Compatible with bash 3.2 and with callers that run
# with or without `set -e`: nothing here exits the caller.
#
#   casavpn_notify <kind> <severity> <title> <body> [dedupe]
#
# Sends the event to every channel that is set up:
#   the relay   POST $CASAVPN_RELAY_URL/v1/events with
#               "Authorization: Bearer $CASAVPN_RELAY_TOKEN" (docs/APP.md,
#               "Relay API"). Needs both variables.
#   ntfy        POST to $NTFY_URL. ntfy has no dedupe, so an event with a
#               dedupe key is sent at most once per CASAVPN_NOTIFY_REPEAT
#               seconds (default 6 h), tracked in CASAVPN_NOTIFY_STATE_DIR.
#
# Return codes: 0 delivered on every configured channel, 1 a channel failed
# (the reason is logged to stderr), 2 the arguments are wrong, 3 no channel is
# configured. The caller decides what a failure means; none of them aborts it.
#
# Settings (environment; the scripts load them from casavpn.env):
#   CASAVPN_RELAY_URL, CASAVPN_RELAY_TOKEN   the relay and the HOST token
#   NTFY_URL                                 optional second channel
#   CASAVPN_NOTIFY_DRY_RUN=1                 print the event, send nothing
#   CASAVPN_NOTIFY_STATE_DIR                 default /var/lib/casavpn
#   CASAVPN_NOTIFY_REPEAT                    default 21600
#
# Time limits: every request has a 5 s connect and a 10 s total limit. When a
# channel does not answer at all (a timeout, no route), the library marks it down
# for the rest of the process and fails its later sends at once, so a run with many
# events is bounded by one timeout per channel, not one per event. Nothing is
# recorded for a failed send, so the next run tries again.
#
# Also here: casavpn_env_load, the allow-listed parser for casavpn.env.

: "${CASAVPN_NOTIFY_REPEAT:=21600}"
_NOTIFY_RELAY_DOWN=0
_NOTIFY_NTFY_DOWN=0

_notify_log() { printf '%s casavpn-notify: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }

# casavpn_env_load <file> <KEY>...: read the named KEY=VALUE lines of casavpn.env.
# The file is data, never executed; keys not named are ignored. A variable that
# already has a value in the environment wins over the file. Returns 1 when the
# file cannot be read.
casavpn_env_load() {
  local file="$1" line key val k pinned=" "
  shift
  [ -r "$file" ] || return 1
  for k in "$@"; do
    if [ -n "${!k:-}" ]; then pinned="$pinned$k "; fi
  done
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    case " $* " in *" $key "*) ;; *) continue ;; esac
    case "$pinned" in *" $key "*) continue ;; esac
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf -v "$key" '%s' "$val"
    # shellcheck disable=SC2163  # exporting the variable NAMED by $key is the point
    export "$key"
  done <"$file"
  return 0
}

# casavpn_notify_event_json <kind> <severity> <title> <body> [dedupe]
# The Event body of the relay API. jq builds it, so quotes, newlines and non-ASCII
# text in a title or a client name cannot break the JSON. Fields are cut to the
# relay's limits (80, 400 and 64 characters).
casavpn_notify_event_json() {
  jq -nc --arg kind "$1" --arg severity "$2" --arg title "$3" --arg body "$4" --arg dedupe "${5:-}" '
    {kind: $kind, severity: $severity, title: ($title | .[0:80]), body: ($body | .[0:400])}
    + (if $dedupe == "" then {} else {dedupe: ($dedupe | .[0:64])} end)'
}

# _notify_check <kind> <severity>: 0 when both are in the relay's vocabulary.
_notify_check() {
  [[ "$1" =~ ^[a-z._]{1,32}$ ]] || { _notify_log "refusing event: kind '$1' is not 1-32 characters of a-z . _"; return 1; }
  case "$2" in critical|warning|info) ;; *) _notify_log "refusing event: severity '$2' is not critical, warning or info"; return 1 ;; esac
}

# casavpn_notify_relay <kind> <severity> <title> <body> [dedupe]
# 0 delivered (HTTP 202, or 200 when the relay already had the dedupe key),
# 1 failed, 2 bad arguments, 3 the relay is not configured.
casavpn_notify_relay() {
  local json url code
  _notify_check "$1" "$2" || return 2
  [ -n "${CASAVPN_RELAY_URL:-}" ] && [ -n "${CASAVPN_RELAY_TOKEN:-}" ] || return 3
  if [ "$_NOTIFY_RELAY_DOWN" = 1 ] && [ "${CASAVPN_NOTIFY_DRY_RUN:-0}" != 1 ]; then
    _notify_log "the relay did not answer earlier in this run; not sending '$1' (the next run retries)"
    return 1
  fi
  json="$(casavpn_notify_event_json "$@")" || { _notify_log "could not build the event JSON (is jq installed?)"; return 1; }
  if [ "${CASAVPN_NOTIFY_DRY_RUN:-0}" = 1 ]; then printf 'would send to the relay: %s\n' "$json"; return 0; fi
  # The token goes to curl in a config on stdin: argv is visible in `ps`. Refuse
  # characters that could end the quoted config value.
  case "$CASAVPN_RELAY_TOKEN" in
    *[!A-Za-z0-9._~+/=-]*) _notify_log "CASAVPN_RELAY_TOKEN has characters a token should not have; not sending"; return 1 ;;
  esac
  url="${CASAVPN_RELAY_URL%/}/v1/events"
  if ! code="$(printf 'header = "Authorization: Bearer %s"\n' "$CASAVPN_RELAY_TOKEN" \
        | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 -K - \
            -X POST -H 'Content-Type: application/json' --data-binary "$json" "$url" 2>/dev/null)"; then
    _notify_log "the relay did not answer ($url)"
    _NOTIFY_RELAY_DOWN=1
    return 1
  fi
  case "$code" in
    200|202) return 0 ;;
    401) _notify_log "the relay refused the host token (HTTP 401): check CASAVPN_RELAY_TOKEN" ;;
    *) _notify_log "the relay answered HTTP $code for '$1'" ;;
  esac
  return 1
}

# casavpn_notify_ntfy <kind> <severity> <title> <body> [dedupe]
# Same return codes; 3 also when NTFY_URL is empty.
casavpn_notify_ntfy() {
  local kind="$1" sev="$2" title="$3" body="$4" key="${5:-}" prio tag dir file safe now last crc
  _notify_check "$kind" "$sev" || return 2
  [ -n "${NTFY_URL:-}" ] || return 3
  if [ "${CASAVPN_NOTIFY_DRY_RUN:-0}" = 1 ]; then printf 'would send to ntfy: [%s] %s: %s\n' "$sev" "$title" "$body"; return 0; fi
  dir="${CASAVPN_NOTIFY_STATE_DIR:-/var/lib/casavpn}"
  file=""
  if [ -n "$key" ] && [ -d "$dir" ]; then
    safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)-$(printf '%s' "$key" | cksum | cut -d' ' -f1)"
    file="$dir/ntfy-$safe"
    now="$(date +%s)"
    last="$(cat "$file" 2>/dev/null || true)"
    if [[ "$last" =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$CASAVPN_NOTIFY_REPEAT" ]; then return 0; fi
  fi
  case "$sev" in critical) prio=urgent; tag=rotating_light ;; warning) prio=high; tag=warning ;; *) prio=default; tag=information_source ;; esac
  title="$(printf '%s' "$title" | tr -d '\r\n')"
  if [ "$_NOTIFY_NTFY_DOWN" = 1 ]; then
    _notify_log "ntfy did not answer earlier in this run; not sending '$kind' (the next run retries)"
    return 1
  fi
  # The topic in NTFY_URL is the only secret of the channel, so the URL goes to curl
  # in a config on stdin, not in argv. Refuse characters that could end the value.
  # Brackets are allowed for an IPv6 host (https://[2001:db8::1]/topic); -g stops
  # curl from reading them as a URL glob.
  case "$NTFY_URL" in
    *[!][A-Za-z0-9._~:/?\&=%+,@-]*) _notify_log "NTFY_URL has characters a URL should not have; not sending"; return 1 ;;
  esac
  crc=0
  printf 'url = "%s"\n' "$NTFY_URL" \
    | curl -fsSg --max-time 10 --connect-timeout 5 -K - -H "Title: $title" -H "Priority: $prio" -H "Tags: $tag" \
        -d "$body" >/dev/null 2>&1 || crc=$?
  if [ "$crc" -ne 0 ]; then
    # 6 no host, 7 no connection, 28 timeout, 35 TLS, 52/56 empty reply or reset.
    case "$crc" in 6|7|28|35|52|56) _NOTIFY_NTFY_DOWN=1 ;; esac
    _notify_log "could not deliver '$kind' to ntfy"
    return 1
  fi
  if [ -n "$file" ]; then printf '%s\n' "$now" >"$file" 2>/dev/null || true; fi
  return 0
}

# casavpn_notify <kind> <severity> <title> <body> [dedupe]
# Every configured channel is tried, so one broken channel does not hide the event
# from the other.
casavpn_notify() {
  local r sent=0 failed=0
  if [ "${CASAVPN_NOTIFY_DRY_RUN:-0}" = 1 ]; then
    _notify_check "$1" "$2" || return 2
    printf 'would send: %s\n' "$(casavpn_notify_event_json "$@")"
    return 0
  fi
  r=0; casavpn_notify_relay "$@" || r=$?
  case "$r" in 0) sent=1 ;; 3) ;; 2) return 2 ;; *) failed=1 ;; esac
  r=0; casavpn_notify_ntfy "$@" || r=$?
  case "$r" in 0) sent=1 ;; 3) ;; 2) return 2 ;; *) failed=1 ;; esac
  if [ "$failed" = 1 ]; then return 1; fi
  if [ "$sent" = 0 ]; then return 3; fi
  return 0
}
