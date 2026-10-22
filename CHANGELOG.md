# Changelog

## Unreleased

### Added

- The `monitor/` Worker is now also the alert relay of [docs/APP.md](docs/APP.md). Its own
  transitions are alerts (`vpn.down` critical, `vpn.recovered` info): recorded once in a
  history in KV (one key per alert, 30 days) and pushed to the iPhone app through APNs (ES256 JWT signed with
  WebCrypto, cached 50 minutes). A new HTTPS API serves `POST`/`DELETE /v1/devices`,
  `GET /v1/alerts`, `POST /v1/events` (6-hour dedupe) and `POST /v1/test`, behind two
  bearer tokens (`APP_TOKEN`, `HOST_TOKEN`) compared in constant time.

- `app/`: the CasaVPN iPhone app (SwiftUI, iOS 17+, XcodeGen). Status, Clients, Alerts and
  Settings tabs as in `docs/APP.md`; pairing by `casavpn://pair` link or QR code; push
  registration with the relay. `CasaKit`, a UI-free Swift package, holds the pairing link
  parser, the Keychain store, the relay and 3x-ui panel clients and the formatting, with 69 unit
  tests that run on macOS (`app/check.sh`). The panel client is written against the 3x-ui
  v3.10.2 source; turning a client on or off is not yet verified against a live panel.

### Changed

- The Worker has a public URL now (`workers_dev = true`; every route needs a token).
  ntfy is optional (`NTFY_URL`) and a failure is logged instead of thrown; the monitor
  state also records `lastCheck` and `target`, written every run (288 KV writes a day).
  `monitor/README.md` and `docs/MONITORING.md` describe the relay setup and note that
  ntfy.sh answers 522 to Workers.

### Fixed

- `./check.sh` run by the pre-push hook from a linked worktree no longer lets the
  tests write into the real repository: git exports `GIT_DIR` to hooks there, which
  pointed `test-pii-scan.sh`'s throwaway repository at the real `.git` (its fixture
  `user.email` landed in `.git/config`). `check.sh` and the test unset the git
  environment; `tests/test-git-env.sh` guards it.

### Changed

- `tools/pii-scan.py` gains `ack-identity <commit>`: one reviewed, already published
  commit's author and committer are exempt, its message is still scanned. The
  allow-list accepts GitHub's merge-button text (`noreply@github.com`, "from
  <owner>/"). CONTRIBUTING documents merging locally instead of with the button.
- The Xray core is pinned separately from 3x-ui (`config/xray-core.env`: version
  v26.7.28 and a SHA-256 per architecture). After 3x-ui is in place, `install.sh` and
  `casavpn-upgrade` download the official `XTLS/Xray-core` zip, refuse a hash mismatch,
  check that the binary runs and reports the pinned version, and install it atomically
  over `bin/xray-linux-<arch>`; the bundled core is kept as `xray-linux-<arch>.bundled`.
  Why: Xray 26.10.10, bundled with 3x-ui 3.10.2, rejects Shadowrocket at the Reality
  handshake while Xray-based clients keep working.
- `casavpn-upgrade` re-applies the core pin after a panel upgrade, and also when the
  panel is already at the pinned version but the core differs (x-ui restarts once, the
  tree is not swapped). `casavpn-rollback` restores the old tree with the core it had.
- `CASAVPN_XRAY_CORE=bundled` opts out; `--offline-xray <zip>` installs a zip you
  downloaded yourself (still hash-checked).
- Docs: "The Xray core pin" and "Changing the Xray core" in `docs/UPGRADING.md`, the
  rule that every core change is tested with a non-Xray client on mobile data, and
  RUNBOOK Playbook 3b with the log line and a temporary info-logging recipe.

## 0.1.0 (first release)

The first public version, generalised from a private home deployment.

### Included

