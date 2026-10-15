#!/usr/bin/env bash
#
# restore-drill.sh — prove the newest backup can actually be restored, without
# touching the VPN host. Run on your laptop, now and then (monthly is plenty).
#
# It decrypts the newest archive with your age identity, unpacks it into a
# private temp directory, then checks:
#   - the archive decrypts and unpacks, and holds no path that escapes the dir
#   - MANIFEST is present, well formed, and its db_sha256 matches the database
#   - the sqlite database passes PRAGMA integrity_check
#   - it contains inbounds, clients, and a Reality private key
#   - the config files the restore procedure needs are there
# and prints COUNTS and versions only. Keys, UUIDs and passwords are never
# printed. The temp directory is removed on exit.
#
# Usage:
#   restore-drill.sh --identity ~/.config/casavpn/age-identity.txt
#   restore-drill.sh --identity <(security find-generic-password -s casavpn-age -w)
#   restore-drill.sh --archive path/to/casavpn-...age --identity FILE
#
# Environment (flags win):
#   CASAVPN_AGE_IDENTITY   age identity file (or a /dev/fd path from <(...))
#   CASAVPN_BACKUP_LOCAL   directory holding the archives
#                          (default: ${XDG_DATA_HOME:-~/.local/share}/casavpn/backups)
#
# Exit status: 0 = restorable; 1 = a check failed; 64 = usage error.

set -euo pipefail
umask 077

IDENTITY="${CASAVPN_AGE_IDENTITY:-}"
DIR="${CASAVPN_BACKUP_LOCAL:-${XDG_DATA_HOME:-$HOME/.local/share}/casavpn/backups}"
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --archive)  ARCHIVE="${2:-}"; shift 2 ;;
    --dir)      DIR="${2:-}"; shift 2 ;;
    -h|--help)  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 64 ;;
  esac
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*"; }
ok()   { printf 'ok    %s\n' "$*"; }

[[ -n "$IDENTITY" ]] || { echo "no age identity: pass --identity FILE or set CASAVPN_AGE_IDENTITY" >&2; exit 64; }
[[ -r "$IDENTITY" ]] || { echo "cannot read identity: $IDENTITY" >&2; exit 64; }
for tool in age sqlite3 tar; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed (brew install $tool)" >&2; exit 64; }
done

if [[ -z "$ARCHIVE" ]]; then
  # Names carry a UTC timestamp: the last one in sort order is the newest.
  for f in "$DIR"/casavpn-*.age; do
    if [[ -e "$f" ]]; then ARCHIVE="$f"; fi
  done
  [[ -n "$ARCHIVE" ]] || fail "no casavpn-*.age archives in $DIR (run scripts/pull-backups.sh first)"
fi
[[ -f "$ARCHIVE" ]] || fail "archive not found: $ARCHIVE"

case "$ARCHIVE" in
  *.tar.zst.age)
    command -v zstd >/dev/null || { echo "zstd is required to read a .tar.zst.age archive and is not installed: brew install zstd" >&2; exit 64; }
    DECOMPRESS=(zstd -dc) ;;
  *.tar.gz.age)  DECOMPRESS=(gzip -dc) ;;
  *) fail "unrecognised archive name (expected .tar.zst.age or .tar.gz.age): $ARCHIVE" ;;
