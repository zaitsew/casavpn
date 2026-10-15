#!/usr/bin/env bash
#
# Tests for scripts/lib/render_links.py, scripts/gen-client-links.sh and
# scripts/lib/set_min_client_ver.py. All secrets are generated at run time.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-clients-test.XXXXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/       /'; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -q -- "$1" <<<"$OUT"; }
lacks() { ! grep -q -- "$1" <<<"$OUT"; }

# --- fixtures -----------------------------------------------------------------
python3 - "$T" <<'PY'
import json, secrets, sqlite3, sys, uuid
t = sys.argv[1]
ids = [str(uuid.uuid4()), str(uuid.uuid4())]
pbk = secrets.token_urlsafe(32)
sid = secrets.token_hex(4)
stream = {
    "network": "tcp", "security": "reality",
    "realitySettings": {
        "dest": "www.example.net:443", "serverNames": ["www.example.net"],
        "privateKey": secrets.token_urlsafe(32), "shortIds": [sid],
        "settings": {"publicKey": pbk, "fingerprint": "chrome", "spiderX": "/"},
    },
}
settings = {"clients": [
    {"id": ids[0], "email": "alice", "flow": "xtls-rprx-vision"},
    {"id": ids[1], "email": "bob", "flow": "xtls-rprx-vision"},
]}
rows = [{"port": 443, "settings": json.dumps(settings), "stream_settings": json.dumps(stream)}]
json.dump(rows, open(f"{t}/rows.json", "w"))
json.dump({"ids": ids, "pbk": pbk, "sid": sid}, open(f"{t}/secrets.json", "w"))

db = sqlite3.connect(f"{t}/x-ui.db")
db.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT, port INTEGER, protocol TEXT, enable INTEGER, settings TEXT, stream_settings TEXT)")
db.execute("INSERT INTO inbounds VALUES (1, 'main', 443, 'vless', 1, ?, ?)", (json.dumps(settings), json.dumps(stream)))
plain = dict(stream, security="none")
db.execute("INSERT INTO inbounds VALUES (2, 'other', 8080, 'vless', 1, '{}', ?)", (json.dumps(plain),))
db.execute("INSERT INTO inbounds VALUES (3, 'trojan', 9000, 'trojan', 1, '{}', '{}')")
db.commit(); db.close()
PY
ID0="$(python3 -c "import json,sys; print(json.load(open('$T/secrets.json'))['ids'][0])")"
PBK="$(python3 -c "import json,sys; print(json.load(open('$T/secrets.json'))['pbk'])")"

echo "render_links.py"
RENDER="$ROOT/scripts/lib/render_links.py"
OUT="$(python3 "$RENDER" vpn.example.com "$T/links.txt" <"$T/rows.json" 2>&1)"; RC=$?
check "renders and exits 0" test "$RC" -eq 0
OUT="$(cat "$T/links.txt")"
check "one link per client" test "$(grep -c '^vless://' "$T/links.txt")" -eq 2
check "link carries the address and port" has "@vpn.example.com:443?"
check "link carries the client id, key and flow" bash -c "grep -q '$ID0' '$T/links.txt' && grep -q 'pbk=$PBK' '$T/links.txt' && grep -q 'flow=xtls-rprx-vision' '$T/links.txt'"
check "default tag prefix is CasaVPN-" has "#CasaVPN-alice"
check "the file is owner-only" test "$(stat -c %a "$T/links.txt" 2>/dev/null || stat -f %Lp "$T/links.txt")" = 600
OUT="$(python3 "$RENDER" vpn.example.com "$T/links2.txt" MyNet <"$T/rows.json" 2>&1)"
check "custom tag prefix" has "#MyNet-bob"
OUT="$(python3 "$RENDER" 2001:db8::1 "$T/links3.txt" <"$T/rows.json" 2>&1)"
check "an IPv6 address is bracketed" has "@\[2001:db8::1\]:443"
OUT="$(printf '[]' | python3 "$RENDER" vpn.example.com "$T/none.txt" 2>&1)"; RC=$?
check "no inbounds is an error" test "$RC" -ne 0
OUT="$(printf 'not json' | python3 "$RENDER" vpn.example.com "$T/none.txt" 2>&1)"; RC=$?
check "bad input is an error, not a traceback" bash -c "! grep -q Traceback <<<'$OUT'"

