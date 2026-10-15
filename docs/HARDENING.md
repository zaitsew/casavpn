# Hardening

What `install.sh` applies, why, and how to check or undo each item.
`casavpn-healthcheck --local` verifies most of this on a schedule you choose.

## 1. Host firewall (nftables, default deny)

Template: [config/nftables.conf.tmpl](../config/nftables.conf.tmpl). Inbound:

| Port | From |
|---|---|
| `CASAVPN_VPN_PORT` (443) | anywhere, IPv4 |
| `CASAVPN_WEB_PORT` (8443) | anywhere, IPv4 (nginx decides what is served) |
| `CASAVPN_SSH_PORT` (22) | `CASAVPN_LAN_CIDR` only |
| Tailscale (optional) | SSH and the web port on `tailscale0`, UDP 41641 |
| DHCP, mDNS, ICMP (rate limited) | LAN |

Everything else is dropped, with a rate-limited log line. The forward chain is
`policy drop`: the host routes nothing, Xray is a local proxy.

It creates its **own** `inet casavpn` table and does not flush the ruleset, so
Tailscale, Docker or fail2ban tables survive.

```bash
sudo nft list table inet casavpn
sudo nft -c -f /etc/nftables.conf      # syntax check without loading
```

`install.sh` validates the file with `nft -c`, refuses to load it when your SSH
session is not from the LAN (`--force-firewall` overrides), and arms a
confirmation timer that removes the table again unless you confirm. If you edit
the rules yourself, use the same trick:

```bash
sudo systemd-run --on-active=300 --unit=nft-deadman /usr/sbin/nft delete table inet casavpn
# ...edit and load; then, once SSH still works:
sudo systemctl stop nft-deadman.timer
```

## 2. The panel is never on a public interface

3x-ui's panel (`CASAVPN_PANEL_PORT`) and subscription server (`CASAVPN_SUB_PORT`)
listen on `127.0.0.1` only (`webListen`/`subListen`). The only way in is nginx on
the web port, and nginx serves:

- `/sub/`: public, rate limited (30 requests/minute per address). Clients need it
  to refresh their profile.
- the panel under its **secret base path**: allowed only from loopback, your LAN
  and Tailscale (`100.64.0.0/10`), `deny all` for everyone else.
- everything else: `404`.

The base path is a speed bump, not a secret to rely on. The access control is the
`allow`/`deny` list ([config/nginx/casavpn-admin-only.conf.tmpl](../config/nginx/casavpn-admin-only.conf.tmpl)).

### Reaching the panel (panel access)

| From | How |
|---|---|
| Home LAN | `https://<LAN_IP>:8443/<base path>/` (certificate-name warning is expected) |
| Anywhere, VPN down | Tailscale: `https://<tailscale-ip>:8443/<base path>/`, or `ssh` over Tailscale. This is the repair path, because it does not depend on the thing that is broken |
| Anywhere, VPN up | The optional panel route (below) |
| Last resort | `ssh -L 8080:127.0.0.1:2053 pi@<LAN_IP>` then `http://127.0.0.1:8080/<base path>/` |

A request to the public hostname **from home** hairpins through the router, arrives
from your public IP and is refused. At home use the LAN address.

**Tailscale** is optional. `install.sh --tailscale` (or an installed `tailscale`
command) adds the firewall rules; you still run `sudo tailscale up` once and
approve the device. The free plan is enough. Install Tailscale on your laptop and
phone with the same account.

**The panel route** lets exactly one VPN user (you) open the panel from anywhere
while the VPN works: an Xray `freedom` outbound with `redirect` sends that user's
requests for the web port to nginx on loopback, which then sees `127.0.0.1`.
Every other VPN user leaves through the router, arrives from the public IP and gets
`403`. Merge [config/xray/panel-route.example.json](../config/xray/panel-route.example.json)
into the Xray template (panel > Xray Settings), put the rule **before** the
`geoip:private` block, and replace the hostname, port and client name.

> **Xray 26+ trap.** A `freedom` outbound blocks loopback and private targets by
> default for traffic that arrived on a VLESS inbound. Without the explicit
> `finalRules` allow for `127.0.0.1:<web port>` the redirect fails silently.

## 3. SSH

[config/sshd/00-casavpn-hardening.conf.tmpl](../config/sshd/00-casavpn-hardening.conf.tmpl):
key-only, no root, `AllowUsers <admin user>`, `MaxAuthTries 3`, no X11/agent
forwarding. Local TCP forwarding stays on so `ssh -L` keeps working as the panel
fallback.

The `00-` prefix is load-bearing: sshd takes the **first** value it sees for a
keyword and reads drop-ins in sorted order, and images such as cloud-init
re-assert `PasswordAuthentication yes` in a `50-` file.

`install.sh` refuses to write this file unless an authorized key exists for the
admin user and `sshd -t` accepts the result. Check what is *effective*:

```bash
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|allowusers)'
ssh -o BatchMode=yes -o PreferredAuthentications=publickey pi@<LAN_IP> true && echo key login works
```

Test a **second** SSH session before you close the first.

## 4. fail2ban

An `sshd` jail (systemd backend): 4 failures in 10 minutes earns a 1 hour ban; the
LAN is on the ignore list so you cannot lock yourself out at home. SSH is LAN-only
already, so this is the second line: a compromised device on your network
guessing passwords, or the day somebody opens the SSH port.

## 5. Automatic security updates

`unattended-upgrades` with a daily refresh. This covers Debian packages, **not**
3x-ui or Xray, which are installed outside apt: those change only when you run
[`casavpn-upgrade`](UPGRADING.md).

## 6. Panel two-factor login

Cannot be automated: TOTP enrolment needs a QR scan. Panel > Settings > Security >
Two Factor Authentication > Enable, scan with an authenticator, and store the
recovery codes in a password manager (not on the phone that holds the TOTP seed).

Check: `sudo sqlite3 /etc/x-ui/x-ui.db "select key,value from settings where key='twoFactorEnable';"`
should print `twoFactorEnable|true`.

## 7. Unused services

On a headless Pi, disable what you do not use: `cups`, `cups-browsed`,
`bluetooth`, `ModemManager`, and **mask** `rpcbind` (its socket unit re-activates
it). `install.sh` does not touch these, since what is unused depends on your image.
`casavpn-healthcheck --local` fails if the panel ports are on a public interface,
and `ss -tlnp` shows the rest.

## Things deliberately left alone

- `avahi-daemon` (so `hostname.local` works): the firewall allows mDNS from the LAN only.
- `lightdm`/`wayvnc` on a desktop image: they do not listen on the network by
  default; disable them yourself if the Pi is truly headless.
