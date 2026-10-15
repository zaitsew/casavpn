#!/usr/bin/env python3
"""Render VLESS/Reality client links from 3x-ui's `sqlite3 -json` output.

Reads the JSON rows on stdin, writes the links to stdout and to a file.

Usage: render_links.py <address> <output-path> [tag-prefix]

The tag prefix defaults to "CasaVPN"; the link label is <prefix>-<client email>.
"""

import json
import os
import sys
import urllib.parse


def build_links(rows, address, prefix="CasaVPN"):
    links = []
    for row in rows:
        settings = json.loads(row["settings"])
        stream = json.loads(row["stream_settings"])
        port = row["port"]

        reality = stream.get("realitySettings", {})
        inner = reality.get("settings", {})

        base = {
            "type": stream.get("network", "tcp"),
            "security": stream.get("security", "reality"),
            "pbk": inner.get("publicKey", ""),
            "fp": inner.get("fingerprint", "chrome"),
            "sni": (reality.get("serverNames") or [""])[0],
            "sid": (reality.get("shortIds") or [""])[0],
            "spx": inner.get("spiderX", "/"),
        }

        for client in settings.get("clients", []):
            params = dict(base)
            # `flow` is per-client and must match on both ends, so carry it
            # through rather than assuming a default.
            if client.get("flow"):
                params["flow"] = client["flow"]
            query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
            tag = urllib.parse.quote(f"{prefix}-{client.get('email') or 'client'}")
            host = f"[{address}]" if ":" in address and not address.startswith("[") else address
            links.append(f"vless://{client['id']}@{host}:{port}?{query}#{tag}")

    return links


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)

    address, out_path = sys.argv[1], sys.argv[2]
    prefix = sys.argv[3] if len(sys.argv) == 4 else "CasaVPN"

    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit("no data received from the panel database")

    try:
        rows = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.exit(f"could not parse sqlite output as JSON: {exc}")

    links = build_links(rows, address, prefix)
    if not links:
        sys.exit("no enabled inbounds with clients found")

    body = "\n\n".join(links)
    # The file holds client UUIDs, which are credentials: owner-only from the start.
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(
            "SENSITIVE: contains client UUIDs. Do not commit or share.\n"
            f"Generated for address: {address}\n\n{body}\n"
        )

    print(body)
    print(f"\n{len(links)} link(s) written to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
