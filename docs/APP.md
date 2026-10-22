# The CasaVPN iPhone app and its alert relay

The app shows the server's state and its clients, and receives push alerts. It
talks to two things:

- **The 3x-ui panel**, through the panel's own API with a revocable API token.
  The panel stays closed to the internet, so this part works only from the LAN,
  over the VPN itself, or over Tailscale ([HARDENING.md](HARDENING.md)).
- **The relay**: the monitor Worker in [`monitor/`](../monitor), which also gets
  a small HTTPS API. It keeps the alert history and sends push notifications
  through Apple's push service (APNs). It runs on Cloudflare, so alerts arrive
  even when the house is offline.

```
 iPhone app ──(LAN / VPN / Tailscale)──▶ 3x-ui panel API  (status, clients)
     │  ▲
     │  └──── APNs push ◀──┐
     └──▶ relay API ───────┤  Cloudflare Worker: cron probe + alert history
                           │
 host: casavpn-ddns, ──────┘  POST /v1/events
       casavpn-alerts
```

Why a relay and not ntfy: ntfy.sh answers 522 to requests from Cloudflare
Workers, so the Worker cannot use it. APNs accepts them (checked 2026-10-22).
ntfy stays an optional second channel for the host scripts.

## Alerts

| kind | severity | from | when |
|---|---|---|---|
| `vpn.down` | critical | Worker | the VPN port fails two checks in a row |
| `vpn.recovered` | info | Worker | it answers again |
| `ip.changed` | warning | `casavpn-ddns` | the public IP changed and DNS was repaired |
| `ddns.failed` | critical | `casavpn-ddns` | three runs in a row could not update DNS |
| `cert.expiring` | warning, critical under 3 days | `casavpn-alerts` | the web certificate expires in under 14 days |
| `client.traffic` | warning at 90 %, critical at 100 % | `casavpn-alerts` | a client with a traffic limit nears or hits it |
| `client.expiring` | warning, critical once expired | `casavpn-alerts` | a client with an expiry date has under 3 days left |
| `xray.down` | critical | `casavpn-alerts` | the VPN port does not listen on the host while x-ui runs |
| `backup.stale` | warning | `casavpn-alerts` | the newest backup is older than 36 h |
| `disk.low` | warning | `casavpn-alerts` | the root filesystem is over 90 % full |
| `host.rebooted` | info | `casavpn-alerts` | the host booted since the last run |
| `test` | info | app | the user pressed "Send test alert" |

Critical alerts are delivered as time-sensitive notifications.

## Relay API

Base URL: the Worker's URL (`https://casavpn-monitor.<subdomain>.workers.dev`).
Every request carries `Authorization: Bearer <token>`. There are two tokens,
both Worker secrets, compared in constant time:

- `APP_TOKEN`: the app. Registers devices, reads alerts, sends a test.
- `HOST_TOKEN`: the host scripts. Posts events.

A wrong or missing token gets `401` with no body. Bodies are JSON and at most 4 KB.

| Method and path | Token | Body | Answer |
|---|---|---|---|
| `POST /v1/devices` | app | `{"token": "<hex>", "environment": "sandbox" \| "production", "name": "<≤40 chars>"}` | `204`. At most 10 devices; the oldest is dropped. |
| `DELETE /v1/devices/<hex>` | app | — | `204` |
| `GET /v1/alerts?limit=50` | app | — | `200 {"alerts": [Alert], "monitor": Monitor}` newest first, `limit` 1–100 |
| `POST /v1/events` | host | `Event` | `202 {"id": "...", "pushed": <devices>}`, or `200 {"deduped": true}` |
| `POST /v1/test` | app | — | `202 {"id": "...", "pushed": <devices>}` |

```
Event   {"kind": "<a-z . _>{1,32}", "severity": "critical" | "warning" | "info",
         "title": "<≤80 chars>", "body": "<≤400 chars>",
         "dedupe": "<≤64 chars, optional>"}
Alert   Event without dedupe, plus {"id": "<sortable id>", "at": "<ISO 8601>",
         "source": "monitor" | "host" | "app"}
Monitor {"status": "up" | "down" | "unknown", "since": "<ISO>",
         "lastCheck": "<ISO>", "ip": "<IPv4 or null>", "target": "host:port"}
```

