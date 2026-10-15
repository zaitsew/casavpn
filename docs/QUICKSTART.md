# Quick start

From a fresh Raspberry Pi to a working VPN in about 45 minutes. Read
[FAQ.md](FAQ.md) first if you are not sure CasaVPN is what you want, and
[LEGAL.md](LEGAL.md) if you are not sure it is allowed where you live.

> **Status.** CasaVPN 0.1.0 is covered by offline tests (fake `systemctl`, `nft`,
> `sshd`, ...). `install.sh` has **not** yet been run end to end on a clean Pi.
> Do the first install with the Pi next to you, not in a drawer in another city,
> and keep a monitor and keyboard handy in case a firewall or SSH step goes wrong.

## What you need

| Thing | Notes |
|---|---|
| A Raspberry Pi 4/5 (or any Debian/Ubuntu box), wired to the router | arm64 or amd64. Raspberry Pi OS Lite 64-bit, Debian 12+ or Ubuntu 22.04+ |
| A public IPv4 address | **Not** CGNAT. Check: the address your router reports as "WAN" must equal what `curl -4 ifconfig.me` shows. If it starts with `100.64`-`100.127` or is private, ask your ISP for a public address first |
| A domain on Cloudflare (free plan) | For the hostname, the dynamic-IP updater and the certificate. [DNS-MIGRATION.md](DNS-MIGRATION.md) if the domain lives elsewhere |
| A Cloudflare API token | `Zone > DNS > Edit`, restricted to that one zone |
| Router access | To forward two TCP ports and reserve a LAN address |
| A laptop with `ssh` | And an SSH key pair. Password logins are switched off |

## 1. Prepare the Pi

1. Flash Raspberry Pi OS Lite 64-bit. In the imager, enable SSH **with your public
   key**, set a user (these docs say `pi`; any name works) and the hostname.
2. In the router, reserve a fixed LAN address for the Pi (DHCP reservation). Written
   as `<LAN_IP>` below.
3. From your laptop: `ssh pi@<LAN_IP>`. It must work with the key, no password.

## 2. Get CasaVPN onto the Pi

```bash
ssh pi@<LAN_IP>
sudo apt-get update && sudo apt-get install -y git
git clone <REPO_URL> casavpn && cd casavpn
```

(`<REPO_URL>` is wherever you cloned or downloaded CasaVPN from.)

## 3. Configure

```bash
sudo ./install.sh --dry-run      # creates /etc/casavpn/casavpn.env from the example and stops (exit 3)
sudo nano /etc/casavpn/casavpn.env
```

Fill in at least `CASAVPN_DOMAIN`, `CASAVPN_LAN_CIDR`, `CASAVPN_ADMIN_USER`,
`CF_API_TOKEN` and `CF_ZONE_ID`. Also set `AGE_RECIPIENT` (see
[BACKUP.md](BACKUP.md), step 1: do it now, a VPN without a restorable backup is
a weekend lost) and optionally `NTFY_URL`. Every key is documented in the file.

Then read what it would do:

```bash
sudo ./install.sh --dry-run
sudo ./install.sh --show nftables     # also: nginx | nginx-admin | sshd | fail2ban
```

## 4. Install

```bash
sudo ./install.sh
```

It asks before it loads the firewall and sets a confirmation timer: if you cannot
answer (because the rules locked you out) it removes them again. It refuses to
harden SSH without an authorized key, and refuses to load the firewall when your
SSH session is not from `CASAVPN_LAN_CIDR`.

What is automated and what is not: [below](#what-the-installer-does-and-does-not-do).

At the end it prints the exact values for the one manual step.

## 5. Create the VPN inbound in the panel

Open the panel from a machine on your LAN. The URL, user and password are in a
root-only file:

```bash
sudo cat /etc/casavpn/panel-credentials.env
```

Use `https://<LAN_IP>:8443/<base path>/` (the browser will warn about the
certificate name: it is issued for your domain, not the LAN address; accept it
for this LAN-only visit). Then, as the installer prints: add a VLESS inbound on
your VPN port with security Reality, the target in `CASAVPN_REALITY_TARGET`,
"Get New Cert", and one client per person with flow `xtls-rprx-vision`.

Afterwards:

```bash
sudo casavpn-minver              # set the minimum client version and restart x-ui
casavpn-healthcheck --local      # everything should be green
```

Turn on the panel's two-factor login now ([HARDENING.md](HARDENING.md#6-panel-two-factor-login)).

## 6. Open the router

Forward **only** these two TCP ports to `<LAN_IP>`:

| External | Internal | What |
|---|---|---|
| 443 | 443 | the VPN |
| 8443 | 8443 | client subscriptions |

Do not forward SSH (22), the panel ports (2053, 2096), or port 80. Certificates
use DNS validation, so port 80 is never needed.

## 7. Test from outside

On a phone **with Wi-Fi off** (mobile data), import a client ([CLIENTS.md](CLIENTS.md))
and open any site. Then, from your laptop:

```bash
export CASAVPN_SSH_TARGET=pi@<LAN_IP>
CASAVPN_DOMAIN=vpn.example.com ./scripts/healthcheck.sh
```

Finally set up [monitoring](MONITORING.md) and run a [restore drill](BACKUP.md#prove-it-restores)
once. A backup you never restored is a hope.

## What the installer does and does not do

| Automated by `install.sh` | Documented, left to you |
|---|---|
| apt packages, unattended security upgrades | The Raspberry Pi OS image and SSH key |
| 3x-ui download pinned by SHA-256, panel credentials, secret base path, loopback-only bindings | Creating the VPN inbound and clients in the panel (the panel does it better; exact values printed) |
| Let's Encrypt certificate by DNS-01, renewal hook | The Cloudflare account, domain and API token |
| nginx front end, firewall (nftables), key-only SSH, fail2ban | Router: DHCP reservation and the two port forwards |
| Dynamic-IP updater and nightly encrypted backup timers | Panel 2FA, the age key pair, pulling backups to another machine |
| minimum client version | Tailscale sign-in, the external monitor |

Re-running `install.sh` is safe: it never overwrites an existing env file, panel
database or credentials, and keeps a `<file>.pre-casavpn` copy of any other file
it replaces.
