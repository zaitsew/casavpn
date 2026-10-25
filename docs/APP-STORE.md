# App Store release

How the CasaVPN iPhone app reaches the App Store, and the checklist to pass review the
first time. The listing text, review notes and answers live in [`app/store/`](../app/store);
`scripts/store.py` pushes them to App Store Connect.

| | |
|---|---|
| App Store Connect app id | 6825758776 |
| Name, SKU | CasaVPN, `casavpn` |
| Bundle id | `com.casavpn.CasaVPN` |
| Seller | an organization account (the LLC), not an individual |
| Platform | iPhone only. `TARGETED_DEVICE_FAMILY` is `"1"` in `app/project.yml`, so no iPad build and no iPad screenshots. |
| Category, price | Utilities, free |
| Privacy policy, support | `https://zaitsew.github.io/casavpn/privacy`, `.../support` (GitHub Pages, branch `main`, folder `/docs`) |

## Files

| File | Used for |
|---|---|
| `app/store/metadata/en-US/*.txt` | name, subtitle, promotional text, description, keywords, release notes, URLs |
| `app/store/review_notes.txt` | the App Review notes (demo mode, push, China, encryption, naming) |
| `app/store/contact.local.json` | the reviewer contact and the copyright line. Untracked and git-ignored; copy `contact.example.json` and fill it in. |
| `app/store/APP-PRIVACY.md` | answers for App Privacy, age rating and export compliance |

## Commands

Every command is a dry run until you add `--apply`. Credentials come from
`~/ops/bin/testflight` (the API key in `~/.appstoreconnect/`).

```sh
scripts/store.py lint              # offline: length limits, keywords, no provider names, 3x-ui rules
scripts/store.py check             # read-only: everything still missing before "Submit for Review"
scripts/store.py availability      # every territory except China mainland     (--apply)
scripts/store.py listing           # name, subtitle, privacy URL, category, description, keywords, ...  (--apply)
scripts/store.py review            # review notes + reviewer contact           (--apply)
scripts/store.py age-rating        # the age-rating questionnaire, all "none"  (--apply)
```

Order for the first release: `availability`, `age-rating`, `listing`, `review`, then `check`
until it prints `0 item(s) missing`. "What's New" is skipped on a first release: Apple does not
take it. `release_notes.txt` is used from 1.1 on.

## Upload a build

```sh
# 1. In app/project.yml: MARKETING_VERSION must equal the store version (1.0);
#    raise CURRENT_PROJECT_VERSION by one per upload.
app/check.sh
app/generate.sh
~/ops/bin/testflight release --project app/CasaVPN.xcodeproj --scheme CasaVPN \
    --bundle-id com.casavpn.CasaVPN
```

In App Store Connect, open the version, choose the processed build, and check that
`scripts/store.py check` shows it attached. Build 1 (uploaded 2026-10-22) is for version 0.1.0 and
cannot go into version 1.0.

## Checklist before every submission (POLICY section 15)

- [ ] **China mainland off.** `scripts/store.py availability --apply`. Reason: VPN-related
      management tools need a licence and an ICP filing there. One setting covers every build.
- [ ] **No model provider named** in the name, subtitle, description, keywords, What's New or
      screenshots. `lint` enforces it for the text.
- [ ] **The reviewer can reach every feature.** There is no account, so demo mode is the way in:
      "Try demo mode" on the first screen, and "Send test alert" in Settings. Both are in
      `review_notes.txt`; the build must match those words.
- [ ] **No sign-in wall.** The first screen offers demo mode; nothing is paywalled; no waitlist,
      no region lock, no bring-your-own-key (3.1.1).
- [ ] **Declared capabilities work in the first minute.** Push notifications (aps-environment
      entitlement, test alert in demo mode) and the camera (pairing QR scan, with its usage text).
- [ ] **Listing complete.** Screenshots, age rating, App Privacy, export compliance, support and
      privacy URLs live, copyright, category, price, content rights.
- [ ] **iPhone only says so on the target.** `TARGETED_DEVICE_FAMILY: "1"` on the target (checked
      by `store.py check`).
- [ ] **Screenshots**: iPhone 6.9" display (1320 x 2868, or 1290 x 2796) and 6.5" display
      (1284 x 2778, or 1242 x 2688), portrait, 1 to 10 each, taken from demo mode. No iPad set.
- [ ] **Review notes** say what a reviewer would ask: demo mode, why no account, where push is seen,
      why China is off, encryption, the 3x-ui naming choice.
- [ ] **A cross-provider review** of the final build (`~/ops/bin/codex-review`) before submit.

## Where review may push back

| Guideline | Risk | Answer in the listing and the notes |
|---|---|---|
| 5.4 VPN apps | "VPN" in the name; the app manages a VPN. A reviewer may think it is a VPN client. | The description and notes say it is an admin console, not a VPN service; it uses no NetworkExtension and routes nothing. The seller is an organization anyway. |
| 2.1 VPN questionnaire | Apple's automated analysis flags "VPN functionality" and rejects until three questions are answered (1.0.0, 2026-10-25). | `review_notes.txt` answers them under "VPN QUESTIONS"; the same answers go in the reply to App Review. |
| 4.2 Minimum functionality | An app that needs your own server may look empty. | Demo mode shows every screen with sample data. |
| 2.1 App completeness | The reviewer has no server or account. | Demo mode; no account exists. |
| 5.2.1 / 2.3.7 Third-party names | "3x-ui" in the description. | Named once, as compatibility. Not in the name, subtitle or keywords. "Xray" is not used. |
| 5.1.1 Privacy | Camera and notification prompts. | Usage text states the purpose; both are optional. |

## Needs the website (the API has no endpoint)

- App Privacy: "Data Not Collected", then Publish ([`app/store/APP-PRIVACY.md`](../app/store/APP-PRIVACY.md)).
- Digital Services Act trader status for the EU storefronts (the LLC's address, phone and e-mail
  are shown publicly on the EU listing).
- Choose the build for the version, and set Pricing to Free (the price schedule is set there).
- GitHub Pages for this repo: Settings, Pages, branch `main`, folder `/docs`.
- "Add for Review" and "Submit for Review". The first public release is the owner's call.
- After a rejection: reply on the App Review page, then open the version and click "Update Review"; only then is "Resubmit to App Review" enabled.

## Rejection log

One row per rejection, in the session that meets it. The reason text is only on the App Review
page in App Store Connect (the e-mail and the API carry none). When a rejection is a new class,
add a bullet to POLICY section 15.

| Date | Version (build) | Guideline | Reason, verbatim | Cause | Fix |
|---|---|---|---|---|---|
| 2026-10-25 | 1.0.0 (2) | 2.1.0 Performance: App Completeness | "An automated analysis indicates the app contains VPN functionality." Apple asks what user information the app collects using VPN, for what purposes, and whether it is shared with third parties, in a reply and in the App Review Information section. | The review notes said the app is not a VPN client, but did not answer Apple's three VPN questions. | Answers added to `review_notes.txt` ("VPN QUESTIONS"), pushed with `store.py review --apply`, the same answers sent as the reply; build 2 resubmitted unchanged. |
