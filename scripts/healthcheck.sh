#!/usr/bin/env bash
#
# healthcheck.sh: verify every layer of the VPN, from outside in or on the host.
#
#   healthcheck.sh [options]            from your laptop: DNS, Reality, web port,
#                                       what must NOT be reachable, host services
#   healthcheck.sh --local              on the Pi: services, listeners, firewall,
#                                       SSH hardening, minClientVer, routing
#                                       rules, certificates, backups, disk
#
# Options:
#   --host <fqdn>      VPN hostname           (default CASAVPN_DOMAIN)
#   --ssh <user@host>  the Pi, for host checks (default CASAVPN_SSH_TARGET)
#   --vpn-port <n>     Reality port           (default CASAVPN_VPN_PORT, 443)
#   --web-port <n>     subscription port      (default CASAVPN_WEB_PORT, 8443)
#   --sni <name>       Reality camouflage     (default CASAVPN_REALITY_TARGET)
#   --env <file>       settings file          (default /etc/casavpn/casavpn.env)
#   -h, --help
#
# Exits non-zero if any critical check fails, so it also works from cron or a
# monitor. A warning does not fail the run. "UNVERIFIED" means the check could
# not be made, which is not the same as passing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="$HERE/lib"
[ -d "$LIBDIR" ] || LIBDIR=/usr/local/lib/casavpn
ENV_FILE="${CASAVPN_ENV:-/etc/casavpn/casavpn.env}"
LOCAL=0
DOMAIN_ARG=""; SSH_ARG=""; VPN_PORT_ARG=""; WEB_PORT_ARG=""; SNI_ARG=""

usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --local)    LOCAL=1; shift ;;
    --host)     [ $# -ge 2 ] || usage; DOMAIN_ARG="$2"; shift 2 ;;
    --ssh|--pi) [ $# -ge 2 ] || usage; SSH_ARG="$2"; shift 2 ;;
    --vpn-port) [ $# -ge 2 ] || usage; VPN_PORT_ARG="$2"; shift 2 ;;
    --web-port) [ $# -ge 2 ] || usage; WEB_PORT_ARG="$2"; shift 2 ;;
    --sni)      [ $# -ge 2 ] || usage; SNI_ARG="$2"; shift 2 ;;
    --env)      [ $# -ge 2 ] || usage; ENV_FILE="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

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

DOMAIN="${DOMAIN_ARG:-$(env_get CASAVPN_DOMAIN)}"
SSH_TARGET="${SSH_ARG:-$(env_get CASAVPN_SSH_TARGET)}"
VPN_PORT="${VPN_PORT_ARG:-$(env_get CASAVPN_VPN_PORT)}"; VPN_PORT="${VPN_PORT:-443}"
WEB_PORT="${WEB_PORT_ARG:-$(env_get CASAVPN_WEB_PORT)}"; WEB_PORT="${WEB_PORT:-8443}"
SNI="${SNI_ARG:-$(env_get CASAVPN_REALITY_TARGET)}"; SNI="${SNI:-www.apple.com}"
PANEL_PORT="$(env_get CASAVPN_PANEL_PORT)"; PANEL_PORT="${PANEL_PORT:-2053}"
SUB_PORT="$(env_get CASAVPN_SUB_PORT)"; SUB_PORT="${SUB_PORT:-2096}"
MIN_VER="$(env_get CASAVPN_MIN_CLIENT_VER)"; MIN_VER="${MIN_VER:-1.8.0}"
DB="${CASAVPN_DB:-/etc/x-ui/x-ui.db}"
LE_DIR="${CASAVPN_LE_DIR:-/etc/letsencrypt/live}"
BACKUP_DEST="${CASAVPN_BACKUP_DEST:-$(env_get CASAVPN_BACKUP_DEST)}"; BACKUP_DEST="${BACKUP_DEST:-/var/backups/casavpn}"

[ -n "$DOMAIN" ] || { echo "No hostname: pass --host or set CASAVPN_DOMAIN in $ENV_FILE." >&2; exit 2; }

# --- output -------------------------------------------------------------------
fails=0; warns=0
if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=""; Y=""; R=""; B=""; Z=""; fi
pass() { printf '  %sok%s    %s\n' "$G" "$Z" "$*"; }
warn() { warns=$((warns + 1)); printf '  %swarn%s  %s\n' "$Y" "$Z" "$*"; }
fail() { fails=$((fails + 1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$*"; }
heading() { printf '\n%s%s%s\n' "$B" "$*" "$Z"; }

# A hung connection must not hang the run: use timeout/gtimeout when present.
if command -v timeout >/dev/null 2>&1; then TMO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TMO=gtimeout
else TMO=""; fi
tmo() { local secs="$1"; shift; if [ -n "$TMO" ]; then "$TMO" "$secs" "$@"; else "$@"; fi; }

# priv <cmd...>: as root, directly or through non-interactive sudo.
priv() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }

# days_until <openssl enddate string>: whole days, or empty when unparsable.
days_until() {
  local end="$1" epoch
  epoch="$(date -j -f "%b %d %T %Y %Z" "$end" +%s 2>/dev/null || date -d "$end" +%s 2>/dev/null)" || return 0
  [ -n "$epoch" ] || return 0
  echo $(((epoch - $(date +%s)) / 86400))
}

cert_days_check() { # <label> <days>
  local label="$1" days="$2"
  if [ -z "$days" ]; then warn "$label: expiry date could not be read (UNVERIFIED)"
  elif [ "$days" -lt 0 ]; then fail "$label EXPIRED $((-days)) days ago"
  elif [ "$days" -lt 14 ]; then fail "$label expires in $days days: renewal is failing"
  elif [ "$days" -lt 30 ]; then warn "$label expires in $days days"
  else pass "$label valid for $days more days"; fi
}

# ===================================================================== local ==
run_local() {
  local unit out rc tpl

  heading "1. Services"
  for unit in x-ui nginx nftables fail2ban; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then pass "$unit is active"
    elif [ "$unit" = fail2ban ] || [ "$unit" = nftables ]; then warn "$unit is not active"
    else fail "$unit is NOT active"; fi
  done
  for unit in casavpn-ddns.timer casavpn-backup.timer; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then pass "$unit is enabled"
    else warn "$unit is not enabled"; fi
  done

  heading "2. Listeners (what is open, and to whom)"
  out="$(ss -H -ltn 2>/dev/null)"
  if [ -z "$out" ]; then warn "could not list sockets (UNVERIFIED)"
  else
    if grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):${VPN_PORT}[[:space:]]" <<<"$out"; then pass "VPN port $VPN_PORT listens on all interfaces"
    else fail "nothing listens on the VPN port $VPN_PORT"; fi
    local p
    for p in "$PANEL_PORT" "$SUB_PORT"; do
      if grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):${p}[[:space:]]" <<<"$out"; then
        fail "port $p listens on ALL interfaces: it must be 127.0.0.1 only (see docs/HARDENING.md)"
      elif grep -Eq "(^|[[:space:]])(127\.0\.0\.1|\[::1\]):${p}[[:space:]]" <<<"$out"; then
        pass "port $p is loopback-only"
      else
        warn "port $p is not listening (is x-ui running?)"
      fi
    done
  fi

  heading "3. Firewall and SSH"
  if priv nft list table inet casavpn >/dev/null 2>&1; then pass "nftables table 'inet casavpn' is loaded"
  else warn "nftables table 'inet casavpn' is not loaded (or needs root): the host firewall is UNVERIFIED"; fi
  if out="$(priv sshd -T 2>/dev/null)" && [ -n "$out" ]; then
    if grep -qi '^passwordauthentication no' <<<"$out"; then pass "SSH: password login is off"; else fail "SSH: password login is ON"; fi
    if grep -Eqi '^permitrootlogin (no|prohibit-password|without-password)' <<<"$out"; then pass "SSH: root cannot log in with a password"; else fail "SSH: root can log in with a password"; fi
  else
    warn "could not read the effective sshd configuration (UNVERIFIED)"
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    if priv fail2ban-client status sshd >/dev/null 2>&1; then pass "fail2ban sshd jail is running"
    else warn "fail2ban sshd jail is not running"; fi
  fi

  heading "4. Panel database"
  if [ ! -e "$DB" ] && ! priv test -e "$DB" 2>/dev/null; then
    fail "no 3x-ui database at $DB"
  else
    if out="$(priv python3 "$LIBDIR/set_min_client_ver.py" --db "$DB" --version "$MIN_VER" --check 2>&1)"; then
      pass "Reality minClientVer is $MIN_VER"
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then fail "$out"; else warn "minClientVer could not be checked: $out"; fi
    fi
    if tpl="$(priv sqlite3 "$DB" "select value from settings where key='xrayTemplateConfig';" 2>/dev/null)" && [ -n "$tpl" ]; then
      if out="$(python3 "$LIBDIR/check_xray_template.py" <<<"$tpl" 2>&1)"; then pass "routing: $out"
      else fail "routing: $out (a custom template dropped the default rules)"; fi
    else
      warn "Xray template not stored in the database: the panel defaults apply (block rules UNVERIFIED)"
    fi
  fi

  heading "5. Certificate"
  if [ -r "$LE_DIR/$DOMAIN/fullchain.pem" ] || priv test -r "$LE_DIR/$DOMAIN/fullchain.pem" 2>/dev/null; then
    out="$(priv openssl x509 -noout -enddate -in "$LE_DIR/$DOMAIN/fullchain.pem" 2>/dev/null | cut -d= -f2)"
    cert_days_check "certificate for $DOMAIN" "$(days_until "$out")"
  else
    warn "no certificate at $LE_DIR/$DOMAIN (skipped; fine if the web port is not used yet)"
  fi

  heading "6. DNS"
  local dns_ip pub_ip
  dns_ip="$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1)"
  pub_ip="$(tmo 12 curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$dns_ip" ]; then fail "$DOMAIN does not resolve"
  elif [ -z "$pub_ip" ]; then warn "could not learn this host's public IP; DNS correctness is UNVERIFIED"
  elif [ "$dns_ip" = "$pub_ip" ]; then pass "$DOMAIN resolves to this host's public IP ($pub_ip)"
  else fail "$DOMAIN resolves to $dns_ip but this host is $pub_ip: run 'sudo casavpn-ddns --force'"; fi

  heading "7. Backups and disk"
  local newest
  newest="$(find "$BACKUP_DEST" -maxdepth 1 -name 'casavpn-*.tar.zst.age' -mtime -3 2>/dev/null | head -n1)"
  if [ -n "$newest" ]; then pass "a backup newer than 3 days exists"
  elif [ -d "$BACKUP_DEST" ]; then fail "no backup newer than 3 days in $BACKUP_DEST"
  else warn "no backup directory $BACKUP_DEST yet"; fi
  local used
  used="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  if [ -z "$used" ]; then warn "disk usage unknown"
  elif [ "$used" -ge 90 ]; then fail "root filesystem ${used}% full"
  elif [ "$used" -ge 80 ]; then warn "root filesystem ${used}% full"
  else pass "root filesystem ${used}% full"; fi
}

