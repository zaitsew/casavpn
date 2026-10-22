# casavpn-monitor: uptime monitor and alert relay

A Cloudflare Worker (free plan) with two jobs, described in
[docs/APP.md](../docs/APP.md):

1. **Monitor.** Every 5 minutes it checks the VPN from outside the house. This is
   the "monitor 1" of [docs/MONITORING.md](../docs/MONITORING.md) section 1, built on
   Cloudflare instead of UptimeRobot.
2. **Relay.** A small HTTPS API keeps the alert history and sends push
   notifications to the CasaVPN iPhone app through Apple's push service (APNs). The
   host scripts post their alerts to it too.

Every 5 minutes the monitor:

1. resolves `vpn.example.com` through DNS-over-HTTPS (`cloudflare-dns.com`) and records the IP,
2. opens a TCP connection to `vpn.example.com:443` with `cloudflare:sockets`,
3. alerts **only on a state change**: `vpn.down` (critical) after 2 failures in a row
   (about 10 minutes), `vpn.recovered` (info) when the port answers again. No repeats
   while it stays down.

The down alert includes where DNS points, so "DNS has a stale IP" and "the Pi is
off" are told apart at a glance. Each alert goes into the history in KV and to every
registered phone. ntfy is an optional extra channel (below).

## Deploy (once, about 10 minutes)

You need an Apple Developer account for the push key. First set `TARGET_HOST` (your
`CASAVPN_DOMAIN`) and `TARGET_PORT` (your `CASAVPN_VPN_PORT`) in `wrangler.toml`. The
Worker refuses to run without a host.

```bash
cd monitor
npm install

npx wrangler login                          # opens the browser; the account is chosen here
npx wrangler kv namespace create STATE      # prints an id
```

Paste that id into `wrangler.toml` (`id = "REPLACE_WITH_KV_NAMESPACE_ID"`). Create the
APNs key: Apple Developer → Certificates, Identifiers & Profiles → Keys → **+**, tick
**Apple Push Notifications service (APNs)**, download the `.p8` (Apple shows it once)
and note its Key ID. Then set the secrets:

| Secret | Value |
|---|---|
| `APP_TOKEN` | the app's bearer token: `openssl rand -hex 32` |
| `HOST_TOKEN` | the host scripts' bearer token: `openssl rand -hex 32` |
| `APNS_KEY_P8` | the text of the `.p8` file |
| `APNS_KEY_ID` | the key's 10-character id |
| `APNS_TEAM_ID` | your Apple team id |
| `APNS_TOPIC` | the app's bundle id |
| `NTFY_URL` | optional: an ntfy topic URL |

```bash
npx wrangler secret put APP_TOKEN
npx wrangler secret put HOST_TOKEN
npx wrangler secret put APNS_KEY_P8 < AuthKey_XXXXXXXXXX.p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_TOPIC

npx wrangler deploy                         # prints https://casavpn-monitor.<subdomain>.workers.dev
```

No account id is committed anywhere; `wrangler login` supplies it. Put the printed URL
and `HOST_TOKEN` in the host's `casavpn.env` as `CASAVPN_RELAY_URL` and
`CASAVPN_RELAY_TOKEN`; the app gets the URL and `APP_TOKEN` through `scripts/casavpn-pair`.

Without the `APNS_*` secrets the Worker still records alerts and answers the API; it
pushes nothing. Delete the `.p8` file from your disk or keep it in a password manager:
Apple cannot show it again.

## The API

Every request carries `Authorization: Bearer <token>`. A wrong token gets `401` and
an empty body. Bodies are JSON, at most 4 KB. Replace the URL and tokens below.

