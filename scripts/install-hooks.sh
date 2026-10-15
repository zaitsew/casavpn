#!/usr/bin/env bash
#
# install-hooks.sh — install a git pre-push hook that runs ./check.sh, so a
# push cannot leave this machine with failing shellcheck, failing tests or
# personal data in the tree or the history.
#
# Usage: scripts/install-hooks.sh
# Safe to re-run. Refuses to overwrite a pre-push hook it did not write.

set -u -o pipefail

repo="$(git rev-parse --show-toplevel)" || { echo "not inside a git repository" >&2; exit 1; }
hooks_dir="$(git -C "$repo" rev-parse --git-path hooks)"
case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
hook="$hooks_dir/pre-push"
marker="# casavpn pre-push hook"

if [ -e "$hook" ] && ! grep -qF "$marker" "$hook"; then
  echo "refusing to overwrite $hook (not written by this script); merge it by hand" >&2
  exit 1
fi

mkdir -p "$hooks_dir"
cat >"$hook" <<HOOK
#!/usr/bin/env bash
$marker
cd "\$(git rev-parse --show-toplevel)" || exit 1
exec ./check.sh
HOOK
chmod +x "$hook"
echo "installed $hook (runs ./check.sh before every push)"
if [ ! -f "${CASAVPN_PII_DENYLIST:-$HOME/.config/casavpn/pii-denylist.txt}" ]; then
  echo "note: no private PII denylist yet; see CONTRIBUTING.md (\"Keeping personal data out\")" >&2
fi
