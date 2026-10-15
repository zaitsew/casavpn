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
# Drop -o/-g so the test needs no root and no root group (macOS has wheel), and
# emulate GNU -D (create the leading directories) for BSD install.
args=""; mkd=0; last=""
while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; -D) mkd=1; shift ;; *) args="$args '$1'"; last="$1"; shift ;; esac; done
[ "$mkd" = 0 ] || mkdir -p "$(dirname "$last")"
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
lacks  "  ...no placeholder left" "@[A-Za-z_]*@"

echo "install.sh hairpin-NAT guard and LAN gateway"
NETBIN="$T/netbin"; mkdir -p "$NETBIN"
cat >"$NETBIN/ip" <<'SH'
#!/bin/sh
# ip -4 route show default
[ -n "${FAKE_DEFAULT_ROUTE:-}" ] && echo "$FAKE_DEFAULT_ROUTE"
exit 0
SH
chmod +x "$NETBIN/ip"
rules_of() { grep -E '^(allow|deny)' <<<"$OUT" | tr '\n' ' '; }
show_nets() { OUT="$(PATH="$NETBIN:$PATH" "$INSTALL" --show "$1" --env "$2" 2>/dev/null)"; RC=$?; }
good_env "$T/lan.env" CASAVPN_LAN_CIDR=198.51.100.0/24
FAKE_DEFAULT_ROUTE="default via 198.51.100.1 dev eth0 proto dhcp src 198.51.100.50 metric 100"; export FAKE_DEFAULT_ROUTE
show_nets nginx-admin "$T/lan.env"
expect "the default route's gateway is detected and denied" 0 "^deny 198.51.100.1;"
yes "  ...before the LAN is allowed" test "$(rules_of)" = "allow 127.0.0.1; deny 198.51.100.1; allow 198.51.100.0/24; allow 100.64.0.0/10; deny all; "
good_env "$T/gw.env" CASAVPN_LAN_CIDR=198.51.100.0/24 CASAVPN_LAN_GATEWAY=198.51.100.254
show_nets nginx-admin "$T/gw.env"
expect "an explicit CASAVPN_LAN_GATEWAY wins over detection" 0 "^deny 198.51.100.254;"
lacks  "  ...and the detected one is not also used" "deny 198.51.100.1;"
FAKE_DEFAULT_ROUTE="default via 203.0.113.1 dev wlan0"; export FAKE_DEFAULT_ROUTE
show_nets nginx-admin "$T/lan.env"
expect "a default route outside the LAN CIDR is not trusted as the gateway" 0 "hairpin-NAT guard is OFF"
lacks  "  ...no deny rule for it" "^deny 203.0.113.1"
unset FAKE_DEFAULT_ROUTE
show_nets nginx-admin "$T/lan.env"
expect "no detectable gateway: the rule is a loud comment, not silence" 0 "set CASAVPN_LAN_GATEWAY"
yes "  ...allow/deny order is intact" test "$(rules_of)" = "allow 127.0.0.1; allow 198.51.100.0/24; allow 100.64.0.0/10; deny all; "
OUT="$(PATH="$NETBIN:$PATH" "$INSTALL" --dry-run --env "$T/lan.env" 2>&1)"; RC=$?
expect "the installer tells the user what is left when it cannot detect it" 0 "Set CASAVPN_LAN_GATEWAY to your router"
good_env "$T/gwnone.env" CASAVPN_LAN_CIDR=198.51.100.0/24 CASAVPN_LAN_GATEWAY=none
FAKE_DEFAULT_ROUTE="default via 198.51.100.1 dev eth0"; export FAKE_DEFAULT_ROUTE
show_nets nginx-admin "$T/gwnone.env"
lacks  "CASAVPN_LAN_GATEWAY=none adds no deny rule" "^deny 198"
unset FAKE_DEFAULT_ROUTE
bad_env "a gateway that is not an IPv4 address is rejected" "CASAVPN_LAN_GATEWAY is not an IPv4 address" CASAVPN_LAN_GATEWAY=router.local
bad_env "a gateway octet above 255 is rejected" "CASAVPN_LAN_GATEWAY is not an IPv4 address" CASAVPN_LAN_GATEWAY=198.51.100.300
yes "the Xray panel-route example is valid JSON" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/config/xray/panel-route.example.json"
OUT="$(python3 - "$ROOT/config/xray/panel-route.example.json" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))["rules"]
print("owner-first" if rules[0].get("user") and rules[0]["outboundTag"] == "panel" else "owner-not-first")
others = [r for r in rules[1:] if r["outboundTag"] == "blocked" and not r.get("user") and r.get("port")]
print("guards=%d" % len(others))
print("all-guards-after-owner" if all(rules.index(r) > 0 for r in others) else "bad-order")
print("hostname" if any("full:vpn.example.com" in r.get("domain", []) for r in others) else "no-hostname-guard")
print("ip" if any(r.get("ip") for r in others) else "no-ip-guard")
PY
)"; RC=$?
expect "panel-route example: the owner's rule comes first" 0 "owner-first"
expect "  ...then a blackhole guard for the hostname on the web port" 0 "hostname"
expect "  ...and one for the public IP" 0 "^ip"
expect "  ...guards never name a user, so they bite every other client" 0 "guards=2"

