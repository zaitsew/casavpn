# CasaVPN for iPhone

An iPhone app for a [CasaVPN](../README.md) server. It shows whether the VPN is up, lists
your clients (traffic, expiry, who is online), turns a client on or off, shares a client's
subscription link as text or QR code, and receives push alerts from the
[relay](../monitor). The design and the relay API are in [docs/APP.md](../docs/APP.md).

SwiftUI, iOS 17 or later, iPhone only. No analytics, no third-party code. The app talks only
to the 3x-ui panel and the relay that you set up.

## Quick start

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd app
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set your bundle id and team id
./generate.sh                                            # creates CasaVPN.xcodeproj (not committed)
open CasaVPN.xcodeproj                                   # run the CasaVPN scheme
```

`./check.sh` generates the project, runs the unit tests and builds the app. It needs no
simulator and no signing.

The bundle id must be one you own and must match the relay's `APNS_TOPIC` secret. Push
notifications need a real device and a signing team with the Push Notifications capability.

## Pairing

Open Settings and either scan the QR code that `sudo scripts/casavpn-pair` prints on the
server, or paste the `casavpn://pair?...` link. The app asks before it replaces anything.
Or type the five values: the panel URL and API token, the relay URL and app token, and the
subscription base URL. They are stored in the Keychain.

| Panel token | What works |
|---|---|
| admin | everything |
| monitor | the Status tab; the Clients tab says the token cannot list clients |

Create the token in the panel under Settings, API tokens. The panel answers only on your
home network, over the VPN or over Tailscale; away from those, the panel parts of the app say
so and the relay parts (VPN state, alerts) keep working.

## Layout

```
app/
  project.yml            XcodeGen spec (generated project is not committed)
  Config/                Base.xcconfig; Local.xcconfig (yours, ignored) from the .example
  CasaKit/               Swift package, no UI: pairing link, Keychain, relay and panel clients, formatting
  CasaVPN/               the app: SwiftUI views, the app model, entitlements, privacy manifest, icon
  tools/make-icon.swift  draws the app icon
```

## TestFlight

Archive the Release configuration with your own team. Release builds use the production APNs
environment and register with the relay as `production`; Debug builds use `sandbox`. A build is
done when it installs from TestFlight and the "Send test alert" button in Settings makes your
phone buzz. The first public release is the owner's call.
