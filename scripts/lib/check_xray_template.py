#!/usr/bin/env python3
"""Check an Xray template (3x-ui's xrayTemplateConfig) for the default safety rules.

Reads the template JSON on stdin and checks that routing blocks
  * private destinations (geoip:private), so a VPN client cannot reach the
    server's own LAN through the tunnel, and
  * BitTorrent, which is blocked by default so the home connection is not used
    for file sharing.
A rule counts only if it sends the traffic to a blackhole outbound.

Exit 0 when both are present, 1 when one is missing (it says which), 2 for bad input.
"""

import json
import sys


def main():
    try:
        tpl = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"not valid JSON: {exc}", file=sys.stderr)
        return 2
    holes = {o.get("tag") for o in tpl.get("outbounds", []) if o.get("protocol") == "blackhole"}
    rules = tpl.get("routing", {}).get("rules", [])
    private = any(r.get("outboundTag") in holes and "geoip:private" in r.get("ip", []) for r in rules)
    torrent = any(r.get("outboundTag") in holes and "bittorrent" in r.get("protocol", []) for r in rules)
    missing = []
    if not private:
        missing.append("geoip:private is not blocked")
    if not torrent:
        missing.append("bittorrent is not blocked")
    if missing:
        print("; ".join(missing))
        return 1
    print("geoip:private and bittorrent are blocked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
