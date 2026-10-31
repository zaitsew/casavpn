#!/usr/bin/env bash
#
# Offline tests for scripts/casavpn-pair.
#
# The inputs are fixtures: a casavpn.env, a throwaway SQLite database shaped like
# 3x-ui's (settings, api_tokens), and PATH-free stubs: a fake x-ui binary in
# CASAVPN_XUI_DIR and a fake qrencode first on PATH. No network, no panel.

# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/casavpn-pair"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-pair-test.XXXXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 missing, skipping pair tests"; exit 0; }

pass=0; fail=0
OUT=""; ERR=""; RC=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n%s\n' "$OUT" "$ERR" | tail -n 12 | sed 's/^/       /'; }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$RC, want $2)"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
out_has() { if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 (stdout lacks: $2)"; fi; }
out_lacks() { if grep -qF -- "$2" <<<"$OUT"; then bad "$1 (stdout has: $2)"; else ok "$1"; fi; }
err_has() { if grep -qF -- "$2" <<<"$ERR"; then ok "$1"; else bad "$1 (stderr lacks: $2)"; fi; }
err_lacks() { if grep -qF -- "$2" <<<"$ERR"; then bad "$1 (stderr has: $2)"; else ok "$1"; fi; }

# --- fixtures ---------------------------------------------------------------------
FAKE="$T/fake"; mkdir -p "$FAKE/xui" "$FAKE/bin"
export FAKE
TOKEN="tok_fake_fake_fake_fake"

cat >"$FAKE/xui/x-ui" <<'XUI'
#!/usr/bin/env bash
# Fake 3x-ui binary: logs its arguments, prints what 3x-ui 3.10.2 prints.
echo "$*" >>"$FAKE/xui.log"
[ -f "$FAKE/xui_fail" ] && { echo "Error: database is locked"; exit 1; }
[ -f "$FAKE/xui_garbage" ] && { echo "nothing useful here"; exit 0; }
printf 'Token name: casavpn-app\nscope: admin\napiToken: %s\n' "$(cat "$FAKE/token")"
XUI
chmod +x "$FAKE/xui/x-ui"
printf '%s' "$TOKEN" >"$FAKE/token"

cat >"$FAKE/bin/qrencode" <<'QR'
#!/usr/bin/env bash
echo "$*" >"$FAKE/qr.args"
cat >"$FAKE/qr.stdin"
echo "[QR CODE]"
QR
chmod +x "$FAKE/bin/qrencode"

REAL_PY="$(command -v python3)"
printf '#!/usr/bin/env bash\necho "python3 $*" >>"$FAKE/argv.log"\nexec "%s" "$@"\n' "$REAL_PY" >"$FAKE/bin/python3"
chmod +x "$FAKE/bin/python3"

cat >"$T/mkdb.py" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
d.execute("CREATE TABLE api_tokens (id INTEGER PRIMARY KEY, name TEXT UNIQUE, token TEXT, scope TEXT)")
if sys.argv[2]:
    d.execute("INSERT INTO settings (key, value) VALUES ('webBasePath', ?)", (sys.argv[2],))
if len(sys.argv) > 3 and sys.argv[3] == "token":
    d.execute("INSERT INTO api_tokens (name, token, scope) VALUES ('casavpn-app', 'hash', 'admin')")
d.commit()
PY
mkdb() { rm -f "$1"; python3 "$T/mkdb.py" "$@"; }

DB="$T/x-ui.db"
mkdb "$DB" "/abc123secret/"
cat >"$T/casavpn.env" <<'ENV'
CASAVPN_DOMAIN=vpn.example.com
CASAVPN_WEB_PORT=8443
CASAVPN_RELAY_URL=https://casavpn-monitor.example.workers.dev/
CASAVPN_RELAY_TOKEN=hosttoken_fakefake
ENV
: >"$T/empty.env"
CREDS="$T/panel-credentials.env"
printf 'PANEL_BASE_PATH=/fromfile/\n' >"$CREDS"

# run [env assignments...] -- [args...]
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "$FAKE/xui.log" "$FAKE/qr.args" "$FAKE/qr.stdin" "$FAKE/argv.log"
  OUT="$(env -i PATH="$FAKE/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" HOME="$T" \
      CASAVPN_PAIR_ALLOW_NONROOT=1 CASAVPN_ENV_FILE="$T/casavpn.env" CASAVPN_DB="$DB" \
      CASAVPN_PANEL_CREDS="$CREDS" CASAVPN_XUI_DIR="$FAKE/xui" FAKE="$FAKE" \
      CASAVPN_RELAY_APP_TOKEN="apptoken_FAKE-FAKE" \
      ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" 2>"$T/err" </dev/null)"
  RC=$?
  ERR="$(cat "$T/err")"
}
xui_calls() { [ -f "$FAKE/xui.log" ] && wc -l <"$FAKE/xui.log" | tr -d ' ' || echo 0; }
param() { python3 -c 'import sys, urllib.parse as u; q = u.urlparse(sys.argv[1]).query; print(u.parse_qs(q, keep_blank_values=True)[sys.argv[2]][0])' "$OUT" "$1"; }