echo "install.sh nginx HTTP/2 form"
OLDBIN="$T/oldnginx"; mkdir -p "$OLDBIN"
printf '#!/bin/sh\necho "nginx version: nginx/${FAKE_NGINX_VERSION:-1.22.1}" >&2\n' >"$OLDBIN/nginx"; chmod +x "$OLDBIN/nginx"
show_ng() { OUT="$(PATH="$OLDBIN:$PATH" FAKE_NGINX_VERSION="$1" "$INSTALL" --show nginx --env "$T/ok.env" 2>/dev/null)"; RC=$?; }
show_ng 1.22.1
expect "nginx 1.22 (Debian 12): http2 goes on the listen line" 0 "listen 8443 ssl http2;"
expect "  ...also for IPv6" 0 "listen \[::\]:8443 ssl http2;"
lacks  "  ...and there is no 'http2 on;' directive that 1.22 rejects" "^ *http2 on;"
show_ng 1.25.0
expect "nginx 1.25.0 still takes the listen form" 0 "listen 8443 ssl http2;"
show_ng 1.25.1
expect "nginx 1.25.1 takes 'http2 on;'" 0 "^ *http2 on;"
lacks  "  ...and no http2 on the listen line" "ssl http2;"
show_ng 1.26.3
expect "nginx 1.26 takes 'http2 on;'" 0 "^ *http2 on;"
show_ng 1.9.15
expect "an old 1.9 is the listen form" 0 "ssl http2;"
show nginx "$T/ok.env"
lacks  "  ...no placeholder left (whatever nginx is installed)" "@[A-Za-z_]*@"
show sshd "$T/ok.env"
expect "sshd: key-only" 0 "PasswordAuthentication no"
expect "  ...no root login" 0 "PermitRootLogin no"
expect "  ...only the admin user" 0 "AllowUsers alice"
show fail2ban "$T/ok.env"
expect "fail2ban: only loopback is exempt by default" 0 "^ignoreip = 127.0.0.1/8 ::1$"
lacks  "  ...the LAN can be banned" "192.168.0.0/24"
good_env "$T/f2b.env" 'CASAVPN_FAIL2BAN_IGNOREIP=198.51.100.77, 198.51.100.78/32'
show fail2ban "$T/f2b.env"
expect "CASAVPN_FAIL2BAN_IGNOREIP adds exactly what was asked" 0 "^ignoreip = 127.0.0.1/8 ::1 198.51.100.77 198.51.100.78/32$"
bad_env "an ignoreip list with junk is rejected" "CASAVPN_FAIL2BAN_IGNOREIP is not a list" 'CASAVPN_FAIL2BAN_IGNOREIP=198.51.100.77; rm -rf /'
OUT="$("$INSTALL" --show nope --env "$T/ok.env" 2>&1)"; RC=$?
expect "--show with an unknown name is a usage error" 2 "unknown name"

