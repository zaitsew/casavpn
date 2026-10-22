# Monitoring and alerting

A VPN that fails silently is found by the people who use it, which is the worst
way to find out. This is how to find out first.

## The one rule

> **The check must run outside the house.**

A monitor on the Pi cannot report that the Pi is unreachable, and a monitor on your
laptop cannot report that the home line is down. Both fail silently in exactly the
scenario you built them for.

## 1. External uptime monitor (do this first)

Two free options; pick one.

### Option A: the bundled Cloudflare Worker

[`monitor/`](../monitor) checks DNS and the VPN port from Cloudflare's network
every 5 minutes and pushes to ntfy **only on a state change** (down after two
failures in a row, recovered when the port answers). The alert says where DNS
points, so "stale IP" and "the Pi is off" are told apart at a glance. Setup is in
[monitor/README.md](../monitor/README.md). It needs a free Cloudflare account and
an ntfy topic.

### Option B: a hosted service

Any "TCP port" monitor works: UptimeRobot's free tier, Better Stack, and so on.
Create a **port** monitor for `CASAVPN_DOMAIN` on `CASAVPN_VPN_PORT` at a 5-minute
interval. Because it resolves the hostname on every check, it catches **both**
failure modes: the server down, and DNS pointing somewhere wrong. A second HTTPS
monitor on the web port (`https://vpn.example.com:8443/`, expecting a `404`) checks
nginx and the certificate (enable SSL-expiry alerts at 14 days).

Either way, send the alerts to a channel you actually read on your phone.

## 2. ntfy push alerts

[ntfy.sh](https://ntfy.sh) needs no account. The topic name is the only secret, so
make it unguessable:

```bash
echo "https://ntfy.sh/casavpn-$(openssl rand -hex 8)"
```

Subscribe to that topic in the ntfy app, then put the URL in `NTFY_URL` (the host's
`casavpn.env`, `monitor/wrangler.toml` as a secret, `CASAVPN_PULL_NTFY_URL` on your
laptop). Test it: `curl -d "hello" "$NTFY_URL"`.

What pushes from where:

| Source | Pushes when |
|---|---|
| `casavpn-ddns` (host) | the IP changed and was repaired, three runs in a row failed, the IP is not public, duplicate records ([DYNAMIC-IP.md](DYNAMIC-IP.md)). With the relay set, the first two also go to the relay as `ip.changed` and `ddns.failed` |
| `casavpn-alerts` (host, every 15 min) | the certificate expires in under 14 days, a client nears or hits its traffic limit or expiry, Xray does not listen while x-ui runs, no backup for 36 h, the disk is over 90 % full, the host rebooted. Sent to the relay and, if set, ntfy ([APP.md](APP.md#alerts)) |
| `pull-backups.sh` (laptop) | no fresh backup for 48 h, or no pull for 7 days |
| the Worker (Cloudflare) | the VPN port stops answering / recovers. With the relay's push keys set, it also pushes to the iPhone app |
| the relay (the same Worker) | receives the host's events (`POST /v1/events`), keeps the history and sends the push through APNs ([APP.md](APP.md)) |

`casavpn-alerts` and the relay are optional. Set `CASAVPN_RELAY_URL` and
`CASAVPN_RELAY_TOKEN` in `casavpn.env` (the host token from the relay's setup), or
only `NTFY_URL`, and run `install.sh` again; it enables
`casavpn-alerts.timer` when either channel exists. Read the log with
`journalctl -u casavpn-alerts.service`, check what it would send with
`sudo casavpn-alerts --dry-run`, and see the next run with
`systemctl list-timers casavpn-alerts.timer`. A delivery that fails is retried on
the next run, because the dedupe state is written only after the relay accepts the
event.

## 3. The healthcheck

```bash
casavpn-healthcheck --local                 # on the host
CASAVPN_DOMAIN=vpn.example.com CASAVPN_SSH_TARGET=pi@<LAN_IP> ./scripts/healthcheck.sh   # from the laptop
```

**On the host** it verifies: x-ui/nginx/nftables/fail2ban are active and enabled;
the panel and subscription ports listen on loopback only; the `inet casavpn` table
is loaded; SSH password and root login are off (`sshd -T`); `minClientVer` is set;
the Xray template still blocks private ranges and BitTorrent; the certificate has
more than 14 days left; DNS equals the host's public IP; a backup (`.tar.zst.age` or `.tar.gz.age`) newer than 3 days
exists; the disk is under 90% full.

**From the laptop** it verifies: the name resolves (and, with `--ssh`, to the host's
real public IP); a TCP connection to the VPN port gives the **camouflage site's
genuine certificate**; the web port answers; what must *not* be reachable
(panel and SSH ports) is not; and, over SSH, the host services.

Exit status is non-zero on any critical failure. A warning does not fail the run.
`UNVERIFIED` means the check could not be made, which is not the same as passing.
Run it from cron or a launchd job and pipe failures to ntfy if you want a third
signal; it is not a substitute for the external monitor.

## 4. Certificate expiry

Issuance and renewal use DNS-01, so a stale `A` record does not break renewal (it
did in older designs that needed port 80). A failing renewal is still silent until
the certificate expires; the healthcheck fails under 14 days left and warns under
30. `sudo certbot renew --dry-run` tests the path.

## 5. 3x-ui's built-in Telegram bot (optional)

The panel can send login alerts and scheduled database backups to Telegram (Panel >
Settings > Telegram Bot). The login notification is valuable: if someone
authenticates and it was not you, you know in seconds. Do not rely on it for
backups; use [BACKUP.md](BACKUP.md), which encrypts.

## 6. Logs

```bash
sudo journalctl -u x-ui -n 50 --no-pager
sudo journalctl -u casavpn-ddns.service -n 30 --no-pager
sudo journalctl -u casavpn-backup.service -n 30 --no-pager
sudo nft list chain inet casavpn input      # counters, including the final drop
sudo fail2ban-client status sshd
```
