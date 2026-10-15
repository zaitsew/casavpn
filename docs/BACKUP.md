# Backup and restore

The Pi boots from an SD card. When it dies, everything that makes the VPN yours
dies with it: the Reality private key and every client UUID live in one SQLite
file. Without a copy **off the Pi**, every client is re-provisioned by hand. This
page sets up the copy, proves it restores, and walks the restore.

```
 host   03:30  casavpn-backup.timer --> /usr/local/bin/casavpn-backup
                tar | zstd | age --> /var/backups/casavpn/casavpn-<UTC stamp>.tar.zst.age
                                          |  encrypted to a PUBLIC key; the newest 14 are kept
 laptop daily   scripts/pull-backups.sh ---+  (ssh/rsync, *.age files only; keeps 30; heartbeat)
 laptop monthly scripts/restore-drill.sh      (decrypt, integrity_check, counts; the host is untouched)
```

Only the **public** age key is on the host. Someone who steals the SD card, or
the copies on your laptop, learns nothing without the **identity** (private key),
which lives in your keychain and in one offline place (step 1).

What an archive holds: the panel DB (a consistent snapshot, WAL included), your
`casavpn.env` and panel credentials, `nftables.conf`, `sshd_config.d`, fail2ban
jails, nginx `sites-available`/`sites-enabled`/`conf.d`, `/etc/letsencrypt`, the
systemd units and `casavpn-*` scripts as installed, `MANIFEST` (3x-ui, Xray,
kernel, OS, DB checksum, what was captured and what was absent) and
`dpkg-selections.txt`.

It does **not** hold the 3x-ui/Xray binaries (the manifest names the version to
reinstall), your home directory, or the SSH host keys (clients of SSH will see a
new host key after a rebuild; that is fine).

## Setup (once, about 15 minutes)

### 1. Make the age key on your laptop

```bash
brew install age zstd        # or: apt install age zstd
umask 077 && mkdir -p ~/.config/casavpn
age-keygen -o ~/.config/casavpn/age-identity.txt
# prints "Public key: age1..."  <- this goes into casavpn.env as AGE_RECIPIENT; it is not secret
```

Keep the identity (the `AGE-SECRET-KEY-1...` line) **outside any repo**, in two
places:

- your password manager or OS keychain (day to day), and
- an **offline copy** (printed sheet, a note in a second password manager). If the
  laptop and the Pi die together and the key was only on the laptop, every backup
  is noise. This is the single point of failure that is easiest to forget.

### 2. Tell the host the public key

In `/etc/casavpn/casavpn.env` on the host:

```
AGE_RECIPIENT=age1...
CASAVPN_BACKUP_KEEP=14
CASAVPN_BACKUP_GROUP=pi        # optional: lets this user pull the encrypted archives without sudo
```

`install.sh` already installed `casavpn-backup` and the timer. Run the first
backup now rather than waiting for 03:30:

```bash
sudo systemctl start casavpn-backup.service
sudo journalctl -u casavpn-backup.service -n 20 --no-pager
sudo ls -l /var/backups/casavpn
```

Without `AGE_RECIPIENT` the script refuses to run (`--allow-plaintext` exists for
experiments and writes a `0600 root` file; never use it for real backups).

### 3. Pull the archives to another machine

A backup on the same SD card is not a backup. On your laptop:

```bash
export CASAVPN_SSH_TARGET=pi@<LAN_IP>
./scripts/pull-backups.sh
```

Schedule it daily. On macOS use the launchd template
[config/launchd/com.casavpn.pull-backups.plist](../config/launchd/com.casavpn.pull-backups.plist)
(instructions inside the file); on Linux a systemd user timer or cron entry that
runs the same command. The ssh key must work with no prompt
(`ssh -o BatchMode=yes pi@<LAN_IP> true`).

`pull-backups.sh` is also a **dead-man's switch**:

| Situation | Exit | Meaning |
|---|---|---|
| Host answers, newest backup older than 48 h (or none) | 2 | the nightly job stopped: `ssh pi@<LAN_IP> journalctl -u casavpn-backup.service` |
| Host answers, newest backup is empty or did not arrive | 2 | the job writes bad archives; an empty copy is removed and never counted as a pull |
| Host unreachable, newest local copy older than 7 days | 3 | you have not been home; connect and run it |
| Host unreachable, local copy newer than 7 days | 0 | warning only: a laptop is not always home |
| Fresh | 0 | writes `.last-pull` (the heartbeat) |

