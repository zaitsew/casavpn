---
title: CasaVPN Privacy Policy
---

# CasaVPN Privacy Policy

Effective 22 October 2026.

**Short version: CasaVPN collects nothing for the developer.** There is no CasaVPN account,
no CasaVPN server, no analytics, no advertising and no tracking. The app talks only to the
two services that you set up yourself.

## What the app is

CasaVPN is an admin console for a VPN server that you own. It is not a VPN service and it
does not route your traffic. The server is yours, so the data on it is yours.

## Who the app talks to

| Service | Who runs it | What the app sends |
|---|---|---|
| Your panel (a 3x-ui panel on your server) | You | Your panel username, password and two-factor code, to sign in. Then the commands you give: list, add, edit or delete a user, reset traffic, restart the VPN core, read logs. |
| Your relay (a small service you deploy yourself) | You | Your relay's access token and your iPhone's push token, so the relay can send you alerts. |
| Apple Push Notification service | Apple | Nothing from the app directly. Your relay sends alerts to your iPhone through Apple's push service, under [Apple's privacy policy](https://www.apple.com/legal/privacy/). |

The app sends nothing to the developer or to any other server. It contains no third-party
SDKs.

## What is stored, and where

- **On your iPhone, in the Keychain:** your panel address and credentials and your relay
  address and token. They never leave the device except to reach the service they belong to.
  Deleting the app removes them.
- **On your iPhone, in app storage:** settings such as which server is selected.
- **On your own relay:** your iPhone's push (APNs) device token, and the alert history your
  server sent (for example "a user ran out of traffic"). The relay is yours, and you control
  and can delete this data. The developer cannot see it.
- **Demo mode:** shows sample data built into the app. It makes no network requests to any
  server.

## Permissions

- **Notifications:** to show alerts from your relay. Optional.
- **Camera:** only to scan the pairing QR code that your own server shows. The image is
  processed on the device and is not stored or sent. Optional.

## What we do not do

No analytics. No advertising. No tracking and no data sold or shared. No profile of you is
built. The app does not use the advertising identifier.

## Children

CasaVPN is a tool for people who run servers. It is not directed at children and collects no
data from anyone.

## Open source

The app, the relay and the server scripts are open source, so you can check these
statements in the code: [github.com/zaitsew/casavpn](https://github.com/zaitsew/casavpn).

## Changes

If this policy changes, the new text is published on this page with a new effective date.

## Contact

Open an issue at [github.com/zaitsew/casavpn/issues](https://github.com/zaitsew/casavpn/issues).
Issues are public: do not post passwords, tokens or server addresses there. See also
[Support](support).