# --- the happy path -----------------------------------------------------------------
echo "pairing link"
run -- --yes
rc_is "exits 0" 0 0
out_has "the link starts with the app scheme" "casavpn://pair?panel="
eq "panel = domain, web port and the base path from the database" "$(param panel)" "https://vpn.example.com:8443/abc123secret"
eq "panelToken is the token x-ui printed" "$(param panelToken)" "$TOKEN"
eq "relay has no trailing slash" "$(param relay)" "https://casavpn-monitor.example.workers.dev"
eq "relayToken is the APP token" "$(param relayToken)" "apptoken_FAKE-FAKE"
eq "sub is the /sub/ URL on the web port" "$(param sub)" "https://vpn.example.com:8443/sub/"
eq "the link is one line on stdout" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
out_lacks "the host token never reaches the link" "hosttoken_fakefake"
err_has "warns that the code holds secrets" "contains secrets"
err_has "the QR is drawn on stderr" "[QR CODE]"
eq "qrencode draws the terminal QR" "$(cat "$FAKE/qr.args" | cut -d' ' -f1-2)" "-t ANSIUTF8"
err_lacks "stderr does not repeat the link" "casavpn://pair"
eq "the QR is made from the link on stdin" "$(cat "$FAKE/qr.stdin")" "$OUT"
eq "qrencode gets only options, no string (the link would show in ps)" "$(cat "$FAKE/qr.args")" "-t ANSIUTF8 -m 2"
# Every process the script starts has its argv recorded (python3 by a wrapper, qrencode and
# x-ui by their stubs); no secret may be in any of them.
no_secret_in_argv() { # <label> <secret>...
  local label="$1" sec bad_one=""
  shift
  for sec in "$@"; do
    if grep -qF -- "$sec" "$FAKE/argv.log" "$FAKE/qr.args" "$FAKE/xui.log" 2>/dev/null; then bad_one="$sec"; fi
  done
  if [ -z "$bad_one" ]; then ok "$label"; else bad "$label (found in a command line)"; fi
}
no_secret_in_argv "no token is in any command line (panel token, app token, link)" "$TOKEN" "apptoken_FAKE-FAKE" "casavpn://pair" "abc123secret"
eq "x-ui is called once with the flags before the positional argument" "$(cat "$FAKE/xui.log")" "setting -getApiToken -tokenName casavpn-app -tokenScope admin"

echo "--no-qr and a missing qrencode"
run -- --yes --no-qr
rc_is "--no-qr exits 0" 0 0
err_lacks "--no-qr draws nothing" "[QR CODE]"
out_has "--no-qr still prints the link" "casavpn://pair?"
rm -f "$FAKE/bin/qrencode"
run -- --yes
rc_is "without qrencode it still succeeds" 0 0
err_has "without qrencode it says how to install it" "apt-get install qrencode"
out_has "without qrencode the link is printed" "casavpn://pair?"
printf '#!/usr/bin/env bash\necho "$*" >"$FAKE/qr.args"\ncat >"$FAKE/qr.stdin"\necho "[QR CODE]"\n' >"$FAKE/bin/qrencode"; chmod +x "$FAKE/bin/qrencode"

# --- encoding ----------------------------------------------------------------------
echo "encoding"
run "CASAVPN_RELAY_APP_TOKEN=a b&c=d%e/f+g#h?i" "CASAVPN_PANEL_TOKEN=pt&x=1 2" -- 
rc_is "exotic characters do not break it" 0 0
no_secret_in_argv "  ...and none of them is in a command line" "c=d%e" "pt&x"
eq "relayToken round-trips (spaces are stripped, the rest encoded)" "$(param relayToken)" "ab&c=d%e/f+g#h?i"
eq "panelToken round-trips (spaces stripped)" "$(param panelToken)" "pt&x=12"
out_lacks "a raw ampersand from a token cannot start a new parameter" "&x=1"
out_lacks "no raw hash in the link" "#"
eq "an env token means x-ui is not touched" "$(xui_calls)" "0"
run -- --yes
eq "the panel URL colons and slashes are encoded" "$(printf '%s' "$OUT" | sed 's/.*panel=\([^&]*\)&.*/\1/')" "https%3A%2F%2Fvpn.example.com%3A8443%2Fabc123secret"