echo "install.sh real runs against a scratch root (fake tools, no host changes)"
printf '#!/bin/sh\necho "certbot $*" >>"$FAKE_CERTBOT_LOG"\nexit 0\n' >"$T/bin/certbot"; chmod +x "$T/bin/certbot"
export FAKE_CERTBOT_LOG="$T/certbot.log"
# The token is rotated: the credentials file certbot renews with must follow it.
R="$T/root1"; mkdir -p "$R/etc" "$R/le"
good_env "$T/cf-a.env" CF_API_TOKEN=tokOLDvalue CF_ZONE_ID=zone CASAVPN_ACME_AGREE_TOS=1
real_certs() { # <env file>
  OUT="$(PATH="$T/bin:$PATH" CASAVPN_ETC="$R/etc" CASAVPN_LE_DIR="$R/le" "$INSTALL" --env "$1" --yes \
    --skip-packages --skip-files --skip-3xui --skip-nginx --skip-ssh --skip-firewall --skip-fail2ban --skip-timers --skip-updates 2>&1)"; RC=$?
}
: >"$FAKE_CERTBOT_LOG"
real_certs "$T/cf-a.env"
expect "first run with a token: certificate requested" 0 "certificate issued"
yes "  ...certbot was run once" test "$(grep -c '^certbot certonly' "$FAKE_CERTBOT_LOG")" = 1
yes "  ...cloudflare.ini holds the token" grep -qx 'dns_cloudflare_api_token = tokOLDvalue' "$R/etc/casavpn/cloudflare.ini"
perm="$(stat -c %a "$R/etc/casavpn/cloudflare.ini" 2>/dev/null || stat -f %Lp "$R/etc/casavpn/cloudflare.ini")"
yes "  ...mode 0600" test "$perm" = 600
lacks  "  ...the token is never printed" "tokOLDvalue"
mkdir -p "$R/le/live/vpn.example.com"; : >"$R/le/live/vpn.example.com/fullchain.pem"
good_env "$T/cf-b.env" CF_API_TOKEN=tokNEWvalue CF_ZONE_ID=zone CASAVPN_ACME_AGREE_TOS=1
: >"$FAKE_CERTBOT_LOG"
real_certs "$T/cf-b.env"
expect "a rotated token with a certificate already issued" 0 "already exists"
yes "  ...cloudflare.ini now holds the NEW token" grep -qx 'dns_cloudflare_api_token = tokNEWvalue' "$R/etc/casavpn/cloudflare.ini"
yes "  ...and not the old one" bash -c "! grep -q tokOLDvalue '$R/etc/casavpn/cloudflare.ini'"
yes "  ...certbot was not asked for another certificate" test ! -s "$FAKE_CERTBOT_LOG"
perm="$(stat -c %a "$R/etc/casavpn/cloudflare.ini" 2>/dev/null || stat -f %Lp "$R/etc/casavpn/cloudflare.ini")"
yes "  ...mode still 0600" test "$perm" = 600
chmod 0644 "$R/etc/casavpn/cloudflare.ini"
real_certs "$T/cf-b.env"
expect "same token again" 0 "already holds the current token"
perm="$(stat -c %a "$R/etc/casavpn/cloudflare.ini" 2>/dev/null || stat -f %Lp "$R/etc/casavpn/cloudflare.ini")"
yes "  ...a loosened mode is tightened back to 0600" test "$perm" = 600
good_env "$T/cf-c.env" CF_API_TOKEN=tokNEWvalue CF_ZONE_ID=zone
real_certs "$T/cf-c.env"
expect "the token is also refreshed when the licence is not accepted (a cert may exist)" 0 "Subscriber Agreement"

