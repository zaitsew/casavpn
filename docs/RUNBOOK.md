# Runbook

Start here when something is broken. Playbooks are ordered by how often the cause
actually occurs.

## First: run the healthcheck

```bash
casavpn-healthcheck --local                                      # on the host
CASAVPN_DOMAIN=vpn.example.com CASAVPN_SSH_TARGET=pi@<LAN_IP> ./scripts/healthcheck.sh   # from the laptop
```

It walks DNS, the VPN transport, the web front end and the host services and says
which layer failed. Most incidents are diagnosed by its output alone.

---

## Playbook 1: the VPN stopped working

**By far the most likely cause is a changed public IP with stale DNS**, often after
a power cut or an ISP maintenance window.

```bash
dig +short vpn.example.com @1.1.1.1      # what the world thinks
curl -4 -s https://api.ipify.org         # the IP you actually have (run at home)
```

If they differ, force the updater:

```bash
ssh pi@<LAN_IP> 'sudo casavpn-ddns --force'
```

If the updater is not installed or broken, either fix the record by hand in the
Cloudflare dashboard, or get clients back immediately **without DNS**: Reality's
SNI is independent of the address dialled, so connecting to the IP works.

```bash
./scripts/gen-client-links.sh "$(curl -4 -s https://api.ipify.org)"
```

