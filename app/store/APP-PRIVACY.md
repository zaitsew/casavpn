# App Store Connect answers: privacy, age rating, export compliance

Answers for the forms that the API cannot fill. Enter them once in App Store Connect
(App Privacy, App Information, and the build's export compliance). Keep this file in step
with the app: if the app starts to send anything to the developer, every answer below changes.

## App Privacy

**Answer: Data Not Collected.** Tracking: No.

Why. Apple counts data as "collected" when it leaves the device and the developer or a
partner can read it for longer than a live request needs. CasaVPN has no developer server and
no partner SDK. Each piece of data goes to a service that the user runs:

| Data | Where it goes | Collected by us? |
|---|---|---|
| Panel username, password, two-factor code | The user's own panel, over HTTPS. Stored in the iPhone Keychain. | No |
| Panel address, relay address and token | The Keychain and the user's own relay. | No |
| APNs device token (a device identifier) | The user's own relay, which sends the user's alerts. We cannot read it. | No |
| Server data (users, traffic, logs, alerts) | Shown on screen from the user's panel and relay. | No |
| Camera image of the pairing QR code | Decoded on the device, not stored or sent. | No |
| Demo mode sample data | Built into the app, no network. | No |
| Crash data, analytics, usage | Not gathered. Apple's own crash reports reach us only if the user shares them with developers. | No |

In the form:

1. "Do you or your third-party partners collect data from this app?" **No**.
2. Review the summary: it must read "Data Not Collected".
3. Privacy Policy URL: `https://zaitsew.github.io/casavpn/privacy` (also set by `scripts/store.py listing`).
4. Privacy Choices URL: leave empty.

Other items in the form and the build:

- Advertising identifier (IDFA): **No**. No ads, no ATT prompt. `usesIdfa` stays unset.
- `PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected data types,
  and the required-reason API `UserDefaults` (reason `CA92.1`). If the rewritten app uses
  another required-reason API (file timestamps, system boot time, disk space), add its
  category and reason there before the archive.
- Third-party SDKs: none, so no SDK privacy manifests are needed.

## Age rating

Expected result: **4+**. `scripts/store.py age-rating --apply` fills the questionnaire:

| Question | Answer |
|---|---|
| Violence (cartoon or fantasy, realistic, prolonged graphic), horror or fear themes | None |
| Sexual content or nudity, graphic sexual content | None |
| Profanity or crude humor | None |
| Alcohol, tobacco or drug use or references | None |
| Mature or suggestive themes | None |
| Simulated gambling, real gambling, contests | None / No |
| Medical or treatment information, health or wellness topics | None / No |
| Guns or other weapons | None |
| Unrestricted web access | No (the app opens only the user's own panel) |
| User-generated content, messaging and chat, social media | No |
| Advertising | No |
| Loot boxes | No |
| Parental controls, age assurance | No |

If a new question appears in App Store Connect that this table lacks, answer it "None" or
"No" only when that is true for the current build, and add a row here.

## Export compliance

`ITSAppUsesNonExemptEncryption` = `NO` in `app/CasaVPN/Supporting/Info.plist`, so App Store
Connect does not ask on each build.

Why it is exempt. The app uses encryption only through Apple's own networking and Keychain
APIs: HTTPS to the user's panel and relay (URLSession), and secure storage in the Keychain.
That is the standard-encryption exemption (it makes no custom, proprietary or non-standard
cryptography, and offers no VPN or encryption function to the user). No French declaration
is needed for the same reason.

Revisit this the day the app adds its own cryptography (for example a custom key exchange
or a local encrypted file format).

## Other declarations

| Item | Answer |
|---|---|
| Content rights ("third-party content") | Does not use third-party content (`scripts/store.py listing` sets it) |
| Primary category | Utilities (set by `listing`) |
| Price | Free |
| China mainland | Not available (`scripts/store.py availability`) |
| Sign in with Apple (guideline 4.8) | Not required: the app has no third-party or social login |
