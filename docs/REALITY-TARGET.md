# Choosing a Reality target

`CASAVPN_REALITY_TARGET` is the real website your server imitates. Anyone who is
not a client (a scanner, a prober, a curious network) has their TLS handshake
relayed to that site and sees its genuine certificate. CasaVPN has **no default**
for it, and `install.sh` refuses to run until you set one.

## Why there is no default

A default is a fingerprint. If thousands of servers imitate the same few famous
sites, "a server in a residential range that answers like that site" becomes an
easy pattern to look for, and a handful of names (the big phone, desktop-software,
CDN and search companies) are the ones everybody picks first. Current Xray
releases say so themselves: at startup they log a warning that choosing such a
popular target, or listening on a port other than 443, raises the likelihood of
the server's IP being blocked. So choose your own, and keep the VPN on 443.

## What makes a good target

| Requirement | Why |
|---|---|
| Serves **TLS 1.3 and HTTP/2** on port 443 **directly** (the handshake itself, not a redirect from another host) | Reality copies a real handshake; the site must complete one with the properties your clients mimic |
| **Not** behind a mega-CDN that fingerprints or filters such traffic | The relay must look like the site would from your address |
| **Near your server**, network- and geography-wise | A handshake to a site that is far away or in a very different network stands out in timing and routing |
| **Not** one of the heavily used defaults (the large phone, desktop-software, CDN and search companies' main sites) | See above |
| Boring and stable: an ordinary organisation's site that is up all the time and unlikely to change its TLS setup | If it stops answering, so does your camouflage |
| Reachable **from the Pi** | The server dials it for every stranger |

A hostname only: `www.example.net`, not a URL. The examples here use reserved
names; they are not suggestions.

## Check a candidate

Run these from the Pi (or any machine on the same network as it).

```bash
CAND=www.example.net

# TLS 1.3 and HTTP/2 straight on 443 (look for "TLSv1.3" and "ALPN protocol: h2"):
echo | openssl s_client -connect "$CAND:443" -servername "$CAND" -tls1_3 -alpn h2 2>/dev/null \
  | grep -E 'Protocol|ALPN|Verify return code'

# It answers HTTP/2 directly and does not just redirect elsewhere:
curl -sI --http2 "https://$CAND/" -o /dev/null -w 'http=%{http_version} code=%{http_code} redirect=%{redirect_url}\n'
```

You want `TLSv1.3`, `ALPN protocol: h2`, `Verify return code: 0 (ok)`, `http=2`, and an
empty `redirect=` (a `200` is ideal; a redirect to the same host's own page is
tolerable, a redirect to another domain is not). Do it a few times at different
hours. Then check the round-trip is small and steady:

```bash
for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{time_connect} %{time_appconnect}\n' "https://$CAND/"; done
```

Compare with a site on the other side of the world; yours should be clearly closer.

## Set it, then verify it

1. Put it in `/etc/casavpn/casavpn.env`: `CASAVPN_REALITY_TARGET=www.example.net`.
2. `install.sh` prints it as the inbound's **Target** (`<site>:443`) and **SNI**. Use the
   same value in the panel.
3. After the router forward is in place, from outside:

```bash
CASAVPN_DOMAIN=vpn.example.com CASAVPN_REALITY_TARGET=www.example.net ./scripts/healthcheck.sh
# or: ./scripts/healthcheck.sh --host vpn.example.com --sni www.example.net
```

It confirms a probe on the VPN port is served the target's genuine certificate.
The healthcheck has no default either: without `--sni` or the setting it stops with
an error.

Changing the target later means changing it in the panel's inbound too (Target and
SNI, and the clients' SNI if they pinned one: regenerate with
`scripts/gen-client-links.sh`), then restarting x-ui.

## Keep the VPN port on 443

`CASAVPN_VPN_PORT` defaults to **443**, and you should leave it. Besides the
Xray warning above, port 443 is what a filter that only allows "web" ports lets
through, and a Reality server on an unusual port is a stronger signal than the
camouflage is worth. `install.sh` and the settings validation warn when it is not
443; it is still allowed (for example when something else must own 443 on that
address).

The router forward follows from it:

| External | Internal | What |
|---|---|---|
| **443** | 443 | the VPN (Reality) |
| 8443 | 8443 | client subscriptions (nginx) |

If you do change the VPN port, change the forward to match (and the healthcheck's
`--vpn-port`), and expect the Xray warning in `journalctl -u x-ui`.