# A panel database that already exists is the truth: take its user name and base
# path, never invent a password for it, never print one that cannot work.
mkxdb() { # <file> <webBasePath> <username>
  rm -f "$1"
  sqlite3 "$1" "create table settings (id integer primary key, key text, value text); create table users (id integer primary key, username text, password text);
    insert into settings (key, value) values ('webBasePath', '$2'), ('webPort', '2053');
    insert into users (username, password) values ('$3', '\$2a\$10\$hashhashhash');"
}
mkxdb "$T/pre.db" '/oldsecretpath/' bobadmin
mkdir -p "$T/xuidir"; printf '#!/bin/sh\nexit 0\n' >"$T/xuidir/x-ui"; chmod +x "$T/xuidir/x-ui"
OUT="$(CASAVPN_DB="$T/pre.db" CASAVPN_PANEL_CREDS="$T/none/creds.env" CASAVPN_XUI_DIR="$T/xuidir" "$INSTALL" --dry-run --env "$T/ok.env" 2>&1)"; RC=$?
expect "dry run with a preserved database and no credentials file" 0 "would read the user name and base path from the database"
expect "  ...says the password cannot be recovered" 0 "password cannot be recovered"
expect "  ...prints how to reset it" 0 "x-ui setting -username <user> -password"
lacks  "  ...does not point at a credentials file for the password" "sudo cat"
lacks  "  ...never prints a password line" "PANEL_PASSWORD="
OUT="$(CASAVPN_DB="$T/pre.db" CASAVPN_PANEL_CREDS="$T/none/creds.env" "$INSTALL" --show nginx --env "$T/ok.env" 2>/dev/null)"; RC=$?
expect "nginx is rendered for the database's base path, not an invented one" 0 "location /oldsecretpath/ {"
expect "  ...proxying to it" 0 "proxy_pass http://127.0.0.1:2053/oldsecretpath/;"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "$PORT" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
time.sleep(60)
PY
LISTENER=$!
good_env "$T/adopt.env" "CASAVPN_PANEL_PORT=$PORT"
real_3xui() { # <db> <creds>
  OUT="$(PATH="$T/bin:$PATH" CASAVPN_ETC="$R/etc" CASAVPN_DB="$1" CASAVPN_PANEL_CREDS="$2" CASAVPN_XUI_DIR="$T/xuidir" \
    "$INSTALL" --env "$T/adopt.env" --yes --skip-packages --skip-files --skip-certs --skip-nginx --skip-ssh --skip-firewall --skip-fail2ban --skip-timers --skip-updates 2>&1)"; RC=$?
}
real_3xui "$T/pre.db" "$T/adopt1/creds.env"
expect "real run: a preserved database is adopted" 0 "the password is NOT known"
yes "  ...credentials file has the database's user name" grep -qx 'PANEL_USER=bobadmin' "$T/adopt1/creds.env"
yes "  ...and its base path" grep -qx 'PANEL_BASE_PATH=oldsecretpath' "$T/adopt1/creds.env"
yes "  ...and no invented password" bash -c "! grep -q '^PANEL_PASSWORD' '$T/adopt1/creds.env'"
perm="$(stat -c %a "$T/adopt1/creds.env" 2>/dev/null || stat -f %Lp "$T/adopt1/creds.env")"
yes "  ...mode 0600" test "$perm" = 600
yes "  ...the database's base path is untouched" test "$(sqlite3 "$T/pre.db" "select value from settings where key='webBasePath';")" = "/oldsecretpath/"
expect "  ...the end of the run explains the reset" 0 "reset it and restart the panel"
lacks  "  ...never says to read a password from the file" "username and password are in"
mkxdb "$T/root.db" '/' stockadmin
real_3xui "$T/root.db" "$T/adopt2/creds.env"
expect "real run: a stock database served at / gets a generated secret path" 0 "generated one"
newpath="$(sed -n 's/^PANEL_BASE_PATH=//p' "$T/adopt2/creds.env")"
yes "  ...16 hex characters in the credentials file" bash -c "[[ '$newpath' =~ ^[0-9a-f]{16}\$ ]]"
yes "  ...and the same path set in the database" test "$(sqlite3 "$T/root.db" "select value from settings where key='webBasePath';")" = "/$newpath/"
yes "  ...the user name kept" grep -qx 'PANEL_USER=stockadmin' "$T/adopt2/creds.env"
kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null

echo "install.sh printed panel URL"
OUT="$("$INSTALL" --dry-run --env "$T/ok.env" 2>&1)"; RC=$?
expect "the guide opens the panel by hostname" 0 "https://vpn.example.com:8443/<base path>/"
lacks  "  ...not by a bare LAN IP URL that fails the TLS handshake" "https://<LAN_IP>"
expect "  ...with a hosts entry or split DNS" 0 "<LAN_IP> vpn.example.com"
expect "  ...and says a public-address request is refused on purpose" 0 "refused on purpose"

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
