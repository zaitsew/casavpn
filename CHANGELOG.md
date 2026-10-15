# Changelog

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
