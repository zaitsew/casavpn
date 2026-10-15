# Contributing

Thanks for helping. CasaVPN is small on purpose: a Raspberry Pi, a handful of
scripts, a manual. Changes that keep it that way are the easiest to accept.

## The gate

There is no CI. `./check.sh` on your machine is the gate:

```bash
scripts/install-hooks.sh     # once: runs ./check.sh before every push
./check.sh                   # shellcheck, py_compile, every tests/test-*.sh, node tests for monitor/, the PII scan
```

You need `shellcheck`, `python3`, `bash`, `git`, and `node` (22.18+, only for `monitor/`;
without it that step is skipped loudly). Everything runs offline and without root.

## Pull requests

- One logical change per pull request; small commits with a message that says *why*.
- Everything in the repository is **English**: code comments, docs, commit messages,
  issues, test fixtures.
- A new script gets a `tests/test-<name>.sh`. Tests fake the system (`systemctl`,
  `nft`, `sshd`, `dig`, `curl`, ...) with stubs on `PATH`; see `tests/test-healthcheck.sh`.
  Generate secrets and UUIDs at run time inside a test rather than writing them in a file.
- Keep bash compatible with 3.2 where a script has to run on a Mac (`install.sh --dry-run`,
  laptop-side helpers). Avoid `mapfile`, associative arrays and `${var,,}` there.
- Scripts that read `/etc/casavpn/casavpn.env` **parse** it; they never `source` it.
- Say what you could **not** verify (for example "not run on a real Pi") in the pull request.
- Anything that costs money for users (a paid service, a metered API) is named in
  the docs with its price.

Bugs and ideas: open an issue with the output of `casavpn-healthcheck --local` (after
removing anything personal, see below).

## Keeping personal data out

CasaVPN was generalised from a private deployment, and every contributor runs one of
their own. The repository must never contain real hostnames, IP addresses, e-mail
addresses, client names, UUIDs, keys, tokens, zone or account IDs, or your location.
Use placeholders only:

| Use | Never |
|---|---|
| `vpn.example.com`, `example.com` | your domain |
| RFC 5737 addresses: `192.0.2.x`, `198.51.100.x`, `203.0.113.x` | your public or LAN IP |
| `<LAN_IP>`, `192.168.0.0/24` as the example network | your real range if it identifies you |
| users `pi` / `admin`, clients `alice` / `bob` | real names |
| `alice@example.com` | your address |
| `<REPO_URL>` | a personal account in a link |

`tools/pii-scan.py` enforces it, and `./check.sh` runs it over the tree, file names,
every commit message and identity, and every line ever added to history (a file that
was committed and then deleted still counts).

**Add your own private denylist.** The generic rules cannot know your domain, your
street or your family's names. Put one extended regular expression per line in
`~/.config/casavpn/pii-denylist.txt` (outside the repository), for example your
domain, your ISP, your city. The scanner matches them case-insensitively and
reports only "denylist entry #N at file:line"; it never prints the pattern or the
matched text, so a CI log or a screenshot does not leak it. Set
`CASAVPN_PII_DENYLIST` to use another path, and `CASAVPN_REQUIRE_DENYLIST=1` to
make a missing file an error.

If the scanner flags a placeholder, change the placeholder. The allow-list
(`tools/pii-allow.txt`) is for values that are public knowledge or documentation
ranges, and every line in it is a promise. Do not add a real value to make a check
pass.

If personal data did reach a commit, do not just delete the file: the history still
has it. Rewrite the branch before anything is pushed, and rotate any secret that was
exposed.

## Releases

Version in `CHANGELOG.md`; the pinned 3x-ui release and its hashes in
`config/xui-release.env` change together in one commit after reading that release's
notes and testing `casavpn-upgrade` and `casavpn-rollback`.