esac
command -v "${DECOMPRESS[0]}" >/dev/null || { echo "${DECOMPRESS[0]} is not installed" >&2; exit 64; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/casavpn-drill.XXXXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "archive: $(basename "$ARCHIVE") ($(wc -c <"$ARCHIVE" | tr -d ' ') bytes)"

# --- decrypt + unpack -----------------------------------------------------------
# Decrypt once into a tar stream on disk (inside the 0700 temp dir) so the
# listing check and the extraction read the same bytes.

TARFILE="$WORK/archive.tar"
age -d -i "$IDENTITY" "$ARCHIVE" 2>"$WORK/age.err" | "${DECOMPRESS[@]}" >"$TARFILE" \
  || fail "cannot decrypt/decompress (wrong identity, or a damaged archive): $(head -c 200 "$WORK/age.err" 2>/dev/null)"
ok "decrypted and decompressed"

# Refuse anything that would write outside the target directory.
bad="$(tar -tf "$TARFILE" | grep -E '(^/|(^|/)\.\.(/|$))' || true)"
[[ -z "$bad" ]] || fail "archive contains absolute or parent-relative paths"

X="$WORK/x"
mkdir -p "$X"
tar -xf "$TARFILE" -C "$X" || fail "tar extraction failed"
rm -f "$TARFILE"
ok "unpacked ($(find "$X" -type f | wc -l | tr -d ' ') files)"

# --- manifest -----------------------------------------------------------------

MAN="$X/MANIFEST"
[[ -f "$MAN" ]] || fail "MANIFEST missing"
mval() { sed -n "s/^$1=//p" "$MAN" | head -n 1; }
[[ "$(mval format)" == "casavpn-backup-v1" ]] || fail "MANIFEST format is '$(mval format)', expected casavpn-backup-v1"
for k in created_utc hostname kernel xui_version xray_version db_sha256; do
  [[ -n "$(mval "$k")" ]] || fail "MANIFEST lacks $k"
done
ok "manifest: format casavpn-backup-v1, created $(mval created_utc), host $(mval hostname)"
echo "      kernel:  $(mval kernel)"
echo "      3x-ui:   $(mval xui_version)"
echo "      xray:    $(mval xray_version)"
[[ "$(mval xui_version)" != "unknown" ]] || warn "3x-ui version unknown: the restore must pick a version by hand"

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

DB="$X/rootfs/etc/x-ui/x-ui.db"
[[ -f "$DB" ]] || fail "rootfs/etc/x-ui/x-ui.db missing"
[[ "$(sha256_of "$DB")" == "$(mval db_sha256)" ]] || fail "database checksum does not match the manifest"
ok "database checksum matches the manifest"

# --- database -----------------------------------------------------------------

integrity="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 || true)"
[[ "$integrity" == "ok" ]] || fail "PRAGMA integrity_check: $integrity"
ok "sqlite integrity_check: ok"

inbounds="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM inbounds;' 2>&1)" \
  || fail "no readable inbounds table: $inbounds"
clients="$(sqlite3 "$DB" "SELECT COALESCE(SUM(json_array_length(json_extract(settings,'\$.clients'))),0) FROM inbounds;" 2>&1)" \
  || fail "cannot count clients: $clients"
reality="$(sqlite3 "$DB" "SELECT COUNT(*) FROM inbounds WHERE stream_settings LIKE '%privateKey%';" 2>&1)" \
  || fail "cannot inspect stream settings: $reality"
echo "      inbounds: $inbounds"
echo "      clients:  $clients"
echo "      inbounds with a Reality private key: $reality"
[[ "$inbounds" -ge 1 ]] || fail "the database has no inbounds"
[[ "$clients" -ge 1 ]] || fail "the database has no clients"
[[ "$reality" -ge 1 ]] || fail "no inbound carries a Reality private key"
ok "database holds inbounds, clients and a Reality key"

# --- files the restore procedure needs ------------------------------------------

missing_required=0
for rel in etc/nginx/sites-available etc/nftables.conf; do
  if [[ -e "$X/rootfs/$rel" ]]; then ok "has /$rel"
  else warn "/$rel is not in the archive"; missing_required=1; fi
done
for rel in etc/nginx/sites-enabled etc/letsencrypt etc/casavpn/casavpn.env \
           etc/ssh/sshd_config.d etc/fail2ban/jail.local etc/systemd/system/x-ui.service; do
  if [[ -e "$X/rootfs/$rel" ]]; then ok "has /$rel"
  else warn "/$rel is not in the archive"; fi
done
[[ -s "$X/dpkg-selections.txt" ]] && ok "has dpkg-selections.txt ($(wc -l <"$X/dpkg-selections.txt" | tr -d ' ') lines)"
if [[ -L "$X/rootfs/etc/nginx/sites-enabled/default" || -n "$(find "$X/rootfs/etc/nginx/sites-enabled" -mindepth 1 2>/dev/null | head -n 1)" ]]; then
  ok "nginx sites-enabled is captured (site activation can be replayed)"
fi

[[ "$missing_required" -eq 0 ]] || fail "required configuration is missing from the archive"
echo
echo "RESTORE DRILL PASSED: $(basename "$ARCHIVE")"