echo "gen-client-links.sh"
mkdir -p "$T/bin"
cat >"$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
# Fake ssh: record the target, answer with the canned sqlite output.
printf '%s\n' "$*" >"$FAKE_SSH_LOG"
cat "$FAKE_ROWS"
FAKE
chmod +x "$T/bin/ssh"
export FAKE_SSH_LOG="$T/ssh.log" FAKE_ROWS="$T/rows.json"
GEN="$ROOT/scripts/gen-client-links.sh"
OUT="$(cd "$T" && PATH="$T/bin:$PATH" CASAVPN_ENV=/nonexistent "$GEN" --ssh admin@192.0.2.10 --out "$T/gen.txt" vpn.example.com 2>&1)"; RC=$?
check "--ssh renders links" test "$RC" -eq 0
check "  ...for the given target" grep -q 'admin@192.0.2.10' "$T/ssh.log"
check "  ...and writes the output file" test "$(grep -c '^vless://' "$T/gen.txt")" -eq 2
printf 'CASAVPN_DOMAIN=vpn.example.org\nCASAVPN_SSH_TARGET=admin@192.0.2.11\n' >"$T/test.env"
OUT="$(cd "$T" && PATH="$T/bin:$PATH" CASAVPN_ENV="$T/test.env" "$GEN" --out "$T/gen2.txt" 2>&1)"; RC=$?
check "address and target default from the env file" bash -c "[ $RC -eq 0 ] && grep -q 'admin@192.0.2.11' '$T/ssh.log' && grep -q '@vpn.example.org:443' '$T/gen2.txt'"
OUT="$(cd "$T" && PATH="$T/bin:$PATH" CASAVPN_ENV=/nonexistent "$GEN" --ssh admin@192.0.2.10 2>&1)"; RC=$?
check "no address anywhere is a usage error" test "$RC" -eq 2
OUT="$("$GEN" --bogus 2>&1)"; RC=$?
check "unknown option is a usage error" test "$RC" -eq 2

echo "set_min_client_ver.py"
SETV="$ROOT/scripts/lib/set_min_client_ver.py"
reality_ver() { python3 - "$T/x-ui.db" "$1" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (int(sys.argv[2]),)).fetchone()
print(json.loads(row[0]).get("realitySettings", {}).get("minClientVer", "unset"))
PY
}
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.8.0 --check 2>&1)"; RC=$?
check "--check fails while unset" test "$RC" -eq 1
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.8.0 --dry-run 2>&1)"; RC=$?
check "--dry-run changes nothing" test "$(reality_ver 1)" = unset
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.8.0 2>&1)"; RC=$?
check "sets minClientVer on the Reality inbound" test "$RC" -eq 0 -a "$(reality_ver 1)" = 1.8.0
check "  ...and says to restart x-ui" has "restart x-ui"
check "  ...and leaves the non-Reality inbound alone" bash -c "python3 - '$T/x-ui.db' <<'PY'
import json, sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute('SELECT stream_settings FROM inbounds WHERE id = 2').fetchone()
sys.exit(0 if 'minClientVer' not in json.loads(row[0]).get('realitySettings', {}) else 1)
PY"
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.8.0 2>&1)"; RC=$?
check "idempotent: second run reports already set" test "$RC" -eq 0 -a "$(printf '%s' "$OUT" | grep -c already)" -eq 1
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.8.0 --check 2>&1)"; RC=$?
check "--check passes once set" test "$RC" -eq 0
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.9.0 --port 443 2>&1)"; RC=$?
check "--port selects the inbound and updates it" test "$RC" -eq 0 -a "$(reality_ver 1)" = 1.9.0
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version 1.8.0 --port 9999 2>&1)"; RC=$?
check "unknown port is an error" test "$RC" -eq 2
OUT="$(python3 "$SETV" --db "$T/x-ui.db" --version banana 2>&1)"; RC=$?
check "a non-version is rejected" test "$RC" -eq 2
OUT="$(python3 "$SETV" --db "$T/nope/x-ui.db" --version 1.8.0 2>&1)"; RC=$?
check "a missing database is an error, not a traceback" bash -c "[ $RC -eq 2 ] && ! grep -q Traceback <<<'$OUT'"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
