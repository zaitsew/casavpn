# Architecture

## Two paths into the host

Keep these apart in your head. Most confusion comes from mixing them up.

### 1. The VPN path (the VPN port, default 443)

```
VPN client --TCP 443--> router (NAT) --> host :443 --> Xray (VLESS + Reality)
                                                          |
                                         +----------------+----------------+
                                         |                                 |
                                client proves the key               everything else
                                         |                                 |
                              proxied to the internet           relayed to the real
                              (outbound "direct")               CASAVPN_REALITY_TARGET:443
```

This path never touches nginx.

Reality is not "TLS with a certificate you own", it is a **borrowed handshake**.
The host holds no certificate for the camouflage site. A connection that proves
knowledge of the Reality key pair and a short ID is served as a tunnel. Any other
connection (a scanner, a prober, a curious ISP) has its TLS handshake relayed to
the real site and sees that site's genuine certificate. You can check:

```bash
echo | openssl s_client -connect vpn.example.com:443 -servername www.example.net 2>/dev/null \
  | grep -E 'subject=|Verify return code'
```

A genuine certificate for the camouflage site and `Verify return code: 0 (ok)`
is Reality working, not a misconfiguration. `casavpn-healthcheck` does this check.

### 2. The web path (the web port, default 8443)

```
browser --TCP 8443--> router --> host :8443 --> nginx (TLS, Let's Encrypt cert)
                                                  |-- /sub/            -> 127.0.0.1:2096  (subscriptions, public, rate limited)
                                                  |-- /<secret path>/  -> 127.0.0.1:2053  (panel; LAN, Tailscale, loopback only)
                                                  '-- everything else  -> 404
```

A request that does not carry the right `Host` (an IP scan) gets no TLS handshake
at all (`ssl_reject_handshake`), so scanning the bare address reveals nothing.

## Components

| Component | Location | Managed by |
|---|---|---|
| 3x-ui | `/usr/local/x-ui/x-ui` | `x-ui.service`; version pinned in `config/xui-release.env` |
| Xray core | `/usr/local/x-ui/bin/` | 3x-ui (child process) |
| Xray config | `/usr/local/x-ui/bin/config.json` | **Generated** by 3x-ui from the database. Never edit it |
| Panel database | `/etc/x-ui/x-ui.db` (SQLite) | 3x-ui. The real source of truth: Reality private key, clients |
| Settings | `/etc/casavpn/casavpn.env` (root, 0600) | You. Parsed, never sourced |
| Panel credentials | `/etc/casavpn/panel-credentials.env` | `install.sh` (generated) |
| nginx | `/etc/nginx/sites-available/casavpn`, `conf.d/00-casavpn.conf`, `snippets/casavpn-admin-only.conf` | `install.sh` templates |
| Firewall | `/etc/nftables.conf`, table `inet casavpn` | `install.sh` template, `nft -c` checked |
| Certificate | `/etc/letsencrypt/live/<domain>/` | certbot (DNS-01 via Cloudflare) + deploy hook |
| Tools | `/usr/local/bin/casavpn-*`, `/usr/local/lib/casavpn/` | `install.sh` |
| Timers | `casavpn-ddns.timer` (every minute), `casavpn-backup.timer` (03:30) | systemd |

`config.json` is a build artifact: 3x-ui regenerates it from the database on every
restart, so a direct edit looks like it works until the next restart silently
reverts it. Change settings in the panel or the database. This is also why backups
capture `x-ui.db`, not `config.json`.

## Routing rules (do not remove)

3x-ui's default Xray template contains two blocking rules that CasaVPN depends on:

1. destinations in `geoip:private` go to a blackhole. Without this every VPN user
   has a route onto your home LAN: router admin page, printers, NAS.
2. protocol `bittorrent` goes to a blackhole, which keeps file sharing off a
   residential line billed to your name ([LEGAL.md](LEGAL.md)).

`casavpn-healthcheck --local` verifies both are still present in the stored template.

## Reality parameters that must match on both ends

| Parameter | Value |
|---|---|
| Network / security | `tcp` / `reality` |
| Flow | `xtls-rprx-vision` (set on the client too, or the connection stalls) |
| SNI and target | `CASAVPN_REALITY_TARGET` (no default; you choose it) |
| Fingerprint | `chrome` |
| Public key, short ID | from the panel; clients receive the public half only |

Choosing the target matters and has no default: see
[REALITY-TARGET.md](REALITY-TARGET.md) for what makes a good one, how to check a
candidate, and why the VPN port should stay 443.

## Dynamic IP

`casavpn-ddns` reconciles one DNS `A` record with the host's current public IPv4
every minute ([DYNAMIC-IP.md](DYNAMIC-IP.md)). The record is DNS-only (grey cloud)
with a 60 s TTL: a Cloudflare proxy cannot carry the VPN, and a long TTL would
prolong an outage after an address change.

## What this design deliberately is not

- Not a multi-user commercial service: no billing, no quotas beyond what 3x-ui
  shows, one host, one operator.
- Not a way to hide who you are from the people you connect to: it is a private
  tunnel to your own connection ([SECURITY-MODEL.md](SECURITY-MODEL.md)).
- Not exposed on IPv6: no `AAAA` record is published and the firewall accepts the
  public ports on IPv4 only.
