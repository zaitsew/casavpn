# Security model

What CasaVPN protects, against whom, and where it stops. Read this before you give
anyone a client profile.

## What you are protecting

1. **The Reality private key and client UUIDs** (in `/etc/x-ui/x-ui.db`). A client
   UUID *is* the credential to use your connection.
2. **Your home network.** A VPN client must not be able to reach it.
3. **The Cloudflare token** (it can edit your DNS: point the name anywhere).
4. **The panel**, which controls all of the above.

## What an attacker on the internet can do

| Attempt | Result |
|---|---|
| Scan the VPN port | Sees the camouflage site's real handshake and certificate |
| Scan the web port by IP | No TLS handshake at all |
| Request the web port with the right hostname | `/sub/` (needs a valid subscription id), robots.txt, otherwise `404` |
| Guess the panel path | `403` from nginx unless they are on the LAN, Tailscale or loopback |
| Brute-force SSH | Port closed from the internet; open to the LAN only, key-only |
| Steal the SD card | Backups are age-encrypted; **the live database is not encrypted at rest**. Treat the card like a key |

## What a VPN client (a person you gave a profile to) can do

- Reach the internet through your home IP address, with the BitTorrent block applied.
- **Not** reach your LAN (`geoip:private` is blocked in the Xray template) or the
  panel (nginx allows only loopback, LAN and Tailscale; the VPN exit shows up as your public IP).
- Share the profile with a friend. A UUID has no per-device binding. If a profile
  leaks, delete that client in the panel and issue a new one. One identity per
  person is what makes that cheap.

## What the operator (you) is responsible for

Everything that connects through the VPN appears to come from your IP address:
your ISP's terms, local law and any abuse complaints land on you. Give profiles
only to people you would vouch for. See [LEGAL.md](LEGAL.md).

## Known limitations

- **Single host, single operator.** There is no HA, no audit trail beyond logs, no
  hardware key for the panel (TOTP only).
- **Trust on first use of the 3x-ui download.** The installer pins a SHA-256 per
  architecture; `--trust-release-sha` accepts the hash published next to the release
  instead (which proves the file matches the release, not that the release is
  good). Never combine it with an offline tarball (the installer refuses).
- **Upstream supply chain.** 3x-ui bundles Xray; you are trusting those projects.
  The pin makes upgrades deliberate, not safe by themselves.
- **The panel password is briefly visible in `ps`.** The 3x-ui CLI takes it as an
  argument, for the instant `install.sh` sets it. Acceptable on a single-user
  host; do not install on a machine with other people's shells.
- **Admin access is a single user with sudo.** Whether that sudo needs a password
  is up to your OS image; review `sudo -l` yourself.
- **The panel's TLS certificate name** does not match LAN addresses; you click
  through a warning on the LAN. The traffic never leaves your network.
- **An IPv6-only or CGNAT line cannot run this** (inbound ports are unreachable).
- **Reality is not undetectable.** It is hard to fingerprint today. No tool is
  guaranteed forever; keep the Xray core current ([UPGRADING.md](UPGRADING.md)).
- **Fail-open DNS.** If the Cloudflare token is revoked, the record freezes at the
  last IP. The updater alerts after three failed runs; the external monitor tells
  you from outside ([MONITORING.md](MONITORING.md)).

## Secrets: where each lives

| Secret | Lives | Never |
|---|---|---|
| Cloudflare token | `/etc/casavpn/casavpn.env` (0600 root) and `cloudflare.ini` (0600) | In git, a chat, an issue, a screenshot |
| Panel user/password/base path | `/etc/casavpn/panel-credentials.env` (0600 root) | Same |
| Reality private key, client UUIDs | `x-ui.db` | Same. `CLIENT-LINKS*` files are git-ignored for this reason |
| age **identity** (private key) | Your laptop's keychain + one offline copy | On the Pi |
| ntfy topic | `NTFY_URL` | It is the only secret protecting your alerts; make it unguessable |

If any of these leaks: rotate it. Token: revoke in the Cloudflare dashboard and
edit the env file. Panel password: `sudo x-ui` menu. Reality keys: generate a new
pair in the inbound and re-issue every client.

## Reporting a vulnerability

See [SECURITY.md](../SECURITY.md).