`dedupe`: an event whose key was seen in the last 6 hours is stored nowhere and
pushed to nobody. The host scripts use it so a condition that lasts does not
alert every run (for example `cert.expiring:2026-12-30`, `client.traffic:alice:90`).

Storage, in the existing KV namespace: `devices` (one JSON array), `alerts` (the
newest 100), `dedupe:<key>` (with a 6-hour TTL), and the monitor's `state`.
Writes happen only when something changes, far under the free plan's 1,000 a day.

### Push

Worker secrets `APNS_KEY_P8` (the `.p8` file's text), `APNS_KEY_ID`,
`APNS_TEAM_ID`, `APNS_TOPIC` (the app's bundle id). The relay signs an ES256 JWT
with WebCrypto and reuses it for 50 minutes. A device registered as `sandbox`
(a debug build) is sent to `api.sandbox.push.apple.com`, any other to
`api.push.apple.com` (TestFlight and App Store builds). A device that APNs answers
with `410` or `400 BadDeviceToken` is removed.

```
{"aps": {"alert": {"title": "...", "body": "..."}, "sound": "default",
         "thread-id": "<kind before the first dot>",
         "interruption-level": "time-sensitive" | "active"},
 "alertId": "<id>", "kind": "<kind>"}
```

A push that fails is not retried; the alert stays in the history, and the app
shows the history when it opens. When no APNs secrets are set, the relay stores
alerts and pushes nothing. When `NTFY_URL` is set, the Worker's own alerts also
go there; an ntfy failure is logged and never blocks the state change.

## The app

SwiftUI, iPhone, iOS 17 or later. The project is generated by XcodeGen from
`app/project.yml`. The bundle id and the team id come from
`app/Config/Local.xcconfig`, which is not committed (copy
`Local.xcconfig.example`).

| Tab | Shows | Source |
|---|---|---|
| Status | VPN up or down since when, public IP, last check; Xray state and version, CPU, memory, disk, uptime | relay; panel |
| Clients | each client: on or off, online now, traffic used of its limit, expiry; share the subscription link as text or QR; turn a client on or off | panel |
| Alerts | the history, newest first; a push opens its alert | relay |
| Settings | connection details, push on or off, "Send test alert" | — |

When the panel cannot be reached, the panel parts say so ("The panel answers
only on the home network, over the VPN or over Tailscale") and the relay parts
keep working.

Connection details: the panel URL (`https://vpn.example.com:8443/<base path>`),
a panel API token, the relay URL, the app token, and the subscription base URL
(`https://vpn.example.com:8443/sub/`). All five go into the Keychain, never into
`UserDefaults`. They can be typed, pasted, or scanned as one QR code:

```
casavpn://pair?panel=<url>&panelToken=<token>&relay=<url>&relayToken=<token>&sub=<url>
```

`scripts/casavpn-pair` prints that QR on the host's terminal.

Panel token scope: an **admin** token unlocks everything; a **monitor** token
gives the Status tab only (the Clients tab then says the token cannot list clients).
Create it in the panel under Settings → API tokens.

No analytics, no third-party SDKs. The app sends data only to the panel and the
relay you configure.

## Setup

1. Apple Developer → Certificates, Identifiers & Profiles → Keys → **+**, tick
   **Apple Push Notifications service (APNs)**, download the `.p8` (once only).
   Note its Key ID.
2. In `monitor/`: `npx wrangler secret put` each of `APP_TOKEN`, `HOST_TOKEN`
   (`openssl rand -hex 32` each), `APNS_KEY_P8` (`< AuthKey_XXXX.p8`),
   `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`; then `npx wrangler deploy`.
3. On the host: put `CASAVPN_RELAY_URL` and `CASAVPN_RELAY_TOKEN` (the host token)
   in `casavpn.env`; run `sudo scripts/casavpn-pair` and scan the code in the app.
