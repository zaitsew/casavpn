# casavpn-monitor: external uptime monitor

A Cloudflare Worker (free plan) that checks the VPN from outside the house every
5 minutes and pushes to your phone through [ntfy](https://ntfy.sh) when the state
changes. This is the "monitor 1" of [docs/MONITORING.md](../docs/MONITORING.md)
section 1, built on Cloudflare instead of UptimeRobot.

Every 5 minutes it:

1. resolves `vpn.example.com` through DNS-over-HTTPS (`cloudflare-dns.com`) and records the IP,
2. opens a TCP connection to `vpn.example.com:443` with `cloudflare:sockets`,
3. alerts **only on a state change**: **down** after 2 failures in a row (about 10
   minutes), **recovered** when the port answers again. No repeats while it stays down.

The down alert includes where DNS points, so "DNS has a stale IP" and "the Pi is
off" are told apart at a glance. State lives in one KV key (written only when it
changes, far under the free 1000 writes/day).

## Deploy (once, about 5 minutes)

First set `TARGET_HOST` (your `CASAVPN_DOMAIN`) and `TARGET_PORT` (your
`CASAVPN_VPN_PORT`) in `wrangler.toml`. The Worker refuses to run without a host.

```bash
cd monitor
npm install

npx wrangler login                          # opens the browser; the account is chosen here
npx wrangler kv namespace create STATE      # prints an id
```

Paste that id into `wrangler.toml` (`id = "REPLACE_WITH_KV_NAMESPACE_ID"`), then:

```bash
# Pick a long random topic. Anyone who knows an ntfy.sh topic can read and post to it.
openssl rand -hex 6                         # e.g. 3f9a1c0b7d2e
npx wrangler secret put NTFY_URL            # paste: https://ntfy.sh/casavpn-CHANGE-ME

npx wrangler deploy
```

No account id is committed anywhere; `wrangler login` supplies it.

## Subscribe on the iPhone

1. Install **ntfy** from the App Store.
2. Tap **+**, enter the topic (`casavpn-CHANGE-ME`), keep the default server `ntfy.sh`, **Subscribe**.
3. Allow notifications when iOS asks.

Test the phone side before trusting the monitor:

```bash
curl -d "casavpn monitor test" https://ntfy.sh/casavpn-CHANGE-ME
```

## Checking that it runs

```bash
npx wrangler tail                           # live logs; one JSON line per run
```

A healthy run logs `"ok":true,"status":"up","alert":null`. To exercise the alert
path without breaking the VPN, deploy once with `TARGET_PORT = "1"` (nothing listens
there): after two runs the phone gets "CasaVPN is DOWN". Set it back to `443`
and redeploy for the "recovered" message.

## Tests and types

```bash
npm test            # node --test: the state machine (src/transition.ts), Node 22.18+
npm run typecheck   # tsc against the Workers types
```

## Notes

- The Worker has no public URL (`workers_dev = false`): it only runs on the cron.
- If ntfy is unreachable when a state change happens, the old state is kept, so the
  next run reaches the same conclusion and tries again.
- `connect()` to a hostname that resolves to a Cloudflare address is refused by the
  platform; the VPN hostname is grey-cloud and points at the home IP, so this does not apply.
  If the Worker ever reports a failure with a "not allowed" error, check that the VPN
  hostname has not been switched to the orange cloud.