Tunables are environment variables (`CASAVPN_REMOTE_MAX_AGE_H`,
`CASAVPN_LOCAL_MAX_AGE_DAYS`, `CASAVPN_KEEP_LOCAL`, `CASAVPN_PULL_NTFY_URL`,
...; `./scripts/pull-backups.sh --help`). Pulling needs no age identity, and only
`*.age` files are ever copied.

### Prove it restores

A backup you have not restored is a hope. The drill decrypts the newest local
archive, unpacks it into a private temp directory and checks it, **without
touching the host**:

```bash
./scripts/restore-drill.sh --identity ~/.config/casavpn/age-identity.txt
# or without a file on disk:
./scripts/restore-drill.sh --identity <(security find-generic-password -s casavpn-age -w)
```

It verifies the manifest and the database checksum, runs `PRAGMA integrity_check`,
and prints the number of inbounds and clients, whether a Reality key exists, and
the 3x-ui/Xray versions. It never prints keys, UUIDs or passwords, and removes its
temp directory on exit. Run it now, then monthly. Anything but a pass: fix it
before you need it. The same chain is exercised offline, with a throwaway key and
a fake root, by `tests/test-backup.sh`.

## Restore onto a fresh SD card

Budget an hour. Work from your laptop. `ARCHIVE` is a file from your local backup
directory (default `~/.local/share/casavpn/backups`).

**0. Read the manifest first** (needs only the identity):

```bash
ARCHIVE=~/.local/share/casavpn/backups/casavpn-<stamp>.tar.zst.age
age -d -i ~/.config/casavpn/age-identity.txt "$ARCHIVE" | zstd -dc | tar -xOf - ./MANIFEST | grep -v '^included='
```

Note `xui_version`, `xray_version`, `os` and `created_utc`. (For a `.tar.gz.age`
use `gzip -dc`.)

**1. Prepare the Pi.** Flash the OS named in `os`. Create your admin user and put
your **public SSH key in its `authorized_keys` before anything else**: the home
directory is not in the backup, and the restored sshd hardening turns password
login off. Give the Pi its old LAN address back (the DHCP reservation) so the
router's port forwards still point at it. Then:

```bash
PI=pi@<LAN_IP>
ssh $PI 'sudo apt-get update && sudo apt-get install -y nginx nftables fail2ban certbot \
  python3-certbot-dns-cloudflare unattended-upgrades sqlite3 zstd age curl jq'
```

`dpkg-selections.txt` in the archive is the full package list, for anything else.

**2. Move the decrypted archive onto the Pi, into RAM only** (`/dev/shm` is a
tmpfs, so no key reaches the new SD card in clear):

```bash
age -d -i ~/.config/casavpn/age-identity.txt "$ARCHIVE" | zstd -dc \
  | ssh $PI 'umask 077; cat > /dev/shm/casavpn-restore.tar'
ssh -t $PI 'sudo install -d -m 0700 /dev/shm/casavpn-restore &&
  sudo tar -xpf /dev/shm/casavpn-restore.tar -C /dev/shm/casavpn-restore &&
  rm /dev/shm/casavpn-restore.tar && sudo ls /dev/shm/casavpn-restore'
```

**3. Install the same 3x-ui version as the manifest.** Not "latest": the Reality
settings and Xray's minimum-client behaviour depend on the core version. Check out
the CasaVPN release that pinned that version, or use `--offline-xui` with a tarball
of that version you downloaded yourself (and `--trust-release-sha` if it is not the
pinned one; read [UPGRADING.md](UPGRADING.md) first). The simplest way to get the
tree, systemd unit and tools in place without touching your restored data:

```bash
ssh $PI 'cd casavpn && sudo ./install.sh --skip-nginx --skip-ssh --skip-firewall --skip-certs --skip-fail2ban --skip-timers'
ssh -t $PI 'sudo systemctl stop x-ui; /usr/local/x-ui/x-ui -v'
```

This creates a throwaway database. The next step replaces it. The version printed
must match `xui_version`.

**4. Restore the database.** Remove stale WAL files so SQLite does not replay the
fresh install's journal over your data:

