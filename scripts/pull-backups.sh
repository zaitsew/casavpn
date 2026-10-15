#!/usr/bin/env bash
#
# pull-backups.sh — copy the host's encrypted backups to this machine (your
# laptop or another box at a different address), and shout when they stop
# arriving. launchd (macOS) or cron/systemd (Linux) runs it daily; see
# config/launchd/com.casavpn.pull-backups.plist and docs/BACKUP.md.
#
# Only "*.age" files are ever pulled, so a plaintext archive can never be copied
# off by accident. Nothing here can decrypt them: the age identity is not needed
# (and must not be present) for pulling; scripts/restore-drill.sh uses it.
#
# Environment:
#   CASAVPN_SSH_TARGET   REQUIRED. ssh target of the VPN host, e.g. pi@<LAN_IP>
#                        or an ssh-config alias
#   CASAVPN_REMOTE_DIR   directory on the host (default: /var/backups/casavpn)
#   CASAVPN_BACKUP_LOCAL where to keep copies
#                        (default: ${XDG_DATA_HOME:-~/.local/share}/casavpn/backups)
#   CASAVPN_KEEP_LOCAL   how many to keep locally (default: 30)
#   CASAVPN_REMOTE_MAX_AGE_H     newest remote backup older than this = ALERT (48)
#   CASAVPN_LOCAL_MAX_AGE_DAYS   host unreachable AND newest local copy older than
#                                this = ALERT (7)
#   CASAVPN_PULL_NTFY_URL        optional: also push alerts to this ntfy topic
#   CASAVPN_PULL_LOCAL_SRC       test hook: treat this local directory as the host
#
# Exit status:
#   0  pulled, newest remote backup is fresh   -- or --
#      host unreachable but the newest local copy is still recent (warning only;
#      a laptop is not always on the home network)
#   2  the host answered but its newest backup is older than 48 h (or there is none)
#   3  the host is unreachable and the newest local copy is older than 7 days
#   64 usage / setup error

set -euo pipefail
umask 077

PI="${CASAVPN_SSH_TARGET:-}"
REMOTE_DIR="${CASAVPN_REMOTE_DIR:-/var/backups/casavpn}"
LOCAL="${CASAVPN_BACKUP_LOCAL:-${XDG_DATA_HOME:-$HOME/.local/share}/casavpn/backups}"
KEEP="${CASAVPN_KEEP_LOCAL:-30}"
REMOTE_MAX_H="${CASAVPN_REMOTE_MAX_AGE_H:-48}"
LOCAL_MAX_D="${CASAVPN_LOCAL_MAX_AGE_DAYS:-7}"
LOCAL_SRC="${CASAVPN_PULL_LOCAL_SRC:-}"
NTFY="${CASAVPN_PULL_NTFY_URL:-}"

case "${1:-}" in
  "") ;;
  -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  *) echo "usage: $0 (configure through the environment; see --help)" >&2; exit 64 ;;
esac

