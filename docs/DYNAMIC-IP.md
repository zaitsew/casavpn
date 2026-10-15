# Dynamic IP (casavpn-ddns)

Home connections change address. When yours does, the hostname in every client
profile points at nobody until DNS is corrected. `casavpn-ddns` corrects it within
a minute and tells you.

## How it works

Every minute (`casavpn-ddns.timer`, one minute after the previous run ends):

1. Learns the host's public IPv4 from **four independent echo services** and needs
   **two to agree**. A tie or a lone answer means "do nothing, exit 1".
2. Refuses non-public answers: RFC 1918, CGNAT `100.64.0.0/10`, loopback, link-local.
3. Reads the record **back from the provider** (never trusts a local cache).
4. If the content differs from the IP, or the record is proxied, has a TTL other
   than 60, or is not type `A`, it rewrites it, reads it back again, and only then
   records success.

State (last IP, failure counter, last alert time) lives in `/var/lib/casavpn-ddns`.
A lock prevents two runs overlapping.

## Alerts (ntfy)

With `NTFY_URL` set, at most one identical message per hour:

| Push | Meaning | What to do |
|---|---|---|
| `<name>: <old> -> <new>` | The ISP changed the IP (or someone edited the record); it was repaired | Nothing: this is the system working |
| `casavpn-ddns failing` | 3 runs in a row failed (Cloudflare unreachable, token revoked, IP sources disagree...). Carries the last error | `journalctl -u casavpn-ddns.service -n 50` |
| `IP not public` | The host's address is private or CGNAT. DNS was left alone | Ask your ISP for a public address; DDNS cannot fix this |
| `multiple A records` | More than one A record for the name. Nothing was changed | Delete the extra record in the dashboard |

This is a signal from **inside** the house. If the host or the line is down it
cannot push anything: pair it with the [external monitor](MONITORING.md). Without
`NTFY_URL` the same events are only written to the journal.

## Commands

```bash
sudo casavpn-ddns --check      # exit 0 if DNS == public IP, 1 otherwise. Writes nothing
sudo casavpn-ddns --dry-run    # everything except the write; logs what it would do
sudo casavpn-ddns --force      # a real write + read-back round trip (proves the token works)
journalctl -u casavpn-ddns.service -n 30 --no-pager
systemctl list-timers casavpn-ddns.timer
```

## Setup

`install.sh` installs the script and the timer. You provide `CASAVPN_DOMAIN`,
`CF_API_TOKEN` and `CF_ZONE_ID` in `/etc/casavpn/casavpn.env`.

The Cloudflare token needs only **Zone > DNS > Edit**, restricted to the single
zone. Create it in the Cloudflare dashboard (My Profile > API Tokens). It is also
used for certificate issuance (DNS-01), so one token serves both.

The record must exist once (type `A`, name `CASAVPN_DOMAIN`, any content, **DNS
only**/grey cloud): if it does not, the updater creates it on the first run.
Check with `scripts/cf-api.sh list-records <zone>`.

## Why DNS-only and TTL 60

A Cloudflare proxy (orange cloud) carries HTTP(S) only; it cannot carry a VLESS
connection to your port. A long TTL would keep the old address cached for hours
after a change. `casavpn-ddns` enforces both on every run and `scripts/cf-api.sh
ensure-grey` / `set-ttl` do it by hand.

## Not using Cloudflare

The provider is pluggable. `CASAVPN_DDNS_PROVIDER` selects a set of five
functions named `provider_<name>_<verb>` in `scripts/casavpn-ddns` (`validate`,
`get`, `update`, `record_ok`, `describe_drift`; the contract is in the comment at
the top of the script). Add a provider by implementing those, listing its name in
`KNOWN_PROVIDERS`, adding a case to `tests/test-ddns.sh`, and opening a pull
request. Certificates are separate: `install.sh` issues them through certbot's
Cloudflare plugin, so with another DNS host run it with `--skip-certs` and point
nginx at a certificate you manage yourself.

## If your IP is behind CGNAT

You cannot run this on that line: inbound connections never reach you. The
public-IP echo services cannot detect it (behind CGNAT they report the carrier's
shared address, which is a valid public IP), so the updater will happily publish
an address nobody can connect to. The external monitor's port check is what
catches it. Call the
ISP and ask for a public IPv4 (often free, sometimes "business" plan). An
alternative is a small VPS relay, which is a different design from CasaVPN.
