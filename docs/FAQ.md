# FAQ

## What is this, in one paragraph?

A Raspberry Pi at home that runs a VLESS + Reality VPN (3x-ui and Xray), made
reproducible: one installer, a firewall, hardened SSH, a dynamic-IP updater,
encrypted backups, a healthcheck and an external monitor. You get your own private
exit through your home connection, for you and a handful of people you trust.

## Who is it for?

People who want a private tunnel through a connection they control (travelling,
family abroad, a censored network) and are comfortable with a command line and a
router's port-forwarding page. It is not a commercial VPN, not a way to appear
anonymous, and not a business.

## Why not WireGuard or OpenVPN?

They are excellent, simple, and easy to recognise: a network that blocks VPN
protocols blocks them. Reality makes the port look like an ordinary HTTPS site to
anyone without the key. If your network does not block VPNs, plain WireGuard is
simpler and you should probably use it.

## Why a Pi and not a cloud VPS?

A VPS has a data-centre address that many sites and some networks treat with
suspicion, and costs money every month. A home line has a residential address.
The price is that you maintain the host and live with your home ISP's uptime.

## Do I need a domain?

You need a hostname. A cheap domain on Cloudflare (free plan) gives you the name, the
dynamic-IP updater and the certificate. Without one the VPN still works if your IP
never changes, but you lose the self-healing.

## Does it work on IPv6-only or behind CGNAT?

No. You need a public IPv4 address with inbound ports. Check
[QUICKSTART.md](QUICKSTART.md#what-you-need). CGNAT cannot be fixed from your side.

## Why is the VPN on port 443 and the web part on 8443?

443 is what a firewall that filters by port lets through, and Reality answers
strangers with the real camouflage site. 8443 serves the subscription URLs and the
(LAN-only) panel through nginx. Both are overridable (`CASAVPN_VPN_PORT`,
`CASAVPN_WEB_PORT`).

## Which site should I use as the Reality target?

There is deliberately no default, and the installer refuses to run without one: a
shared default is a fingerprint, and Xray itself warns about the famous choices.
Pick a site that serves TLS 1.3 and HTTP/2 directly on 443, is near your server and
is not one of the big well-known defaults. How to check a candidate:
[REALITY-TARGET.md](REALITY-TARGET.md).

## Can I use it without Cloudflare?

The VPN, firewall, SSH and backups do not need it. Dynamic DNS and certificates do.
See [DYNAMIC-IP.md](DYNAMIC-IP.md#not-using-cloudflare). A new DDNS provider is a
small contribution.

## Why does the installer not create the VPN inbound itself?

The panel does it well and a script that reimplements 3x-ui's database schema
breaks on every upgrade. The installer prints the exact values and
`casavpn-minver` finishes the part that must be exact.

## Is it safe to give a friend a profile?

They can use your internet connection through your IP. They cannot reach your LAN or
the panel. They *can* share the profile onwards; if that happens, delete the client.
Read [SECURITY-MODEL.md](SECURITY-MODEL.md) and [LEGAL.md](LEGAL.md) first.

## Torrents don't work.

By design: BitTorrent is blocked at the Xray routing layer so a residential line is
not used for file sharing. See [LEGAL.md](LEGAL.md). The block is in the Xray
template; the healthcheck verifies it is still there.

## Why can't I open the panel from the internet?

By design ([HARDENING.md](HARDENING.md#2-the-panel-is-never-on-a-public-interface)).
Use the LAN, Tailscale, or the panel route.

## What if the Pi dies?

[BACKUP.md](BACKUP.md). If you set up the pull and the restore drill, an hour. If you
did not, every client is re-created by hand.

## How do I know it is up?

[MONITORING.md](MONITORING.md): the external monitor tells you before your users do.

## How do I contribute, or report a bug?

[CONTRIBUTING.md](../CONTRIBUTING.md). Security issues: [SECURITY.md](../SECURITY.md).