[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || { echo "CASAVPN_KEEP_LOCAL must be a positive integer" >&2; exit 64; }

if [[ -z "$PI" && -z "$LOCAL_SRC" ]]; then
  echo "CASAVPN_SSH_TARGET is not set (e.g. pi@<LAN_IP>); see --help" >&2
  exit 64
fi

log()   { printf '%s\n' "$*" >&2; }
alert() {
  printf 'ALERT: %s\n' "$*" >&2
  # Best effort notifications: macOS banner, Linux desktop, optional ntfy push.
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$*\" with title \"CasaVPN backup\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "CasaVPN backup" "$*" >/dev/null 2>&1 || true
  fi
  if [[ -n "$NTFY" ]]; then
    curl -fsS --max-time 10 -H "Title: CasaVPN backup" -H "Priority: high" -d "$*" "$NTFY" >/dev/null 2>&1 || true
  fi
}

# "20261015T033000Z" -> epoch seconds (works with BSD date on macOS and GNU date).
stamp_to_epoch() {
  local s="$1" iso
  iso="${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}"
  if date -u -d "$iso UTC" +%s 2>/dev/null; then return 0; fi
  date -u -j -f '%Y%m%dT%H%M%SZ' "$s" +%s
}

stamp_of() {   # casavpn-20261015T033000Z.tar.zst.age -> 20261015T033000Z
  local b
  b="$(basename "$1")"; b="${b#casavpn-}"; printf '%s' "${b%%.*}"
}

NAME_RE='^casavpn-[0-9]{8}T[0-9]{6}Z\.tar\.(zst|gz)\.age$'

newest_of() {  # stdin: file names; prints the newest *.age name, or nothing
  { grep -E "$NAME_RE" || true; } | sort | tail -n 1
}

human_age() {  # seconds -> "5h" / "3d"
  local s="$1"
  if (( s < 172800 )); then printf '%dh' $((s / 3600)); else printf '%dd' $((s / 86400)); fi
}

list_local() {  # basenames of local archives, oldest first
  local f
  for f in "$LOCAL"/casavpn-*.age; do
    if [[ -e "$f" ]]; then basename "$f"; fi
  done | grep -E "$NAME_RE" | sort || true
}

mkdir -p "$LOCAL"
chmod 0700 "$LOCAL"
NOW="$(date -u +%s)"

# --- ask the host what it has ---------------------------------------------------

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
reachable=1
listing=""
if [[ -n "$LOCAL_SRC" ]]; then
  if [[ -d "$LOCAL_SRC" ]]; then listing="$(ls -1 "$LOCAL_SRC")"; else reachable=0; fi
else
  # shellcheck disable=SC2029  # REMOTE_DIR is meant to expand on this side
  if ! listing="$(ssh "${SSH_OPTS[@]}" "$PI" "ls -1 '$REMOTE_DIR'" 2>/dev/null)"; then
    reachable=0
  fi
fi

newest_local_name() { list_local | newest_of; }

if [[ "$reachable" -eq 0 ]]; then
  nl="$(newest_local_name)"
  if [[ -z "$nl" ]]; then
    alert "host unreachable ($PI) and there is NO local backup in $LOCAL"
    exit 3
  fi
  age_s=$(( NOW - $(stamp_to_epoch "$(stamp_of "$nl")") ))
  if (( age_s > LOCAL_MAX_D * 86400 )); then
    alert "host unreachable ($PI) and the newest local backup ($nl) is $(human_age "$age_s") old (limit ${LOCAL_MAX_D}d). Get on the home network (or fix the connection) and run this again."
    exit 3
  fi
  log "WARNING: host unreachable ($PI); keeping existing copies. Newest local: $nl ($(human_age "$age_s") old)."
  exit 0
fi

# --- pull ---------------------------------------------------------------------
# --checksum, not --ignore-existing: an archive is immutable, so any difference
# means the local copy is damaged and must be replaced. rsync writes a temp file
# and renames it, so a failed transfer never replaces a good copy with half a one.
# -rlt, not -a: no owner/group, which a normal user cannot apply anyway. Some
# rsync builds (macOS openrsync) copy the mode regardless, so tighten it below.

newest_remote="$(printf '%s\n' "$listing" | newest_of)"

if [[ -n "$LOCAL_SRC" ]]; then
  rsync -rlt --checksum \
    --include='casavpn-*.age' --exclude='*' "$LOCAL_SRC/" "$LOCAL/"
else
  rsync -rlt --checksum \
    -e "ssh ${SSH_OPTS[*]}" \
    --include='casavpn-*.age' --exclude='*' "$PI:$REMOTE_DIR/" "$LOCAL/"
fi

# Mode 0600 whatever the host said; drop empty files (a damaged copy).
for f in "$LOCAL"/casavpn-*.age; do
  [[ -e "$f" ]] || continue
  if [[ ! -s "$f" ]]; then log "removing empty file: $f"; rm -f "$f"; continue; fi
  chmod 0600 "$f"
done

# --- retention ----------------------------------------------------------------

n=0
while IFS= read -r old; do
  n=$((n + 1))
  if [[ "$n" -gt "$KEEP" ]]; then
    log "pruning $old"
    rm -f "$LOCAL/$old"
  fi
done < <(list_local | sort -r)

# --- dead-man's switch --------------------------------------------------------

if [[ -z "$newest_remote" ]]; then
  alert "the host answered but has NO backups in $REMOTE_DIR. Is casavpn-backup.timer running? (ssh $PI systemctl status casavpn-backup.timer)"
  exit 2
fi

age_s=$(( NOW - $(stamp_to_epoch "$(stamp_of "$newest_remote")") ))
if (( age_s > REMOTE_MAX_H * 3600 )); then
  alert "the newest backup on the host ($newest_remote) is $(human_age "$age_s") old (limit ${REMOTE_MAX_H}h). The nightly job has stopped: ssh $PI journalctl -u casavpn-backup.service -n 50"
  exit 2
fi

# Heartbeat: the last time a pull succeeded against a fresh remote backup.
printf '%s newest=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$newest_remote" >"$LOCAL/.last-pull"
log "ok: newest backup $newest_remote ($(human_age "$age_s") old); $(list_local | wc -l | tr -d ' ') copies in $LOCAL"