```bash
RELAY=https://casavpn-monitor.example.workers.dev
APP_TOKEN=app-token-placeholder
HOST_TOKEN=host-token-placeholder

# The app registers a device (token: 64 hex characters from iOS; environment
# "sandbox" for a debug build, "production" for TestFlight and the App Store).
curl -X POST "$RELAY/v1/devices" -H "Authorization: Bearer $APP_TOKEN" \
  -d '{"token":"<device token in hex>","environment":"production","name":"Phone"}'      # 204

# The app removes it.
curl -X DELETE "$RELAY/v1/devices/<device token in hex>" -H "Authorization: Bearer $APP_TOKEN"   # 204

# The app reads the history (newest first, limit 1-100, default 50) and the monitor state.
curl "$RELAY/v1/alerts?limit=20" -H "Authorization: Bearer $APP_TOKEN"                  # 200

# A host script posts an event. The same dedupe key is ignored for 6 hours.
curl -X POST "$RELAY/v1/events" -H "Authorization: Bearer $HOST_TOKEN" \
  -d '{"kind":"disk.low","severity":"warning","title":"Disk is 93% full","body":"/ is 93% full.","dedupe":"disk.low"}'
# 202 {"id":"...","pushed":1}    or    200 {"deduped":true}

# The app (or you) sends a test alert.
curl -X POST "$RELAY/v1/test" -H "Authorization: Bearer $APP_TOKEN"                     # 202
```

Event fields: `kind` (`[a-z._]{1,32}`), `severity` (`critical`, `warning`, `info`),
`title` (1-80 characters), `body` (0-400), `dedupe` (1-64, optional). Unknown fields
are refused with `400 {"error": "..."}`. `pushed` is the number of devices APNs
accepted the push for.

### Test a push

1. Open the app on the phone and allow notifications; it registers itself.
2. `curl -X POST "$RELAY/v1/test" -H "Authorization: Bearer $APP_TOKEN"`
3. The phone shows "Test alert" within seconds. If `pushed` is `0`, run
   `npx wrangler tail`: a line `{"apns":"rejected","status":403,"reason":"..."}` names
   Apple's reason (a wrong key id, team id or topic, or a sandbox/production mismatch).

To exercise the monitor path without breaking the VPN, deploy once with
`TARGET_PORT = "1"` (nothing listens there): after two runs the phone gets "CasaVPN is
down". Set it back to `443` and redeploy for the "recovered" alert.

## Checking that it runs

```bash
npx wrangler tail                           # live logs; one JSON line per run
```

A healthy run logs `"ok":true,"status":"up","alert":null`. `GET /v1/alerts` also
returns the monitor state with the time of the last check.

## ntfy (optional)

ntfy.sh answers `522` to requests from Cloudflare Workers, so with the default server
the Worker cannot post there. A self-hosted ntfy server works. If you have one:

```bash
npx wrangler secret put NTFY_URL            # paste: https://ntfy.example.com/casavpn-CHANGE-ME
```

The Worker's own alerts (`vpn.down`, `vpn.recovered`) are then posted there as well.
A failure is logged and never blocks anything. The host scripts have their own
`NTFY_URL` in `casavpn.env`.

## Tests and types

```bash
npm test            # node --test: relay API, APNs sender, state machine; Node 22.18+
npm run typecheck   # tsc against the Workers types
```

## Notes

- The Worker has a public URL (`workers_dev = true`); every route needs a bearer token.
  The two tokens are different, so a leaked host token cannot read the history.
- Storage is one KV namespace: `devices`, `alert:<key>` (one key per alert, 30-day
  expiry; the app reads the newest 100), `dedupe:<key>` (6-hour expiry, best effort) and `state`. The monitor writes `state` every run (288 a day) so the app can
  show the time of the last check; the free plan allows 1,000 writes a day.
- A push that fails is not retried; the alert stays in the history.
- If the state write fails after a transition, the next run reaches the same
  transition and finds it already recorded, so the alert is neither lost nor doubled.
- `connect()` to a hostname that resolves to a Cloudflare address is refused by the
  platform; the VPN hostname is grey-cloud and points at the home IP, so this does not apply.
  If the Worker ever reports a failure with a "not allowed" error, check that the VPN
  hostname has not been switched to the orange cloud.
