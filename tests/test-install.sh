#!/usr/bin/env bash
#
# Tests for install.sh (dry run, settings validation, generated configs, the
# first-run settings file) and for scripts/lib/common.sh (env parsing, the
# 3x-ui tarball verification). No root, no network, nothing on the host changes.

# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-install-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

pass=0; fail=0
OUT=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | tail -n 15 | sed 's/^/       /'; }
expect() { # <name> <rc> [pattern]
  if [ "$RC" -ne "$2" ]; then bad "$1 (rc=$RC, want $2)"; return; fi
  if [ -n "${3:-}" ] && ! grep -q -- "$3" <<<"$OUT"; then bad "$1 (output lacks: $3)"; return; fi
  ok "$1"
}
yes() { # <name> <command...>: ok if the command succeeds
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
lacks() { # <name> <pattern>
  if grep -q -- "$2" <<<"$OUT"; then bad "$1 (output has: $2)"; else ok "$1"; fi
}

good_env() { # <file> [extra lines...]
  local f="$1"; shift
  { printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_LAN_CIDR=192.168.0.0/24\nCASAVPN_ADMIN_USER=alice\nCASAVPN_REALITY_TARGET=www.example.net\n'; printf '%s\n' "$@"; } >"$f"
}

echo "install.sh --dry-run"
OUT="$(CASAVPN_ENV=/nonexistent "$INSTALL" --dry-run 2>&1)"; RC=$?
expect "works with no env file and no root" 0 "dry run finished: nothing was changed"
expect "  ...and says it used the example values" 0 "casavpn.env.example"
good_env "$T/ok.env"
OUT="$("$INSTALL" --dry-run --env "$T/ok.env" 2>&1)"; RC=$?
expect "plans the packages" 0 "apt-get install"
expect "plans the 3x-ui release from the pin" 0 "pinned release: v"
expect "plans the SSH hardening for the admin user" 0 "authorized key for alice"
expect "plans the firewall check against the LAN" 0 "from 192.168.0.0/24"
expect "prints the inbound guide with the configured ports" 0 "Port                443"
expect "prints the router step with both ports" 0 "443  (the VPN)      8443  (client subscriptions)"
expect "tells the user not to forward SSH or the panel" 0 "Do not forward 22, 2053 or 2096"
lacks  "never prints a credential" "PANEL_PASSWORD="
OUT="$("$INSTALL" --dry-run --env "$T/ok.env" --skip-firewall --skip-ssh --skip-3xui 2>&1)"; RC=$?
expect "--skip-* leaves the step out" 0 "dry run finished"
lacks  "  ...firewall step absent" "== Firewall"
lacks  "  ...ssh step absent" "== SSH hardening"
good_env "$T/cf.env" "CF_API_TOKEN=tok" "CF_ZONE_ID=zone"
OUT="$("$INSTALL" --dry-run --env "$T/cf.env" 2>&1)"; RC=$?
expect "a Cloudflare token without the licence acceptance skips the certificate" 0 "Subscriber Agreement"
good_env "$T/cf2.env" "CF_API_TOKEN=tok" "CF_ZONE_ID=zone" "CASAVPN_ACME_AGREE_TOS=1"
OUT="$("$INSTALL" --dry-run --env "$T/cf2.env" 2>&1)"; RC=$?
expect "  ...and with it, plans certbot with DNS-01" 0 "certbot certonly --dns-cloudflare"
expect "  ...and adds the certbot packages" 0 "python3-certbot-dns-cloudflare"
lacks  "  ...and the token is not printed" "tok$"

echo "install.sh settings validation"
bad_env() { # <name> <pattern> <extra lines...>
  local name="$1" pat="$2"; shift 2
  good_env "$T/bad.env" "$@"
  OUT="$("$INSTALL" --dry-run --env "$T/bad.env" 2>&1)"; RC=$?
  expect "$name" 1 "$pat"
}
{ printf 'CASAVPN_DOMAIN=vpn.example.com\nCASAVPN_REALITY_TARGET=\n'; } >"$T/notarget.env"
OUT="$("$INSTALL" --dry-run --env "$T/notarget.env" 2>&1)"; RC=$?
expect "an empty Reality target is refused" 1 "CASAVPN_REALITY_TARGET is empty"
expect "  ...with a pointer to the doc" 1 "docs/REALITY-TARGET.md"
bad_env "a Reality target that is not a hostname is rejected" "CASAVPN_REALITY_TARGET is not a hostname" 'CASAVPN_REALITY_TARGET=bad host'
good_env "$T/port.env" CASAVPN_VPN_PORT=4443
OUT="$("$INSTALL" --dry-run --env "$T/port.env" 2>&1)"; RC=$?
expect "a non-443 VPN port is allowed but warned about" 0 "not 443"
bad_env "a hostname without a dot is rejected" "CASAVPN_DOMAIN is not a hostname" CASAVPN_DOMAIN=localhost
{ printf 'CASAVPN_LAN_CIDR=192.168.0.0/24\n'; } >"$T/nodomain.env"
OUT="$("$INSTALL" --dry-run --env "$T/nodomain.env" 2>&1)"; RC=$?
expect "a missing domain is rejected" 1 "CASAVPN_DOMAIN is not set"
bad_env "a bad CIDR is rejected" "CASAVPN_LAN_CIDR is not a CIDR" CASAVPN_LAN_CIDR=no-mask
bad_env "an octet above 255 is rejected" "CASAVPN_LAN_CIDR is not a CIDR" CASAVPN_LAN_CIDR=192.168.300.0/24
bad_env "a port out of range is rejected" "CASAVPN_WEB_PORT is not a port" CASAVPN_WEB_PORT=70000
bad_env "equal VPN and web ports are rejected" "must differ" CASAVPN_WEB_PORT=443
bad_env "a bad admin user is rejected" "CASAVPN_ADMIN_USER is not a valid user name" 'CASAVPN_ADMIN_USER=Bad User'
bad_env "an unknown DDNS provider is rejected" "is unknown" CASAVPN_DDNS_PROVIDER=nope
bad_env "a token without a zone id is rejected" "CF_ZONE_ID is not" CF_API_TOKEN=tok
bad_env "an age key that is not one is rejected" "AGE_RECIPIENT is not an age public key" AGE_RECIPIENT=nope
good_env "$T/many.env" CASAVPN_WEB_PORT=443 CASAVPN_LAN_CIDR=bogus
OUT="$("$INSTALL" --dry-run --env "$T/many.env" 2>&1)"; RC=$?
expect "all problems are reported at once" 1 "CASAVPN_LAN_CIDR"
expect "  ...including the second one" 1 "must differ"
good_env "$T/inj.env" 'CASAVPN_DOMAIN=vpn.example.com; touch '"$T"'/pwned'
OUT="$("$INSTALL" --dry-run --env "$T/inj.env" 2>&1)"; RC=$?
expect "a command in a value is rejected, not run" 1 "not a hostname"
yes "  ...and was never executed" test ! -e "$T/pwned"
good_env "$T/quoted.env"
printf 'CASAVPN_VPN_PORT="4443"\nCASAVPN_WEB_PORT='"'"'9443'"'"'\n' >>"$T/quoted.env"
OUT="$("$INSTALL" --show nftables --env "$T/quoted.env" 2>/dev/null)"; RC=$?
expect "quotes around values are accepted" 0 "tcp dport 4443 accept"
expect "  ...single quotes too" 0 "tcp dport 9443 accept"
OUT="$(CASAVPN_VPN_PORT=5555 "$INSTALL" --show nftables --env "$T/quoted.env" 2>/dev/null)"; RC=$?
expect "the environment wins over the file" 0 "tcp dport 5555 accept"

echo "install.sh first run"
mkdir -p "$T/bin"
cat >"$T/bin/id" <<'SH'
#!/bin/sh
if [ "$1" = "-u" ]; then echo 0; else /usr/bin/id "$@"; fi
SH
cat >"$T/bin/install" <<'SH'
#!/bin/sh
# Drop -o/-g so the test needs no root and no root group (macOS has wheel).
args=""
while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args="$args '$1'"; shift ;; esac; done
eval "exec /usr/bin/install $args"
SH
chmod +x "$T/bin/install"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/apt-get"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/systemctl"
chmod +x "$T/bin/id" "$T/bin/apt-get" "$T/bin/systemctl"
FRESH="$T/etc/casavpn/casavpn.env"
OUT="$(PATH="$T/bin:$PATH" "$INSTALL" --env "$FRESH" 2>&1)"; RC=$?
expect "no settings file: creates it from the example and stops" 3 "Created $FRESH"
yes "  ...a copy of the example" cmp -s "$FRESH" "$ROOT/casavpn.env.example"
perm="$(stat -c %a "$FRESH" 2>/dev/null || stat -f %Lp "$FRESH")"
yes "  ...mode 0600" test "$perm" = 600
OUT="$(PATH="$T/bin:$PATH" "$INSTALL" --env "$FRESH" --dry-run 2>&1)"; RC=$?
expect "the example alone does not pass: the Reality target must be chosen" 1 "CASAVPN_REALITY_TARGET is empty"
{ echo "CASAVPN_DOMAIN=mine.example.org"; echo "CASAVPN_REALITY_TARGET=www.example.net"; } >>"$FRESH"
OUT="$(PATH="$T/bin:$PATH" "$INSTALL" --env "$FRESH" --dry-run 2>&1)"; RC=$?
expect "an existing settings file is never overwritten" 0 "mine.example.org"
yes "  ...and still holds the edit" grep -q "mine.example.org" "$FRESH"
OUT="$(PATH="$T/bin:$PATH" "$INSTALL" --env "$T/ok.env" --bogus 2>&1)"; RC=$?
expect "an unknown option is a usage error" 2 "unknown option"
OUT="$("$INSTALL" --env "$T/ok.env" 2>&1)"; RC=$?
expect "a real run without root refuses" 1 "run as root"

echo "install.sh generated configs (--show)"
show() { OUT="$("$INSTALL" --show "$1" --env "$2" 2>/dev/null)"; RC=$?; }
show nftables "$T/ok.env"
expect "nftables: own table, no global flush" 0 "table inet casavpn"
lacks  "  ...never flushes the whole ruleset" "^flush ruleset"
expect "  ...SSH only from the LAN" 0 "ip saddr 192.168.0.0/24 tcp dport 22 accept"
expect "  ...default drop" 0 "policy drop"
lacks  "  ...no Tailscale rules by default" "tailscale0"
lacks  "  ...no leftover placeholder" "@[A-Za-z_]*@"
OUT="$("$INSTALL" --show nftables --tailscale --env "$T/ok.env" 2>/dev/null)"; RC=$?
expect "  ...Tailscale rules with --tailscale" 0 'iifname "tailscale0"'
lacks  "  ...uncommented" "#@tailscale@"
show nginx "$T/ok.env"
expect "nginx: serves the configured name" 0 "server_name vpn.example.com;"
expect "  ...reject handshake for unknown names" 0 "ssl_reject_handshake on;"
expect "  ...the panel uses the admin-only snippet" 0 "include /etc/nginx/snippets/casavpn-admin-only.conf;"
expect "  ...the panel is proxied to loopback only" 0 "proxy_pass http://127.0.0.1:2053/"
lacks  "  ...no placeholder left" "@[A-Za-z_]*@"
show nginx-admin "$T/ok.env"
expect "nginx admin snippet: the LAN may pass" 0 "allow 192.168.0.0/24;"
expect "  ...everyone else is denied" 0 "deny all;"
show sshd "$T/ok.env"
expect "sshd: key-only" 0 "PasswordAuthentication no"
expect "  ...no root login" 0 "PermitRootLogin no"
expect "  ...only the admin user" 0 "AllowUsers alice"
show fail2ban "$T/ok.env"
expect "fail2ban: the LAN is never banned" 0 "ignoreip = 127.0.0.1/8 ::1 192.168.0.0/24"
OUT="$("$INSTALL" --show nope --env "$T/ok.env" 2>&1)"; RC=$?
expect "--show with an unknown name is a usage error" 2 "unknown name"

echo "common.sh: load_env and the 3x-ui tarball check"
# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
printf '# comment\nA_ONE=1\n  B_TWO = spaced \nC_THREE="quoted value"\nD_FOUR=\x27single\x27\nbad key=3\n9X=1\nE_FIVE=a=b\n' >"$T/p.env"
unset A_ONE B_TWO C_THREE D_FOUR E_FIVE
load_env "$T/p.env"
yes "plain value" test "${A_ONE:-}" = 1
yes "spaces around = and the value are trimmed" test "${B_TWO:-}" = "spaced"
yes "double quotes stripped" test "${C_THREE:-}" = "quoted value"
yes "single quotes stripped" test "${D_FOUR:-}" = "single"
yes "an = inside the value is kept" test "${E_FIVE:-}" = "a=b"
yes "an invalid variable name is ignored" bash -c '! env | grep -q "^9X="'
printf 'A_ONE=first\nA_ONE=second\n' >"$T/dup.env"
unset A_ONE; load_env "$T/dup.env"
yes "the last line wins inside the file" test "${A_ONE:-}" = second
A_ONE=fromenv; export A_ONE; _ENV_SET=""; load_env "$T/dup.env"
yes "the environment wins over the file" test "${A_ONE:-}" = fromenv

# a fake 3x-ui tarball and a pin file for it
mkdir -p "$T/pkg/x-ui/bin"
printf '#!/bin/sh\necho 9.9.9\n' >"$T/pkg/x-ui/x-ui"; chmod +x "$T/pkg/x-ui/x-ui"
tar -czf "$T/x-ui-test.tar.gz" -C "$T/pkg" x-ui
SUM="$(sha256_of "$T/x-ui-test.tar.gz")"
arch="$(xui_arch 2>/dev/null || echo amd64)"
mkpin() { # <hash-amd64> <hash-arm64>
  printf 'XUI_VERSION=v9.9.9\nXUI_SHA256_AMD64=%s\nXUI_SHA256_ARM64=%s\nXUI_REPO=example/x-ui\n' "$1" "$2" >"$T/pin.env"
}
fetch() { mkdir -p "$T/dl"; rm -f "$T"/dl/*; OUT="$( (fetch_xui "$T/pin.env" "$T/dl" "${1:-0}" "$T/x-ui-test.tar.gz") 2>&1 )"; RC=$?; }
mkpin "$SUM" "$SUM"; fetch
expect "a tarball matching the pin is accepted" 0 "matches the pinned value"
mkpin "0000000000000000000000000000000000000000000000000000000000000000" "0000000000000000000000000000000000000000000000000000000000000000"; fetch
expect "a tarball NOT matching the pin is refused" 1 "does not match the pinned value"
yes "  ...and removed" test -z "$(ls "$T/dl")"
mkpin "" ""; fetch
expect "an empty pin is refused too" 1 "does not match the pinned value"
fetch 1
expect "--trust-release-sha cannot rescue an offline tarball" 1 "cannot be combined with --offline-xui"
mkpin "$SUM" "$SUM"
OUT="$(sha256_of "$T/x-ui-test.tar.gz")"
yes "sha256_of gives 64 hex characters" test "${#OUT}" -eq 64

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
