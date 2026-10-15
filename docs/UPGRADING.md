# Upgrading

3x-ui (and the Xray core it bundles) is installed outside apt, so it changes only
when you decide. Debian packages update themselves
([HARDENING.md](HARDENING.md#5-automatic-security-updates)).

## The pin

[config/xui-release.env](../config/xui-release.env) names one release and its
SHA-256 per architecture. `install.sh` and `casavpn-upgrade` download that exact
tarball and **refuse** one whose hash differs. A newer 3x-ui therefore arrives as
a CasaVPN update (a commit changing both lines, after the maintainers read the
release notes), not behind your back.

If you want a release CasaVPN has not pinned yet:

- `--trust-release-sha` accepts the hash published next to the release. That proves
  the file matches the release page; it does not prove the release is good.
- `--offline-xui <tarball>` uses a file you downloaded yourself (still checked
  against the pin). The two flags are refused together: a hash fetched alongside a
  file you supplied would verify nothing.
- Or edit the two lines in `config/xui-release.env` yourself after verifying the
  hashes from the release page.

## Upgrade

```bash
cd casavpn && git pull          # get the new pin and tools
sudo casavpn-upgrade --dry-run  # show the plan
sudo casavpn-upgrade
```

In order, it: takes an encrypted backup (needs `AGE_RECIPIENT`), downloads and
verifies the tarball, stops x-ui, snapshots the database with `sqlite3 .backup`,
moves the installed tree to `/usr/local/x-ui.bak-<old version>`, installs the new
tree, starts x-ui and waits for the panel, **re-asserts `minClientVer` and the
loopback-only bindings** (an upgrade can rewrite them), and runs the local
healthcheck. If x-ui does not come up it rolls back by itself.

State for the rollback lives in `/var/lib/casavpn/upgrades/<stamp>/`
(`RECORD`, the database snapshot, the unit file) with a `latest` link.

## After every upgrade: test with an old client

> A newer Xray core can change what old clients can still do. A fresh client
> proves the server works; only an **old** one proves your users' devices still do.

From Xray 26.3.27 an empty `minClientVer` means "the server's own version", which
locks out every app whose bundled core is older. CasaVPN sets
`CASAVPN_MIN_CLIENT_VER` (default `1.8.0`) explicitly and re-applies it, but the
only real test is to connect once with the **oldest** client you support before you
close the terminal. See [RUNBOOK.md](RUNBOOK.md#playbook-3-every-client-stopped-working-after-an-upgrade).

## Roll back

```bash
sudo casavpn-rollback            # previous tree + the database snapshot taken just before
sudo casavpn-rollback --keep-db  # previous tree, current database (only if the old version can read it)
```

The default restores the database snapshot, because a newer panel may have
migrated it in a way the older one cannot read. The cost: a client you added after
the upgrade is gone. The tree being replaced is kept as
`/usr/local/x-ui.failed-<stamp>`.

## Cleaning up

The previous tree stays at `/usr/local/x-ui.bak-<version>` (about 200 MB on an SD
card). Delete it once you are happy: `sudo rm -rf /usr/local/x-ui.bak-<version>`.

## Rate limits and offline installs

GitHub rate-limits anonymous downloads. If the download fails with HTTP 429 or the
host cannot reach GitHub, fetch the tarball on your laptop, verify it against
`config/xui-release.env`, copy it to the Pi and run
`sudo casavpn-upgrade --offline-xui /path/to/x-ui-linux-<arch>.tar.gz`.

## Operating system upgrades

`apt full-upgrade` and distribution upgrades are yours. Take a
[backup](BACKUP.md) first, run `sudo nft -c -f /etc/nftables.conf` and
`sudo sshd -t` afterwards, reboot once while you are next to the machine, and run
`casavpn-healthcheck --local`.
