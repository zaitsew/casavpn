#!/usr/bin/env bash
#
# Offline tests for scripts/casavpn-os-upgrade. PATH stubs stand in for apt-get,
# dpkg, systemctl, ss, nft, df and curl; each answers from files in $FAKE and logs
# what it was asked. The relay is the stub curl, so the events can be read back.

# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/casavpn-os-upgrade"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-os-upgrade-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

command -v jq >/dev/null 2>&1 || { echo "jq missing, skipping os-upgrade tests"; exit 0; }

pass=0; fail=0
OUT=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 12 | sed 's/^/       /'; }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$RC, want $2)"; fi; }
said()  { if grep -q -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 (output lacks: $2)"; fi; }
logged() { if grep -q -- "$3" "$FAKE/$2" 2>/dev/null; then ok "$1"; else bad "$1 ($2 lacks: $3)"; fi; }
not_logged() { if grep -q -- "$3" "$FAKE/$2" 2>/dev/null; then bad "$1 ($2 has: $3)"; else ok "$1"; fi; }
exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
absent() { if [ -e "$2" ]; then bad "$1 (present: $2)"; else ok "$1"; fi; }
event() { # <name> <kind> <severity>: the relay got an event of that kind and severity
  if grep -q "\"kind\":\"$2\",\"severity\":\"$3\"" "$FAKE/requests" 2>/dev/null; then ok "$1"; else bad "$1 (no $2/$3 event)"; fi
}

# --- stubs ----------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
mk() { printf '%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
mk apt-get '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$FAKE/apt.log"
for a in "$@"; do
  case "$a" in
    -s) cat "$FAKE/plan" 2>/dev/null; exit "$(cat "$FAKE/sim_rc" 2>/dev/null || echo 0)" ;;
    update) exit "$(cat "$FAKE/update_rc" 2>/dev/null || echo 0)" ;;
    full-upgrade) [ -f "$FAKE/upgrade_rc" ] && { echo "E: stub failure"; exit "$(cat "$FAKE/upgrade_rc")"; }; exit 0 ;;
  esac
done
exit 0'
mk dpkg '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$FAKE/dpkg.log"
[ "$1" = --audit ] && cat "$FAKE/audit" 2>/dev/null
exit 0'
mk systemctl '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$FAKE/systemctl.log"
case "$1" in
  is-active) u="${3:-$2}"; [ -f "$FAKE/active/$u" ] && exit 0; exit 3 ;;
  reboot) exit 0 ;;
