# CasaVPN

A home VPN on a Raspberry Pi that you can rebuild in an afternoon and trust to
look after itself. VLESS + Reality (3x-ui / Xray) behind a default-deny firewall,
with a dynamic-IP updater, encrypted backups, a healthcheck and an external
monitor, all installed by one script.

```
 phone / laptop ──443──►  router  ──►  Raspberry Pi
                                         ├─ Xray (Reality)        the VPN; strangers see a real website
                                         └─ nginx :8443           /sub/ for client profiles (public)
                                                                  the panel (LAN / Tailscale only)
   Cloudflare DNS ◄── casavpn-ddns (every minute)      Cloudflare Worker ──► your phone (ntfy)
```

> **Status: 0.1.0, a first release.** Every script is covered by offline tests with
> fake system tools. `install.sh` has **not** yet been run end to end on a clean
> Raspberry Pi. Do your first install with the Pi in reach, and read the
> [CHANGELOG](CHANGELOG.md) for what is verified and what is not.

## Quick start

```bash
git clone <REPO_URL> casavpn && cd casavpn      # on the Pi, as a sudo-capable user with an SSH key
sudo ./install.sh --dry-run                     # 1. creates /etc/casavpn/casavpn.env, then stops
sudo nano /etc/casavpn/casavpn.env              # 2. domain, LAN range, Cloudflare token, age public key
sudo ./install.sh                               # 3. installs; prints the one panel step left for you
# 4. create the Reality inbound + clients in the panel as printed, then: sudo casavpn-minver
# 5. forward ONLY the VPN port (443) and the web port (8443) on your router, test from mobile data
```

The long version, with prerequisites: [docs/QUICKSTART.md](docs/QUICKSTART.md).

## What you get

| | |
|---|---|
| **Stealth transport** | VLESS + Reality: a probe sees the genuine certificate of a real site, never a VPN |
| **Closed by default** | nftables default-deny; SSH from the LAN only; key-only SSH; fail2ban; the panel on loopback behind nginx, reachable from LAN, Tailscale or one VPN identity |
| **Survives a changing IP** | `casavpn-ddns` reconciles your DNS record every minute from four IP sources, reads it back, and pushes an alert |
| **Certificates without port 80** | Let's Encrypt by DNS-01 through Cloudflare |
| **Backups you have restored** | nightly age-encrypted archive, pull to another machine, a restore drill that proves it |
| **Safe upgrades** | the 3x-ui release is pinned by SHA-256; `casavpn-upgrade` backs up first and rolls back by itself; the minimum client version is re-asserted |
| **You hear first** | `casavpn-healthcheck` (host and remote), an external Cloudflare Worker monitor, ntfy pushes |
| **Defaults that protect you** | VPN clients cannot reach your LAN; BitTorrent is blocked; the healthcheck fails if either rule disappears |
| **Tested without a Pi** | ~480 offline test assertions, shellcheck-clean, plus a scanner that keeps personal data out of the repository |

## Requirements

- A Raspberry Pi 4/5 (or any Debian 12+/Ubuntu 22.04+ host, arm64 or amd64) on a wired connection
- A **public IPv4 address** (not CGNAT) and a router where you can forward two TCP ports
- A domain whose DNS is on Cloudflare (free plan) and a DNS-edit API token for that zone
- A laptop with `ssh`; `age` for backups; optionally Tailscale and an [ntfy](https://ntfy.sh) topic

Not for you if you only need a quick VPN on a network that does not block VPNs
(plain WireGuard is simpler), or if your line is CGNAT or IPv6-only ([FAQ](docs/FAQ.md)).

## Commands

| On the Pi | |
|---|---|
| `casavpn-healthcheck --local` | verify every layer |
| `casavpn-ddns [--check\|--force]` | DNS record vs public IP |
| `casavpn-backup` | encrypted backup now |
| `casavpn-minver [--check]` | set / verify the minimum client version |
| `casavpn-upgrade` / `casavpn-rollback` | move 3x-ui to the pinned release / undo it |

| On your laptop | |
|---|---|
| `scripts/healthcheck.sh` | the same checks from outside |
| `scripts/gen-client-links.sh` | client links from the live database |
| `scripts/pull-backups.sh`, `scripts/restore-drill.sh` | fetch backups, prove they restore |
| `scripts/cf-api.sh`, `scripts/dns-diff.sh` | Cloudflare helper, DNS migration checks |
| `./check.sh` | shellcheck, tests, personal-data scan (the gate; there is no CI) |

## Documentation

[Quick start](docs/QUICKSTART.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Hardening and panel access](docs/HARDENING.md) · [Security model](docs/SECURITY-MODEL.md) ·
[Clients](docs/CLIENTS.md) · [Dynamic IP](docs/DYNAMIC-IP.md) · [Backup and restore](docs/BACKUP.md) ·
[Upgrading](docs/UPGRADING.md) · [Monitoring](docs/MONITORING.md) · [DNS migration](docs/DNS-MIGRATION.md) ·
[Reality target](docs/REALITY-TARGET.md) · [Runbook](docs/RUNBOOK.md) · [FAQ](docs/FAQ.md) · [Legal](docs/LEGAL.md)

## Layout

```
install.sh              the installer (--dry-run, --show <config>, --skip-<step>)
casavpn.env.example     every setting, documented
scripts/                tools installed to /usr/local/bin, and laptop-side helpers (scripts/lib/ shared code)
config/                 templates: nftables, nginx, sshd, fail2ban, systemd, launchd, DNS examples, 3x-ui pin
monitor/                the external uptime monitor (Cloudflare Worker, TypeScript)
tests/                  offline tests with fake systemctl/nft/sshd/dig/curl on PATH
tools/                  the personal-data scanner
docs/                   the manual
check.sh                the local gate
```

## Responsible use

You are the operator: traffic leaves from your IP address. Read
[docs/LEGAL.md](docs/LEGAL.md) and [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md)
before you invite anyone.

## License

MIT, see [LICENSE](LICENSE). 3x-ui and Xray are separate projects under their own licenses.