# ==================================================================== remote ==
run_remote() {
  local dns_ip pi_ip target cert_subject verify code expiry cert_host
  local -a resolve_args

  heading "1. DNS"
  # DNS must equal the Pi's public IP, not the address of whatever network this
  # script runs on (away from home those differ, which is not a fault). The
  # Pi's own view comes over SSH; without SSH we can only say it is unverified.
  dns_ip="$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1)"
  pi_ip=""
  if [ -n "$SSH_TARGET" ]; then
    pi_ip="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" 'curl -4 -fsS --max-time 10 https://api.ipify.org' 2>/dev/null | tr -d '[:space:]')"
  fi
  if [ -z "$dns_ip" ]; then fail "$DOMAIN does not resolve"; else pass "$DOMAIN resolves to $dns_ip"; fi
  if [ -n "$pi_ip" ]; then
    if [ "$dns_ip" = "$pi_ip" ]; then pass "DNS matches the Pi's public IP ($pi_ip)"
    else fail "DNS ($dns_ip) != the Pi's public IP ($pi_ip): the VPN is unreachable by name; run 'sudo casavpn-ddns --force' on the Pi"; fi
  else
    warn "could not ask the Pi for its public IP (no --ssh target, or no SSH): DNS correctness is UNVERIFIED"
  fi

  heading "2. VPN transport (Reality on :$VPN_PORT)"
  # The camouflage check proves an unauthenticated probe sees a genuine
  # certificate for $SNI. It does NOT prove an authenticated tunnel works; only
  # a real client connection does.
  target="${dns_ip:-$DOMAIN}"
  if nc -z -G 5 "$target" "$VPN_PORT" >/dev/null 2>&1 || nc -z -w 5 "$target" "$VPN_PORT" >/dev/null 2>&1; then
    pass "TCP $target:$VPN_PORT accepts connections"
    cert_subject="$(echo | tmo 15 openssl s_client -connect "$target:$VPN_PORT" -servername "$SNI" 2>/dev/null | grep -m1 '^subject=')"
    verify="$(echo | tmo 15 openssl s_client -connect "$target:$VPN_PORT" -servername "$SNI" 2>/dev/null | grep -m1 'Verify return code')"
    # "www.example.org" -> "example": the second-to-last label identifies the site.
    local label
    label="$(awk -F. '{ print (NF >= 2 ? $(NF-1) : $1) }' <<<"$SNI")"
    if grep -qi "$label" <<<"$cert_subject"; then
      pass "Reality camouflage healthy: serving a genuine $SNI certificate"
      if grep -q '0 (ok)' <<<"$verify"; then pass "certificate chain verifies"; else warn "chain did not verify: $verify"; fi
    else
      fail "unexpected certificate on :$VPN_PORT: Reality may be misconfigured"
      [ -n "$cert_subject" ] && printf '        %s\n' "$cert_subject"
    fi
  else
    fail "TCP $target:$VPN_PORT unreachable: check the router port forward"
  fi

  heading "3. Subscription / web port (:$WEB_PORT)"
  # Pin curl to the address resolved above. Left to itself curl uses the OS
  # resolver, whose cache can hold a stale answer long after DNS is correct.
  resolve_args=()
  [ -n "$dns_ip" ] && resolve_args=(--resolve "$DOMAIN:$WEB_PORT:$dns_ip")
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${resolve_args[@]+"${resolve_args[@]}"} "https://$DOMAIN:$WEB_PORT/" 2>/dev/null)"
  case "$code" in
    000|"") fail "no HTTPS response on :$WEB_PORT" ;;
    403|404) pass "nginx answers on :$WEB_PORT (HTTP $code: the panel is not exposed here)" ;;
    200|302) warn "HTTP $code on :$WEB_PORT/ from the internet: is the panel reachable? Check docs/HARDENING.md" ;;
    *) warn "unexpected HTTP $code on :$WEB_PORT" ;;
  esac
  cert_host="${dns_ip:-$DOMAIN}"
  expiry="$(echo | tmo 15 openssl s_client -connect "$cert_host:$WEB_PORT" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$expiry" ]; then cert_days_check "TLS certificate on :$WEB_PORT" "$(days_until "$expiry")"; fi

  heading "4. What must NOT be reachable from the internet"
  local p
  for p in "$PANEL_PORT" "$SUB_PORT" 22; do
    if nc -z -G 4 "$target" "$p" >/dev/null 2>&1 || nc -z -w 4 "$target" "$p" >/dev/null 2>&1; then
      # From inside the LAN a closed-to-the-world port can still answer; only
      # a result from outside is conclusive, so this is a warning.
      warn "port $p answers from here: fine on the home LAN, a problem from the internet"
    else
      pass "port $p is closed"
    fi
  done

  heading "5. Host services"
  if [ -z "$SSH_TARGET" ]; then
    warn "no --ssh target: host checks skipped (run 'healthcheck.sh --local' on the Pi)"
  elif ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" true 2>/dev/null; then
    pass "SSH to $SSH_TARGET"
    local unit
    for unit in x-ui nginx; do
      if ssh -o BatchMode=yes "$SSH_TARGET" "systemctl is-active --quiet $unit" 2>/dev/null; then pass "$unit is active"
      else fail "$unit is NOT active"; fi
    done
    if ssh -o BatchMode=yes "$SSH_TARGET" "systemctl is-enabled --quiet casavpn-ddns.timer" 2>/dev/null; then pass "casavpn-ddns.timer is enabled"
    else warn "casavpn-ddns.timer not enabled: DNS will not self-heal (see docs/DYNAMIC-IP.md)"; fi
  else
    warn "cannot SSH to $SSH_TARGET: host checks skipped (expected away from the LAN)"
  fi
}

if [ "$LOCAL" = 1 ]; then run_local; else run_remote; fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '%sAll critical checks passed%s (%d warning(s)).\n' "$G" "$Z" "$warns"
  exit 0
fi
printf '%s%d critical check(s) failed%s (%d warning(s)). See docs/RUNBOOK.md\n' "$R" "$fails" "$Z" "$warns"
exit 1