esac
exit 0'
mk ss '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$FAKE/ss.log"
cat "$FAKE/ss" 2>/dev/null'
mk nft '#!/usr/bin/env bash
cat "$FAKE/nft" 2>/dev/null'
mk df '#!/usr/bin/env bash
printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 1 1 %s 1%% /\n" "$(cat "$FAKE/df")"'
mk ddns '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$FAKE/ddns.log"
exit "$(cat "$FAKE/ddns_rc" 2>/dev/null || echo 0)"'
mk curl '#!/usr/bin/env bash
data=""
while [ $# -gt 0 ]; do case "$1" in --data-binary) data="$2"; shift ;; -K) cat >/dev/null ;; esac; shift; done
printf "%s\n" "$data" >>"$FAKE/requests"
printf 202'
export PATH="$BIN:$PATH"

# --- one fresh host per case ------------------------------------------------------
UNITS="ssh nginx x-ui nftables"
fresh() {
  FAKE="$T/case$((pass + fail))-$RANDOM"; export FAKE
  mkdir -p "$FAKE/active" "$FAKE/state" "$FAKE/boot"
  for u in $UNITS; do : >"$FAKE/active/$u"; done
  echo 5000000 >"$FAKE/df"
  printf 'LISTEN 0 4096 *:10443 *:*\n' >"$FAKE/ss"
  printf 'table inet filter {\n}\n' >"$FAKE/nft"
  printf 'Inst tzdata [2025b-4] (2025c-1 Debian:13.2/stable [all])\nInst tailscale [1.88.1] (1.90.0 tailscale.com [arm64])\nConf tzdata (2025c-1 Debian:13.2/stable [all])\n' >"$FAKE/plan"
  cat >"$FAKE/env" <<EOF
CASAVPN_VPN_PORT=10443
CASAVPN_RELAY_URL=https://relay.example.net
CASAVPN_RELAY_TOKEN=host-token-123
EOF
}
run() {
  RC=0
  OUT="$(CASAVPN_ENV_FILE="$FAKE/env" CASAVPN_OS_UPGRADE_STATE_DIR="$FAKE/state" \
    CASAVPN_REBOOT_REQUIRED="$FAKE/reboot-required" CASAVPN_OS_UPGRADE_BOOT="$FAKE/boot" \
    CASAVPN_OS_UPGRADE_DDNS="$BIN/ddns" CASAVPN_OS_UPGRADE_WAIT="${WAIT:-0}" CASAVPN_OS_UPGRADE_STEP=0 \
    CASAVPN_LIB_DIR="$ROOT/scripts/lib" bash "$SCRIPT" "$@" 2>&1)" || RC=$?
}

echo "casavpn-os-upgrade"

fresh; run
rc_is "an upgrade with packages exits 0" 0
logged "runs apt-get update first" apt.log "^update"
logged "upgrades with --force-confold" apt.log "force-confold.*full-upgrade"
logged "reboots after upgrading" systemctl.log "^reboot"
exists "leaves the post-check pending" "$FAKE/state/os-upgrade-pending"
logged "records the units that were active" state/os-upgrade-pending "units=ssh nginx x-ui nftables"
logged "records the package list" state/os-upgrade-pending "list=tzdata tailscale"
absent "no event before the reboot" "$FAKE/requests"

# The boot after it.
run --post-check
rc_is "post-check passes" 0
event "post-check sends host.upgraded" host.upgraded info
said "reports the package count" "2 package(s) upgraded; rebooted"
absent "post-check clears the pending file" "$FAKE/state/os-upgrade-pending"
logged "keeps the result" state/os-upgrade-last "result=ok"
logged "runs the DDNS check" ddns.log "--check"
logged "looks for a listener on the VPN port" ss.log "sport = :10443"

run --post-check
rc_is "a second post-check has nothing to do" 0
said "says so" "no upgrade is pending"

fresh; run
rm -f "$FAKE/active/x-ui"; : >"$FAKE/ss"; echo 1 >"$FAKE/ddns_rc"
run --post-check
rc_is "a failed post-check exits 1" 1
event "sends host.upgrade_failed critical" host.upgrade_failed critical
said "names the unit" "x-ui is not active"
said "names the VPN port" "nothing listens on the VPN port 10443"
said "names DNS" "DNS does not point at this host"
absent "does not repeat on the next boot" "$FAKE/state/os-upgrade-pending"
logged "keeps the failure" state/os-upgrade-last "result=check-failed"

fresh; run
rm -f "$FAKE/active/fail2ban"
run --post-check
rc_is "a unit that was not active before is not expected" 0

fresh; : >"$FAKE/plan"; run
rc_is "nothing to upgrade exits 0" 0
not_logged "does not run full-upgrade" apt.log "^-y.*full-upgrade"
not_logged "does not reboot" systemctl.log "^reboot"
absent "nothing pending" "$FAKE/state/os-upgrade-pending"

fresh; : >"$FAKE/plan"; : >"$FAKE/reboot-required"; run
rc_is "reboot-required alone" 0
logged "reboots for /run/reboot-required" systemctl.log "^reboot"

fresh; printf 'Inst tzdata [1] (2 x)\nRemv openssh-server [1:9.9]\n' >"$FAKE/plan"; run
rc_is "a plan that removes a protected package is refused" 3
said "names it" "protected packages: openssh-server"
not_logged "nothing is upgraded" apt.log "-y.*full-upgrade"
event "sends a warning" host.upgrade_failed warning
not_logged "no reboot" systemctl.log "^reboot"

fresh; printf 'Remv a [1]\nRemv b [1]\nRemv c [1]\nRemv d [1]\n' >"$FAKE/plan"; run
rc_is "a plan that removes 4 packages is refused" 3
said "gives the count" "removes 4 packages (limit 3)"

fresh; echo 100 >"$FAKE/upgrade_rc"; run
rc_is "a failed full-upgrade exits 1" 1
logged "repairs dpkg" dpkg.log "--configure -a"
event "sends a critical alert" host.upgrade_failed critical
not_logged "does not reboot" systemctl.log "^reboot"
absent "nothing pending" "$FAKE/state/os-upgrade-pending"

fresh; echo 1 >"$FAKE/update_rc"; run
rc_is "a failed apt-get update exits 1" 1
not_logged "upgrades nothing" apt.log "^-y.*full-upgrade"

fresh; echo 'The following packages are only half configured' >"$FAKE/audit"; run
rc_is "a dirty dpkg stops the run" 1
said "says how to fix it" "dpkg --configure -a"
not_logged "runs no apt-get" apt.log "update"

fresh; echo 1000 >"$FAKE/df"; run
rc_is "a full disk stops the run" 1
said "says why" "under 1 GB free"

fresh; run --dry-run
rc_is "dry run exits 0" 0
not_logged "dry run does not update" apt.log "^update"
not_logged "dry run does not upgrade" apt.log "-y.*full-upgrade"
not_logged "dry run does not reboot" systemctl.log "^reboot"
said "dry run lists the plan" "Inst tailscale"
absent "dry run sends nothing" "$FAKE/requests"

fresh; run --no-reboot
rc_is "--no-reboot upgrades and checks" 0
not_logged "does not reboot" systemctl.log "^reboot"
said "says no reboot" "no reboot; all checks passed"
event "sends host.upgraded" host.upgraded info

fresh; echo 'CASAVPN_OS_UPGRADE_REBOOT=never' >>"$FAKE/env"; run
rc_is "REBOOT=never upgrades without a reboot" 0
not_logged "does not reboot" systemctl.log "^reboot"

fresh; echo 'CASAVPN_OS_UPGRADE_UNITS="casa-ddns.timer x-ui"' >>"$FAKE/env"; : >"$FAKE/active/casa-ddns.timer"; run
logged "watches the extra units, once each" state/os-upgrade-pending "units=ssh nginx x-ui nftables casa-ddns.timer$"

fresh; run --bogus
rc_is "an unknown option exits 2" 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
