#!/usr/bin/env python3
"""Set (or check) minClientVer on the VLESS/Reality inbound in a 3x-ui database.

minClientVer makes Xray refuse Reality clients older than the given version.
It is the cheapest hardening that keeps old, broken clients away from the
server. 3x-ui keeps it inside the inbound's stream settings JSON, so it has to
be re-asserted after an upgrade (a panel upgrade can rewrite the row).

Usage:
  set_min_client_ver.py --db /etc/x-ui/x-ui.db --version 1.8.0 [--port 443]
  set_min_client_ver.py --db ... --version 1.8.0 --check      # exit 1 if it differs
  set_min_client_ver.py --db ... --version 1.8.0 --dry-run    # show, change nothing

Exit codes: 0 done / already set / check passed, 1 check failed, 2 usage or
data problem (no Reality inbound, several and no --port, bad version).

Run it with x-ui stopped (or restart x-ui afterwards): the panel reads the row
when it builds the Xray configuration.
"""

import argparse
import json
import re
import sqlite3
import sys

VERSION_RE = re.compile(r"^\d+(\.\d+){1,2}$")


def reality_inbounds(conn, port):
    rows = conn.execute(
        "SELECT id, remark, port, protocol, stream_settings FROM inbounds"
    ).fetchall()
    found = []
    for rid, remark, rport, protocol, stream in rows:
        if protocol != "vless":
            continue
        try:
            data = json.loads(stream or "{}")
        except json.JSONDecodeError:
            continue
        if data.get("security") != "reality":
            continue
        if port is not None and rport != port:
            continue
        found.append((rid, remark, rport, data))
    return found


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db", required=True, help="path to x-ui.db")
    ap.add_argument("--version", required=True, help="minimum Xray client version, e.g. 1.8.0")
    ap.add_argument("--port", type=int, help="inbound port (needed when there are several Reality inbounds)")
    ap.add_argument("--check", action="store_true", help="only verify; exit 1 if it differs")
    ap.add_argument("--dry-run", action="store_true", help="show what would change")
    args = ap.parse_args(argv)

    if not VERSION_RE.match(args.version):
        print(f"set_min_client_ver: not a version: {args.version}", file=sys.stderr)
        return 2

    try:
        conn = sqlite3.connect(args.db, timeout=15)
        inbounds = reality_inbounds(conn, args.port)
    except sqlite3.Error as exc:
        print(f"set_min_client_ver: cannot read {args.db}: {exc}", file=sys.stderr)
        return 2

    if not inbounds:
        where = f" on port {args.port}" if args.port is not None else ""
        print(f"set_min_client_ver: no VLESS/Reality inbound{where} in {args.db}", file=sys.stderr)
        return 2
    if len(inbounds) > 1 and args.port is None:
        ports = ", ".join(str(p) for _, _, p, _ in inbounds)
        print(f"set_min_client_ver: several Reality inbounds (ports {ports}); pass --port", file=sys.stderr)
        return 2

    status = 0
    for rid, remark, port, data in inbounds:
        reality = data.setdefault("realitySettings", {})
        current = reality.get("minClientVer", "")
        label = f"inbound {rid} (port {port}{', ' + remark if remark else ''})"
        if current == args.version:
            print(f"{label}: minClientVer already {args.version}")
            continue
        if args.check:
            print(f"{label}: minClientVer is '{current or 'unset'}', want {args.version}")
            status = 1
            continue
        if args.dry_run:
            print(f"{label}: would set minClientVer '{current or 'unset'}' -> {args.version}")
            continue
        reality["minClientVer"] = args.version
        conn.execute(
            "UPDATE inbounds SET stream_settings = ? WHERE id = ?",
            (json.dumps(data, indent=2), rid),
        )
        conn.commit()
        print(f"{label}: minClientVer '{current or 'unset'}' -> {args.version} (restart x-ui to apply)")
    conn.close()
    return status


if __name__ == "__main__":
    sys.exit(main())