# --- the base path --------------------------------------------------------------------
echo "panel base path"
mkdb "$DB" ""
run -- --yes
rc_is "falls back to panel-credentials.env" 0 0
eq "...and uses its base path" "$(param panel)" "https://vpn.example.com:8443/fromfile"
rm -f "$CREDS"
run -- --yes
rc_is "no base path anywhere fails" 1 0
err_has "...and says where it looked" "cannot find the panel's base path"
eq "...before touching the token" "$(xui_calls)" "0"
printf 'PANEL_BASE_PATH=/fromfile/\n' >"$CREDS"
mkdb "$DB" "/bad path/"
run -- --yes
rc_is "an unsafe base path is refused" 1 0
mkdb "$DB" "/abc123secret/"

# --- the token ---------------------------------------------------------------------
echo "token rotation"
mkdb "$DB" "/abc123secret/" token
run --
rc_is "an existing token without --yes stops (no tty)" 1 0
err_has "...and names the consequence" "stop working"
err_has "...and the way forward" "--yes"
eq "...without calling x-ui" "$(xui_calls)" "0"
out_lacks "...and without printing a link" "casavpn://"
run -- --yes
rc_is "--yes replaces it" 0 0
eq "...calling x-ui once" "$(xui_calls)" "1"
run CASAVPN_PANEL_TOKEN=mine_fakefakefakefake --
rc_is "a token from the environment skips the prompt" 0 0
eq "...and is used as is" "$(param panelToken)" "mine_fakefakefakefake"
mkdb "$DB" "/abc123secret/"
run -- 
rc_is "no earlier token: no confirmation needed" 0 0
eq "...x-ui is called" "$(xui_calls)" "1"
touch "$FAKE/xui_fail"
run -- --yes
rc_is "x-ui failing is reported" 1 0
err_has "...with its message" "database is locked"
out_lacks "...and no link" "casavpn://"
rm -f "$FAKE/xui_fail"; touch "$FAKE/xui_garbage"
run -- --yes
rc_is "output without a token is refused" 1 0
err_has "...and the output is quoted" "nothing useful here"
rm -f "$FAKE/xui_garbage"
run CASAVPN_XUI_DIR="$T/none" --
rc_is "a missing x-ui binary fails" 1 0
err_has "...and points at the panel's API tokens page" "Settings > API tokens"

# --- the relay and the other inputs ------------------------------------------------------
echo "inputs"
run CASAVPN_ENV_FILE="$T/empty.env" --
rc_is "no domain fails" 1 0
err_has "...and names CASAVPN_DOMAIN" "CASAVPN_DOMAIN"
eq "...before touching the token" "$(xui_calls)" "0"
sed '/RELAY_URL/d' "$T/casavpn.env" >"$T/norelay.env"
run CASAVPN_ENV_FILE="$T/norelay.env" -- --yes
rc_is "no relay URL fails" 1 0
err_has "...and names it" "CASAVPN_RELAY_URL"
sed 's#https://#http://#' "$T/casavpn.env" >"$T/http.env"
run CASAVPN_ENV_FILE="$T/http.env" -- --yes
rc_is "a plain http relay is refused" 1 0
sed 's/WEB_PORT=8443/WEB_PORT=9443/' "$T/casavpn.env" >"$T/port.env"
run CASAVPN_ENV_FILE="$T/port.env" -- --yes
eq "the web port follows casavpn.env" "$(param sub)" "https://vpn.example.com:9443/sub/"
sed '/WEB_PORT/d' "$T/casavpn.env" >"$T/noport.env"
run CASAVPN_ENV_FILE="$T/noport.env" -- --yes
eq "the web port defaults to 8443" "$(param sub)" "https://vpn.example.com:8443/sub/"
run CASAVPN_RELAY_APP_TOKEN=hosttoken_fakefake -- --yes
rc_is "the host token (read from casavpn.env) is refused as the app token" 1 0
err_has "...with the reason" "HOST token"
eq "...before touching the token" "$(xui_calls)" "0"
run CASAVPN_RELAY_APP_TOKEN= -- --yes
rc_is "no app token and no terminal fails" 1 0
err_has "...and names the variable" "CASAVPN_RELAY_APP_TOKEN"
eq "...before touching the token" "$(xui_calls)" "0"

# --- usage -----------------------------------------------------------------------------
echo "usage"
run -- --bogus
rc_is "an unknown argument exits 2" 2 0
run -- --help
rc_is "--help exits 0" 0 0
err_has "--help prints the header" "casavpn-pair"
rm -f "$T/rootcheck"
OUT="$(env -i PATH="/usr/bin:/bin" HOME="$T" CASAVPN_ENV_FILE="$T/casavpn.env" bash "$SCRIPT" --yes 2>&1 </dev/null)"; RC=$?
if [ "$(id -u)" -ne 0 ]; then
  rc_is "a non-root user is refused" 1 0
  out_has "...with the sudo hint" "sudo casavpn-pair"
fi

echo
echo "pair tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