- `install.sh`: packages, 3x-ui (pinned by SHA-256), Let's Encrypt by DNS-01, nginx,
  key-only SSH, nftables, fail2ban, timers, unattended upgrades. `--dry-run`,
  `--show <config>`, `--skip-<step>`; never overwrites existing settings, database or
  credentials; keeps `<file>.pre-casavpn` copies.
- `casavpn-ddns`: dynamic-IP updater, four IP sources with quorum, read-back
  verification, ntfy alerts, pluggable provider (Cloudflare first).
- `casavpn-backup`, `pull-backups.sh`, `restore-drill.sh`: age-encrypted backups, a
  pull with a dead-man's switch, and a restore drill.
- `casavpn-upgrade`, `casavpn-rollback`, `casavpn-minver`: pinned upgrades with
  automatic rollback; the minimum client version is re-asserted.
- `casavpn-healthcheck` (host) and `scripts/healthcheck.sh` (remote).
- `gen-client-links.sh`, `cf-api.sh`, `dns-diff.sh`.
- `monitor/`: external uptime monitor on a Cloudflare Worker.
- `tools/pii-scan.py` and `check.sh`: the local gate (there is no CI).
- Documentation in `docs/`.
- `CASAVPN_REALITY_TARGET` has no default: `install.sh` and the settings validation refuse an empty value, the healthcheck needs `--sni` or the setting, and `docs/REALITY-TARGET.md` explains how to choose and check a site. The VPN port stays 443 by default and a different one is warned about.

### Fixed after the first review round

- The panel ACL denies the router's LAN address (`CASAVPN_LAN_GATEWAY`, detected from the
  default route) before allowing the LAN, so a VPN user cannot reach the panel by
  hairpinning through the router; the Xray panel-route example gains a matching
  blackhole guard (`docs/HARDENING.md`, "Hairpin NAT").
- The panel is opened by hostname (hosts entry or split DNS); the printed URL and the docs
  no longer send you to a bare LAN IP that fails the TLS handshake.
- `http2` is rendered as `listen ... ssl http2` for nginx older than 1.25.1.
- An existing `x-ui.db` without a credentials file is adopted (user name and base path read
  from it); a password that cannot be known is never invented or printed.
- `cloudflare.ini` is rewritten on every run with a token; fail2ban exempts loopback only
  (`CASAVPN_FAIL2BAN_IGNOREIP` adds more).
- `cf-api.sh` follows every page of DNS records; the healthcheck accepts `.tar.gz.age`
  backups and matches the camouflage certificate's names (SAN, one-label wildcards) instead
  of a substring; `pull-backups.sh` succeeds only for a non-empty local copy.
- Link generation: the renderer is found after install, only VLESS inbounds with an `id`
  are rendered, and the output file is created mode 0600 through a temp file.
- `casavpn-backup` fails (and prunes nothing) when a file cannot be copied; `casavpn-ddns`
  ignores proxy variables; `dns-diff.sh` asks the zone's real parent for the DS record;
  `pii-scan.py` checks file names with the generic rules and scans merge commits.

### Verified

- shellcheck-clean; offline tests for every script and for the scanner, run with
  fake system tools and no network or root.
- The 8 tests of the monitor's state machine.

### Not verified (read before you install)

- `install.sh` has **not** been run on a real Raspberry Pi or a clean Debian host.
  The generated nftables, nginx, sshd and fail2ban configurations are checked by
  tests that fake the tools, not by `nft -c`, `nginx -t` and `sshd -t` on a target.
- The 3x-ui command-line calls the installer relies on (`x-ui setting -username
  -password -port -webBasePath`, `x-ui migrate`, `x-ui -v`) and the settings keys it
  edits (`webListen`, `subListen`, `webPort`, `subPort`, `subEnable`) were written
  from the upstream project's documented behaviour, not exercised against the pinned
  release in this repository.
- The pinned 3x-ui release (v3.10.2) has not been field-tested; the deployment this
  was generalised from ran an older release.
- The tests ran on macOS only; no Linux host and no Raspberry Pi were used.
