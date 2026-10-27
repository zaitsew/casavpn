# Upgrading

3x-ui and the Xray core it runs are installed outside apt, so they change only
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

## The Xray core pin

3x-ui bundles an Xray core, and a new 3x-ui brings a newer one. CasaVPN pins the
core separately, in [config/xray-core.env](../config/xray-core.env): a version and
a SHA-256 per architecture, taken from the official `XTLS/Xray-core` release (the
`.dgst` files, which match `gh release view <tag> -R XTLS/Xray-core --json assets`).
After 3x-ui is in place, `install.sh` and `casavpn-upgrade` download that zip,
**refuse** it on a hash mismatch, check that the binary runs and reports the pinned
version, and only then put it over `/usr/local/x-ui/bin/xray-linux-<arch>`.

- The swap is atomic (a `.new` file, then `mv -f`): a plain `cp` fails with "Text
  file busy" on a running binary.
- The core 3x-ui shipped is kept beside it as `xray-linux-<arch>.bundled`.
- The pin is re-applied after every panel upgrade, because the new tree arrives
  with its own core. When the panel is already at the pinned version,
  `casavpn-upgrade` still brings the core to the pin (x-ui restarts once, the tree
  is not swapped).
- `--offline-xray <zip>` uses a zip you downloaded yourself (still checked against
  the pin). There is no "trust the published hash" flag for the core: the point of
  the pin is that this exact core was tested.
- **Opt out** with `CASAVPN_XRAY_CORE=bundled` in `/etc/casavpn/casavpn.env`. The
  next `casavpn-upgrade` puts the bundled core back (from `.bundled`) and later
  upgrades keep whatever core the panel ships.

**Why it exists.** Xray 26.10.10, the core bundled with 3x-ui 3.10.2, refuses
Shadowrocket (iOS) at the Reality handshake while Xray-based clients keep working;
26.7.28 with the same 3x-ui does not. The cause inside 26.10.10 is not known, so the
pin stays until a newer core has passed the test below.

## Upgrade

```bash
cd casavpn && git pull          # get the new pin and tools
sudo casavpn-upgrade --dry-run  # show the plan
sudo casavpn-upgrade
```

In order, it: takes an encrypted backup (needs `AGE_RECIPIENT`), downloads and
verifies the tarball and the pinned Xray core zip, stops x-ui, snapshots the database with `sqlite3 .backup`,
moves the installed tree to `/usr/local/x-ui.bak-<old version>`, installs the new
tree and puts the pinned core over its bundled one, starts x-ui and waits for the panel, **re-asserts `minClientVer` and the
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

## Changing the Xray core

**The rule: after any core change, test a real non-Xray client on mobile data, not
only an old Xray client.** That covers a new 3x-ui release (it brings a new core),
a move of the pin, `CASAVPN_XRAY_CORE=bundled`, and a core switched in the panel.
Connect with Shadowrocket (iOS) over mobile data, not Wi-Fi (Wi-Fi can reach the
server through NAT loopback and hide a broken public path), and load a page. An old
Xray-based client passing proves nothing about it: on 2026-10-16 an old 26.2.6 client
worked against 26.10.10 while Shadowrocket was refused.

The failure looks like this in `journalctl -u x-ui` (or the Xray error log) and
nowhere else; the server's own checks and the healthcheck stay green:

```
REALITY: processed invalid connection from <ip>: authentication failed or validation criteria not met
```

If you see it after an upgrade, follow
[RUNBOOK.md, Playbook 3b](RUNBOOK.md#playbook-3b-shadowrocket-fails-after-an-upgrade-xray-clients-work).
To go to the **pinned** core: `git pull`, then `sudo casavpn-upgrade` (it re-applies
the pin even when the panel version matches). To go back to the **bundled** core
(the one that breaks Shadowrocket on 3x-ui 3.10.2, so only to compare): set
`CASAVPN_XRAY_CORE=bundled` and run `sudo casavpn-upgrade`, or copy it by hand, which
keeps the backup: `sudo cp -p /usr/local/x-ui/bin/xray-linux-<arch>.bundled
/usr/local/x-ui/bin/xray-linux-<arch>.new && sudo mv -f
/usr/local/x-ui/bin/xray-linux-<arch>.new /usr/local/x-ui/bin/xray-linux-<arch>`, then
`sudo systemctl restart x-ui`. If x-ui does not come back after a core-only change,
`casavpn-upgrade` puts the previous core back by itself and exits non-zero.

## Roll back

```bash
sudo casavpn-rollback            # previous tree + the database snapshot taken just before
sudo casavpn-rollback --keep-db  # previous tree, current database (only if the old version can read it)
```

The previous tree comes back with the core it had (and its `.bundled` copy). The
default restores the database snapshot, because a newer panel may have
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

Debian packages upgrade themselves. Two routines do it:

- **Daily:** unattended-upgrades installs security fixes. It never reboots.
- **Monthly:** `casavpn-os-upgrade.timer` runs `apt full-upgrade` on the first
  Sunday of the month at 04:30, reboots, and checks the VPN came back. The VPN is
  down for the reboot, about two minutes on a Raspberry Pi 5.

The monthly run, in order:

1. Preflight: `dpkg --audit` is clean, 1 GB free on `/`, 50 MB on the boot partition.
2. It records which units are active: ssh, nginx, x-ui, nftables, fail2ban, the
   CasaVPN timers, and `CASAVPN_OS_UPGRADE_UNITS`.
3. `apt-get update`, then a simulated `full-upgrade`. It stops with nothing changed
   when the plan removes any package, and sends a warning: a removal is your call.
   Run `sudo apt full-upgrade` by hand and read what it removes.
4. `apt-get full-upgrade --no-remove --force-confold`: config files we changed stay,
   and apt aborts rather than remove something the simulation did not show.
5. A reboot, when anything was upgraded or `/run/reboot-required` exists.
6. After the boot, `casavpn-os-upgrade-check.service` checks for up to 5 minutes:
   the units that were active are active again, the VPN port listens, an nftables
   ruleset is loaded, dpkg is clean, and DNS points at the host.

The result reaches the phone as `host.upgraded` (info) or `host.upgrade_failed`
(critical, naming what failed). It is also in `/var/lib/casavpn/os-upgrade-last`.
A failed upgrade does not reboot. If the host does not come back at all, the
external monitor sends `vpn.down` ([MONITORING.md](MONITORING.md)).

apt does not touch 3x-ui or the Xray core: they are not Debian packages. Move
those with `casavpn-upgrade` above.

```bash
sudo casavpn-os-upgrade --dry-run      # the plan from the current package lists; changes nothing
sudo systemctl start casavpn-os-upgrade.service   # run it now, reboot included
sudo casavpn-os-upgrade --no-reboot    # upgrade, check, no reboot
systemctl list-timers casavpn-os-upgrade.timer
journalctl -u casavpn-os-upgrade.service -u casavpn-os-upgrade-check.service -b -1
```

Move the window with `sudo systemctl edit casavpn-os-upgrade.timer` (an
`OnCalendar=` drop-in). Turn it off with `CASAVPN_OS_UPGRADE=off` in
`casavpn.env` and re-run `install.sh`. A missed window (the host was off) waits
for the next month: a catch-up run at boot would reboot at a random hour.

Distribution upgrades (Debian 13 to 14) stay yours. Take a [backup](BACKUP.md)
first, run `sudo nft -c -f /etc/nftables.conf` and `sudo sshd -t` afterwards,
reboot once while you are next to the machine, and run
`casavpn-healthcheck --local`.
