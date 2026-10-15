# Clients

Creating identities, getting a device connected, and the DNS setting that keeps
profiles working through an IP change.

## One identity per person

Each client has its own UUID, so a single device can be revoked without touching
the others. Keep it that way: do not share one identity between two people, and
add a new client in the panel rather than reusing one. Name them by person and
device (`alice-phone`, `bob-tv`); the name appears in the client's profile list.
Traffic is metered per identity in the panel.

## Getting a client connected

Prefer the subscription; use a direct link as a fallback.

### Subscription (preferred)

The panel serves a per-client URL, and the app re-fetches it periodically, so
server-side changes reach the device without you resending anything:

```
https://vpn.example.com:8443/sub/<SUB_ID>
```

Find `<SUB_ID>` in the panel (client details), or on the host:

```bash
sudo sqlite3 /etc/x-ui/x-ui.db "select settings from inbounds;" \
  | python3 -c "import sys,json;[print(c['email'],c.get('subId')) for l in sys.stdin for c in json.loads(l)['clients']]"
```

In the app: add subscription, paste the URL, refresh.

### Direct link

```bash
./scripts/gen-client-links.sh                    # hostname-based (normal)
./scripts/gen-client-links.sh 203.0.113.10       # IP-based (outage workaround)
```

Reads the live database (over SSH with `CASAVPN_SSH_TARGET`, or `--local` on the
host) and writes `CLIENT-LINKS.local.txt` (mode 600, git-ignored). **These links
are credentials.** Send them through a password manager or an end-to-end encrypted
messenger, never plain e-mail or a group chat.

### Which app

Any client that speaks VLESS + Reality with `xtls-rprx-vision`:

| Platform | Examples |
|---|---|
| iOS / macOS | Shadowrocket, Streisand, V2Box |
| Android | v2rayNG, NekoBox |
| Windows / Linux | v2rayN, Nekoray |

Apps change; the Reality parameters in [ARCHITECTURE.md](ARCHITECTURE.md) are what
matter. Clients older than `CASAVPN_MIN_CLIENT_VER` (an Xray version) are refused:
if someone cannot connect, update their app first.

---

## The DNS setting, and who needs it

Profiles point at a hostname. Before a client can connect, the device must resolve
it using the **operating system's** resolver, not anything inside the VPN app,
because the tunnel does not exist yet.

After an IP change, some ISP resolvers keep serving the old address long after the
record is fixed and past its TTL, in one real incident for over 45 minutes. A
device stuck on such a resolver stays broken while the server is healthy.

- **Devices on the home Wi-Fi (the ISP's own resolver): worth doing.** It is the fix
  that unblocks them.
- **Remote users on other networks: optional.** Most large resolvers honour the
  TTL and recover by themselves.

Check whether a device is affected:

```bash
dig +short vpn.example.com @1.1.1.1     # the truth
dig +short vpn.example.com              # what this device believes
```

Different answers: that device's resolver is stale.

### iOS / iPadOS

Per network, so repeat it for each Wi-Fi network that matters. Settings > Wi-Fi >
(i) next to the network > Configure DNS > Manual > remove the existing servers >
Add Server `1.1.1.1`, then `1.0.0.1` > Save. Toggle airplane mode for five seconds
to flush the cache.

Do not install a second VPN app (such as a DNS or WARP app) for this: iOS allows one
VPN profile at a time. Changing DNS *inside* the VPN app does not help either, as
that setting applies through the tunnel.

### Android

System-wide and works on mobile data too: Settings > Network & internet > Private
DNS > hostname `one.one.one.one`.

### macOS

```bash
sudo networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
# undo: sudo networksetup -setdnsservers Wi-Fi empty
```

### Windows

Settings > Network & Internet > (adapter) > Edit DNS settings > Manual > IPv4 on >
Preferred `1.1.1.1`, Alternate `1.0.0.1`; then `ipconfig /flushdns`.

### The whole house at once

Set `1.1.1.1` and `1.0.0.1` as the DNS servers your router hands out over DHCP.
Some ISP-supplied routers do not allow it.

---

## Routing modes in client apps

Many apps have a global routing mode. In a rule-based ("config") mode a broken
server produces a confusing partial failure: domains matching a `DIRECT` rule keep
working while everything matching `PROXY` fails, which reads as "the internet works
but no website opens". **When diagnosing, switch to the plain "proxy everything"
mode first.** If it works there, the server is fine and the problem is in the rules
or in name resolution.

## When a client cannot connect

Cheapest check first:

1. Is it just this device? If others work, it is local: DNS cache or routing mode.
2. Is DNS right? `dig +short vpn.example.com @1.1.1.1` versus the device's answer.
3. Is the server up? `./scripts/healthcheck.sh` from your laptop.
4. Is the app new enough for `CASAVPN_MIN_CLIENT_VER`?
5. Emergency: the IP-based profile below.

More in [RUNBOOK.md](RUNBOOK.md).

### Keep an emergency profile

Generate one IP-based profile per client and have each person import it *alongside*
the normal one, disabled until needed:

```bash
./scripts/gen-client-links.sh "$(dig +short vpn.example.com @1.1.1.1 | tail -1)"
```

It stops working at the next IP change, which is the point: it is the fallback
while DNS catches up. Refresh it whenever the address changes.