Re-import those links on each device ([CLIENTS.md](CLIENTS.md#keep-an-emergency-profile)).
If the two addresses are the same, DNS is not the problem: go to playbook 2.

## Playbook 1b: DNS is fixed but one device still cannot connect

`dig @1.1.1.1` is right, the server tests healthy, a specific device still fails;
often reported as "search works but no page opens". That device's resolver (usually
the ISP's) is still serving the old address, sometimes for 45+ minutes past the TTL.
Fix: give the device a public resolver ([CLIENTS.md](CLIENTS.md#the-dns-setting-and-who-needs-it))
or use the emergency IP profile in the meantime.

## Playbook 2: the server is unreachable

1. `ssh pi@<LAN_IP>` from home. If it does not answer, the Pi is off or off the network:
   power, cable, router. If it does, `casavpn-healthcheck --local`.
2. `systemctl status x-ui nginx nftables`. Restart what is down:
   `sudo systemctl restart x-ui`. Read `sudo journalctl -u x-ui -n 50`.
3. From **outside** (phone on mobile data), is the port open? A test from your own
   LAN can succeed through NAT loopback while the internet path is broken.
   `nc -vz vpn.example.com 443`, or an online port checker.
4. Did the router lose its port forwards or its DHCP reservation? Confirm the VPN
   and web ports still forward to `<LAN_IP>`.
5. Did the ISP move you behind CGNAT? Compare the router's WAN address with
   `curl -4 ifconfig.me`; if they differ, or the WAN address is `100.64.x`-`100.127.x`,
   inbound is impossible: ask the ISP for a public address.

## Playbook 3: every client stopped working after an upgrade

Symptom: the server tests perfectly (port open, the camouflage certificate is
genuine, the healthcheck is green) but **no real client can connect**.

Cause: **Xray enforces a minimum client version.** From 26.3.27 an empty
`minClientVer` means "the server's own recent version", so clients with an older
bundled core are refused. Rejection happens after the Reality handshake, during VLESS
authentication, which is why probes and the healthcheck's camouflage test do not see it.
The tell is in the log:

```bash
sudo journalctl -u x-ui --since "10 min ago" --no-pager | grep -i "minimal client"
```

Fix:

```bash
sudo casavpn-minver --check     # shows the current value
sudo casavpn-minver             # sets CASAVPN_MIN_CLIENT_VER on the inbound and restarts x-ui
```

Clients reconnect by themselves. Verify with a client **older** than the server (a
fresh download hides this bug). Add that test to every upgrade.

## Playbook 3b: Shadowrocket fails after an upgrade, Xray clients work

Symptom: after a 3x-ui or Xray core change, Shadowrocket (iOS) cannot connect, while
an Xray-based client (v2rayN, an old test client) still does. Keys, shortId, SNI,
the clock and `minClientVer` all check out, so this is **not** Playbook 3. The tell
is one line in the log for every Shadowrocket attempt:

```
REALITY: processed invalid connection from <ip>: authentication failed or validation criteria not met
```

```bash
sudo journalctl -u x-ui --since "10 min ago" --no-pager | grep "REALITY: processed invalid connection"
```

Known cause: Xray **26.10.10** (the core bundled with 3x-ui 3.10.2) refuses
Shadowrocket at the Reality handshake. The root cause inside that core is not
known. CasaVPN pins 26.7.28 for this reason ([UPGRADING.md](UPGRADING.md#the-xray-core-pin)).

1. Which core is running?

   ```bash
   a=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
   /usr/local/x-ui/bin/xray-linux-$a version | head -n1
   ls -l /usr/local/x-ui/bin/        # a *.bundled file means the pin was applied
   grep CASAVPN_XRAY_CORE /etc/casavpn/casavpn.env   # "bundled" = you opted out of the pin
   ```

2. Put the core back on the pin (this also fixes a host that was installed before the
   pin existed): `git pull`, then `sudo casavpn-upgrade`. It re-applies the pin even
   when the panel is already at the pinned version and restarts x-ui once.
3. Test Shadowrocket **on mobile data**. If it connects, you are done.
4. If it still fails, find out what the server sees. This needs info-level logging,
   which is off by default; turn it on for the length of the test only. The log paths
   below are rewritten by 3x-ui to `/var/log/x-ui/` when it starts, so the values you
   write are only placeholders.

   ```bash
   DB=/etc/x-ui/x-ui.db
   sudo systemctl stop x-ui
   sudo install -d -m 0700 /root/casavpn-log-test
   sudo python3 - "$DB" /root/casavpn-log-test/template.orig <<'PY'
   import json, sqlite3, sys
   db = sqlite3.connect(sys.argv[1])
   row = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
   if not row or not row[0]:
       sys.exit("no saved template: set Xray Configs -> Basic -> Log level to info in the panel instead, and revert it there")
   open(sys.argv[2], "w").write(row[0])          # the original, for the revert
   tpl = json.loads(row[0])
   tpl["log"] = {"loglevel": "info", "access": "/var/log/x-ui/access.log", "error": "/var/log/x-ui/error.log"}
   db.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(tpl),))
   db.commit()
   PY
   sudo systemctl start x-ui
   ```

   Reproduce with Shadowrocket, then read
   `sudo tail -n 100 /var/log/x-ui/error.log /var/log/x-ui/access.log`. No line at all
   means the connection never reached Xray (a network problem, not this one); a
   REALITY "invalid connection" line means the handshake itself was refused. Keep the
   core version and that line for the bug report, minus the client addresses.
5. **Revert and clean up.** The logs hold client addresses and destinations: do not
   leave them.

   ```bash
   sudo systemctl stop x-ui
   sudo python3 - "$DB" /root/casavpn-log-test/template.orig <<'PY'
   import sqlite3, sys
   db = sqlite3.connect(sys.argv[1])
   db.execute("update settings set value=? where key='xrayTemplateConfig'", (open(sys.argv[2]).read(),))
   db.commit()
   PY
   sudo systemctl start x-ui
   sudo rm -f /var/log/x-ui/access.log /var/log/x-ui/error.log
   sudo rm -rf /root/casavpn-log-test
   ```

   Check `casavpn-healthcheck --local`: it flags a template that lost its blocking rules.
6. Only after Shadowrocket works again on mobile data, close the incident. If a newer
   core fixes it, move the pin in one commit (version and both hashes) and repeat step 3
   before releasing it.

The general rule is in [UPGRADING.md](UPGRADING.md#changing-the-xray-core): after any
core change, test a real non-Xray client on mobile data.

## Playbook 4: clients connect, then immediately drop

A connect, a little data and a FIN within a second or two is a **Reality handshake
mismatch**, not a network fault. Confirm the server first:

```bash
echo | openssl s_client -connect vpn.example.com:443 -servername www.example.net   # your CASAVPN_REALITY_TARGET 2>/dev/null \
  | grep -E 'subject=|Verify return code'
```

A genuine certificate for the camouflage site means the server is fine; the client
configuration is wrong. Compare, against the panel, the public key (`pbk`), a short
ID (`sid`), SNI, flow (`xtls-rprx-vision`), fingerprint (`chrome`), and
`tcp`/`reality`. The reliable fix is to regenerate rather than hand-edit:
`./scripts/gen-client-links.sh`. Regenerating the Reality key pair is a last
resort: it invalidates every client at once and is almost never the cause.

## Playbook 5: I cannot reach the panel

The panel is not on the internet ([HARDENING.md](HARDENING.md#reaching-the-panel-panel-access)).

| From | Do |
|---|---|
| Home | `https://vpn.example.com:8443/<base path>/`, the name pointed at the Pi's LAN address by a hosts entry or split DNS ([HARDENING.md](HARDENING.md#reaching-the-panel-panel-access)) |
| Away, VPN down | Tailscale address, or `ssh` over Tailscale and a tunnel |
| Away, VPN up | the panel route, if you set it up |
| Anywhere with SSH | `ssh -L 8080:127.0.0.1:2053 pi@<LAN_IP>` then `http://127.0.0.1:8080/<base path>/` |

Forgot the path or the password?

```bash
sudo cat /etc/casavpn/panel-credentials.env
sudo sqlite3 /etc/x-ui/x-ui.db "select key,value from settings where key in ('webPort','webBasePath');"
sudo x-ui          # menu: reset username/password
```

A `403` from nginx means you are not coming from loopback, the LAN or Tailscale. At home it
usually means the name resolved to your PUBLIC address and the request hairpinned through
the router, which is refused on purpose: use the hosts entry or split DNS.

## Playbook 6: the certificate expired or renewal fails

```bash
sudo certbot certificates
sudo certbot renew --dry-run
sudo journalctl -u certbot.service -n 50 --no-pager
```

Renewal is DNS-01: it needs the Cloudflare token (`/etc/casavpn/cloudflare.ini`) to
be valid and scoped to the zone, not an open port. A revoked or rotated token is the
usual cause. After you rotate `CF_API_TOKEN` in `casavpn.env`, re-run `install.sh`: it
rewrites `cloudflare.ini` on every run that has a token. After a renewal nginx is reloaded by the deploy hook; if you renewed by
hand, `sudo systemctl reload nginx`.

## Playbook 7: after any power cut

Everything starts on boot. The one thing that does not self-correct without the
updater is the public IP. Run the healthcheck; if DNS differs, `sudo casavpn-ddns --force`.

## Playbook 8: I locked myself out

- **Firewall**: `install.sh` arms a timer that removes the table again if you do not
  confirm. If you loaded rules by other means and lost SSH, use the keyboard and
  monitor: `sudo nft delete table inet casavpn`, fix `/etc/nftables.conf`, and check
  it with `sudo nft -c -f /etc/nftables.conf` before loading.
- **SSH key**: put the card in another machine, add your key to
  `~/.ssh/authorized_keys` of the admin user, or remove
  `/etc/ssh/sshd_config.d/00-casavpn-hardening.conf` temporarily (re-add it after).
- **Panel**: `sudo x-ui` on the host resets the credentials.

---

## Routine operations

### Add or remove a client

Panel > Inbounds > the inbound > clients. One client per person and device, with the
flow `xtls-rprx-vision`. To revoke, delete the client; its UUID stops working at once.
Then `./scripts/gen-client-links.sh` for the new link, or send the subscription URL.

### Back up, and test the backup

[BACKUP.md](BACKUP.md). The nightly job runs by itself; the laptop pull and the
monthly restore drill are yours.

### Restore onto a fresh Pi

[BACKUP.md](BACKUP.md#restore-onto-a-fresh-sd-card).

### Update 3x-ui and Xray

[UPGRADING.md](UPGRADING.md): `sudo casavpn-upgrade`, then test with an old client
**and** with Shadowrocket on mobile data (the Xray core is pinned; see the
[pin](UPGRADING.md#the-xray-core-pin) and
[Playbook 3b](#playbook-3b-shadowrocket-fails-after-an-upgrade-xray-clients-work)).

### Change the settings

Edit `/etc/casavpn/casavpn.env`, then re-run the part of `install.sh` that renders
what changed (for example `sudo ./install.sh --skip-packages --skip-3xui --skip-certs`
to re-render nginx, SSH, firewall and fail2ban). Preview any generated file with
`./install.sh --show nginx` first.

---

## Useful diagnostics

```bash
sudo ss -tlnp                                   # what listens, and as whom
sudo journalctl -u x-ui -n 50 --no-pager        # panel and Xray core
sudo nft list chain inet casavpn input          # firewall counters
sudo fail2ban-client status sshd                # SSH bans
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin)'   # effective SSH settings
nc -vz vpn.example.com 443                      # is the port open (run from OUTSIDE)
```