```bash
ssh -t $PI '
  set -e
  R=/dev/shm/casavpn-restore/rootfs
  sudo rm -f /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
  sudo cp -p $R/etc/x-ui/x-ui.db /etc/x-ui/x-ui.db
  sudo chmod 600 /etc/x-ui/x-ui.db
  sudo sqlite3 /etc/x-ui/x-ui.db "PRAGMA integrity_check;"      # must print: ok
'
```

**5. Restore the configuration.** Look at what the fresh install already activated
in nginx, because `sites-enabled` comes back as symlinks and a leftover `default`
site would fight your vhost:

```bash
ssh -t $PI 'ls -l /etc/nginx/sites-enabled; ls -l /dev/shm/casavpn-restore/rootfs/etc/nginx/sites-enabled'
```

Remove the fresh `default` link if it is not in your list. Then copy back
(if the manifest lists a path as `missing=`, drop its line). `-a` keeps ownership,
modes and symlinks (Let's Encrypt's `live/`, nginx's `sites-enabled/`):

```bash
ssh -t $PI '
  set -e
  R=/dev/shm/casavpn-restore/rootfs
  sudo cp -a $R/etc/casavpn /etc/
  sudo cp -a $R/etc/letsencrypt /etc/
  sudo cp -a $R/etc/nginx/. /etc/nginx/
  sudo cp -a $R/etc/nftables.conf /etc/nftables.conf
  sudo cp -a $R/etc/ssh/sshd_config.d/. /etc/ssh/sshd_config.d/
  sudo cp -a $R/etc/fail2ban/. /etc/fail2ban/
  sudo cp -a $R/etc/systemd/system/. /etc/systemd/system/
  sudo cp -a $R/usr/local/bin/. /usr/local/bin/
  sudo cp -a $R/usr/local/lib/casavpn/. /usr/local/lib/casavpn/
'
```

**6. Check each piece before starting it.** A broken `sshd` or `nftables` config
applied blind is how you lock yourself out of a headless box:

```bash
ssh -t $PI 'sudo nginx -t && sudo sshd -t && sudo nft -c -f /etc/nftables.conf && echo ALL OK'
```

**7. Start everything.**

```bash
ssh -t $PI '
  sudo systemctl daemon-reload
  sudo systemctl enable --now nftables fail2ban nginx x-ui casavpn-ddns.timer casavpn-backup.timer
  sudo systemctl restart ssh nginx
  sudo certbot renew --dry-run
'
CASAVPN_DOMAIN=vpn.example.com ./scripts/healthcheck.sh
```

**8. Check `minClientVer`.** If the Xray version you installed is newer than
`xray_version` in the manifest, an empty value makes the new core refuse older
phones while the server tests green. Run `sudo casavpn-minver` and test with an
**old** client ([RUNBOOK.md](RUNBOOK.md#playbook-3-every-client-stopped-working-after-an-upgrade)).

**9. Clean up and re-arm.**

```bash
ssh -t $PI 'sudo rm -rf /dev/shm/casavpn-restore; sudo systemctl start casavpn-backup.service'
```

Re-run `restore-drill.sh` against the fresh backup and confirm a client connects.
The database carries the same Reality key pair, short IDs and UUIDs, so **no client
link changes**. If the public IP moved while you rebuilt, `casavpn-ddns` repairs
DNS within a couple of minutes ([DYNAMIC-IP.md](DYNAMIC-IP.md)).

## When something is off

| Symptom | Look at |
|---|---|
| `pull-backups.sh` exits 2 | `ssh pi@<LAN_IP> 'systemctl status casavpn-backup.timer; journalctl -u casavpn-backup.service -n 50'` |
| Service fails with `AGE_RECIPIENT is not set` | the line is missing in `/etc/casavpn/casavpn.env` |
| Service fails with a sandbox error (`status=226/NAMESPACE`, read-only file system) | `ReadWritePaths=` in the unit must name existing directories; run `sudo casavpn-backup` by hand to separate sandbox from script problems |
| `cannot chgrp ... to pi` | `CASAVPN_BACKUP_GROUP` names a group that does not exist on the host |
| Drill: cannot decrypt | wrong identity, or a damaged copy: try the previous archive |
| Drill: database checksum does not match | altered or damaged in transit: run `pull-backups.sh` again, then the drill |
| Archive is `.tar.gz.age` | `zstd` was missing on the host: `apt install zstd` |

Never delete the previous archive by hand while you investigate. Retention only
runs after a new archive was written successfully.
