#!/usr/bin/env python3
"""host_probe: the read-only lookups casavpn-alerts and casavpn-pair need.

Run as `python3 -I host_probe.py <command> ...`. Output is plain text for the
shell to split; nothing here writes to the panel database (it is opened with
SQLite's read-only mode and `query_only`).

  clients <db>              one tab-separated row per client_traffics entry:
                            email enable up down total expiry_ms expiry_date
                            (expiry_date is the UTC day, or "-" without expiry)
  inbound <db> <port>       the number of enabled inbounds listening on <port>
  setting <db> <key>        one value from the settings table (empty if unset)
  token-exists <db> <name>  prints 1 or 0: is there an API token with that name
  certdate "<enddate>"      "<epoch> <YYYY-MM-DD>" for `openssl x509 -enddate`
                            text such as "Dec 30 12:00:00 2026 GMT"
  newest <dir>              "<epoch> <YYYY-MM-DD>" of the newest casavpn-*.tar.*
                            in <dir>, or nothing when there is none
  pair-link                 reads key=value lines on stdin (panel, panelToken, relay,
                            relayToken, sub) and prints the casavpn://pair link with
                            every value percent-encoded. The values are secrets, so they
                            come on stdin, never in argv, where `ps` shows them.

Exit status: 0 ok, 1 the lookup failed (reason on stderr), 2 usage.
"""

import calendar
import datetime
import glob
import os
import sqlite3
import sys
import time
import urllib.parse


def utc_day(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%d")


def open_ro(path):
    # mode=ro never creates or writes the file. immutable=1 is NOT used: the panel
    # keeps the database in WAL mode, and immutable would ignore the log.
    uri = "file:" + urllib.parse.quote(os.path.abspath(path)) + "?mode=ro"
    db = sqlite3.connect(uri, uri=True, timeout=5)
    db.execute("PRAGMA query_only = 1")
    return db


def cmd_clients(path):
    db = open_ro(path)
    rows = db.execute(
        "SELECT email, enable, up, down, total, expiry_time FROM client_traffics ORDER BY email"
    ).fetchall()
    for email, enable, up, down, total, expiry in rows:
        email = (email or "").replace("\t", " ").replace("\n", " ").strip()
        if not email:
            continue
        expiry = int(expiry or 0)
        day = utc_day(expiry // 1000) if expiry > 0 else "-"
        print("\t".join(str(v) for v in (
            email, 1 if enable else 0, int(up or 0), int(down or 0), int(total or 0), expiry, day)))


def cmd_inbound(path, port):
    db = open_ro(path)
    row = db.execute("SELECT COUNT(*) FROM inbounds WHERE enable = 1 AND port = ?", (int(port),)).fetchone()
    print(row[0])


def cmd_setting(path, key):
    db = open_ro(path)
    row = db.execute("SELECT value FROM settings WHERE key = ? LIMIT 1", (key,)).fetchone()
    print(row[0] if row and row[0] is not None else "")


def cmd_token_exists(path, name):
    db = open_ro(path)
    row = db.execute("SELECT COUNT(*) FROM api_tokens WHERE name = ?", (name,)).fetchone()
    print(1 if row[0] else 0)


def cmd_certdate(text):
    # openssl pads single-digit days with a space ("Jan  5"); split() absorbs it.
    parts = text.split()
    if parts and parts[-1] == "GMT":
        parts = parts[:-1]
    stamp = time.strptime(" ".join(parts), "%b %d %H:%M:%S %Y")
    epoch = calendar.timegm(stamp)
    print(epoch, utc_day(epoch))


def cmd_newest(directory):
    best = None
    # CASAVPN_BACKUP_GLOB: for hosts whose backups predate the casavpn- prefix.
    pattern = os.environ.get("CASAVPN_BACKUP_GLOB") or "casavpn-*.tar.*"
    for path in glob.glob(os.path.join(directory, pattern)):
        if os.path.basename(path).startswith(".") or not os.path.isfile(path):
            continue
        mtime = int(os.stat(path).st_mtime)
        if best is None or mtime > best:
            best = mtime
    if best is not None:
        print(best, utc_day(best))


PAIR_KEYS = ("panel", "panelToken", "relay", "relayToken", "sub")


def cmd_pair_link():
    values = {}
    for line in sys.stdin.read().splitlines():
        key, sep, val = line.partition("=")
        if sep and key in PAIR_KEYS:
            values[key] = val
    missing = [k for k in PAIR_KEYS if not values.get(k)]
    if missing:
        raise ValueError("missing: " + ", ".join(missing))
    print("casavpn://pair?" + "&".join(
        "%s=%s" % (k, urllib.parse.quote(values[k], safe="")) for k in PAIR_KEYS))


COMMANDS = {
    "clients": (cmd_clients, 1), "inbound": (cmd_inbound, 2), "setting": (cmd_setting, 2),
    "token-exists": (cmd_token_exists, 2), "certdate": (cmd_certdate, 1),
    "newest": (cmd_newest, 1), "pair-link": (cmd_pair_link, 0),
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write(__doc__)
        return 2
    fn, nargs = COMMANDS[argv[1]]
    if len(argv) - 2 != nargs:
        sys.stderr.write("host_probe %s takes %d argument(s)\n" % (argv[1], nargs))
        return 2
    try:
        fn(*argv[2:])
    except (sqlite3.Error, ValueError, OSError) as exc:
        sys.stderr.write("host_probe %s: %s\n" % (argv[1], exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
