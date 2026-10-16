#!/usr/bin/env python3
"""pii-scan: keep personal data and secrets out of the CasaVPN repository.

CasaVPN is generalised from a private deployment. This scanner is the gate
that stops any of that deployment (or any contributor's own) from leaking in.

What it scans
  * the working tree (tracked files and untracked, non-ignored files),
  * every path name,
  * every commit message and author/committer identity in `git log --all`,
  * with --history, every line ever added in any commit (a file that was
    committed and then deleted still lives in history).

Generic rules (always on; exceptions live in tools/pii-allow.txt)
  ipv4        any IPv4 address outside the allow-list (documentation ranges,
              loopback, well-known public resolvers, ...)
  ipv6        any IPv6 address outside 2001:db8::/32, ::1 and ::
  email       any e-mail address outside the allow-list
  uuid        any UUID except all-zero or single-digit examples
  age-secret  an age secret key (AGE-SECRET-KEY-1...)
  private-key a PEM private key block
  token       a 40- or 43-character mixed-case token (API token / Reality key)
  hex32       a 32-character hex id (Cloudflare zone, account, KV ids)
  ntfy-topic  an ntfy.sh topic that is not an obvious placeholder
  age-pubkey  an age public key (age1...) - identifying, so never committed

Private denylist
  One extended regular expression per line, matched case-insensitively. Read
  from $CASAVPN_PII_DENYLIST, else ~/.config/casavpn/pii-denylist.txt. It lives
  OUTSIDE the repo, and this tool never prints its contents: a hit is reported
  as "denylist entry #N" with a path and line number only. When the file is
  missing the scan warns loudly and carries on (CASAVPN_REQUIRE_DENYLIST=1
  turns that into a failure).

Allow-list (tools/pii-allow.txt), one rule per line, '#' starts a comment:
  ipv4-cidr   <cidr>              addresses inside this network are fine
  ipv4        <address>           this exact address is fine
  ipv4-text   <text>              this exact text is fine (e.g. 10.0.0.0/8)
  ipv6-cidr   <cidr>
  email       <address>           this exact address is fine
  email-regex <regex>             full-match regex
  uuid        <uuid>
  literal     <text>              removed from every line before ALL matching,
                                  including the private denylist
  skip-rule   <rule> <path-glob>  do not apply <rule> to matching paths
  skip-path   <path-glob>         do not scan matching paths at all
  ack-identity <commit>           the author/committer name and e-mail of this
                                  one commit (full hash or a prefix of at least
                                  10) are not scanned; its message still is.
                                  For a published commit that cannot be
                                  rewritten, after a human has reviewed it.

Exit status: 0 clean, 1 findings, 2 usage or setup error.
"""

import argparse
import fnmatch
import ipaddress
import os
import re
import subprocess
import sys
import tempfile

DEFAULT_DENYLIST = os.path.expanduser("~/.config/casavpn/pii-denylist.txt")

IPV4_RE = re.compile(r"(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(?![\w]|\.\d)")
IPV6_RE = re.compile(r"(?<![\w:])((?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4})(?![\w:])")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
UUID_RE = re.compile(r"(?<![0-9A-Fa-f-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f-])")
AGE_SECRET_RE = re.compile(r"AGE-SECRET-KEY-1[0-9A-Z]{20,}")
AGE_PUB_RE = re.compile(r"(?<![0-9a-z])age1[0-9a-z]{50,}")
PRIVKEY_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")
TOKEN_RE = re.compile(r"(?<![A-Za-z0-9_+/.-])(?:[A-Za-z0-9_-]{40}|[A-Za-z0-9_-]{43})(?![A-Za-z0-9_+/.-])")
HEX32_RE = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{32}(?![0-9A-Za-z])")
NTFY_RE = re.compile(r"ntfy\.sh/([A-Za-z0-9_-]+)")
NTFY_OK = re.compile(r"^(casavpn-?(CHANGE-ME|EXAMPLE|XXXX|RANDOM)?|example[\w-]*|topic|TOPIC|YOUR[\w-]*)$")

RULES = ["ipv4", "ipv6", "email", "uuid", "age-secret", "age-pubkey",
         "private-key", "token", "hex32", "ntfy-topic", "denylist"]


class Allow:
    def __init__(self):
        self.ipv4_nets = []
        self.ipv4_exact = set()
        self.ipv4_text = set()
        self.ipv6_nets = []
        self.emails = set()
        self.email_res = []
        self.uuids = set()
        self.literals = []
        self.skip_rules = []   # (rule, glob)
        self.skip_paths = []
        self.ack_identities = []

    @classmethod
    def load(cls, path):
        a = cls()
        if not os.path.isfile(path):
            return a
        with open(path, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith("literal ") or stripped.startswith("literal\t"):
                    # literal text is taken verbatim to the end of the line
                    a.literals.append(stripped.split(None, 1)[1])
                    continue
                parts = stripped.split("#", 1)[0].split()
                kind, args = parts[0], parts[1:]
                try:
                    if kind == "ipv4-cidr":
                        a.ipv4_nets.append(ipaddress.ip_network(args[0], strict=False))
                    elif kind == "ipv4":
                        a.ipv4_exact.add(args[0])
                    elif kind == "ipv4-text":
                        a.ipv4_text.add(args[0])
                    elif kind == "ipv6-cidr":
                        a.ipv6_nets.append(ipaddress.ip_network(args[0], strict=False))
                    elif kind == "email":
                        a.emails.add(args[0].lower())
                    elif kind == "email-regex":
                        a.email_res.append(re.compile(args[0], re.I))
                    elif kind == "uuid":
                        a.uuids.add(args[0].lower())
                    elif kind == "skip-rule":
                        a.skip_rules.append((args[0], args[1]))
                    elif kind == "skip-path":
                        a.skip_paths.append(args[0])
                    elif kind == "ack-identity":
                        if not re.fullmatch(r"[0-9a-f]{10,40}", args[0]):
                            raise ValueError("ack-identity needs a commit hash of 10 to 40 lowercase hex digits")
                        a.ack_identities.append(args[0])
                    else:
                        raise ValueError("unknown rule kind %r" % kind)
                except (IndexError, ValueError) as exc:
                    sys.exit("pii-scan: %s:%d: bad allow-list line: %s" % (path, n, exc))
        a.literals.sort(key=len, reverse=True)
        return a

    def skipped(self, rule, path):
        return any(r == rule and fnmatch.fnmatch(path, g) for r, g in self.skip_rules)

    def path_skipped(self, path):
        return any(fnmatch.fnmatch(path, g) for g in self.skip_paths)

    def identity_acked(self, sha):
        return any(sha.startswith(a) for a in self.ack_identities)

    def strip_literals(self, text):
        for lit in self.literals:
            if lit in text:
                text = text.replace(lit, "")
        return text


def uuid_is_example(u):
    h = u.replace("-", "").lower()
    return len(set(h)) == 1  # 0000..., 1111..., aaaa...


def scan_text(text, path, allow):
    """Yield (rule, token) for generic-rule hits on one line of text."""
    text = allow.strip_literals(text)

    if not allow.skipped("ipv4", path):
        for m in IPV4_RE.finditer(text):
            tok = m.group(1)
            octets = tok.split(".")
            if any(int(o) > 255 or (len(o) > 1 and o[0] == "0") for o in octets):
                continue
            cidr = re.match(r"/\d{1,2}", text[m.end():])
            shown = tok + (cidr.group(0) if cidr else "")
            if shown in allow.ipv4_text or tok in allow.ipv4_text or tok in allow.ipv4_exact:
                continue
            addr = ipaddress.ip_address(tok)
            if any(addr in net for net in allow.ipv4_nets):
                continue
            yield "ipv4", tok

    if not allow.skipped("ipv6", path):
        for m in IPV6_RE.finditer(text):
            tok = m.group(1)
            if tok.count(":") < 2:
                continue
            try:
                addr = ipaddress.IPv6Address(tok)
            except ValueError:
                continue
            if addr.is_loopback or addr.is_unspecified:
                continue
            if any(addr in net for net in allow.ipv6_nets):
                continue
            yield "ipv6", tok

    if not allow.skipped("email", path):
        for m in EMAIL_RE.finditer(text):
            tok = m.group(0)
            if tok.lower() in allow.emails or any(r.fullmatch(tok) for r in allow.email_res):
                continue
            yield "email", tok

    if not allow.skipped("uuid", path):
        for m in UUID_RE.finditer(text):
            tok = m.group(0)
            if uuid_is_example(tok) or tok.lower() in allow.uuids:
                continue
            yield "uuid", tok

    if not allow.skipped("age-secret", path):
        for m in AGE_SECRET_RE.finditer(text):
            yield "age-secret", m.group(0)[:12] + "..."
    if not allow.skipped("age-pubkey", path):
        for m in AGE_PUB_RE.finditer(text):
            yield "age-pubkey", m.group(0)[:8] + "..."
    if not allow.skipped("private-key", path):
        for m in PRIVKEY_RE.finditer(text):
            yield "private-key", m.group(0)

    if not allow.skipped("token", path):
        for m in TOKEN_RE.finditer(text):
            tok = m.group(0)
            if (re.search(r"[a-z]", tok) and re.search(r"[A-Z]", tok) and re.search(r"[0-9]", tok)
                    and not re.fullmatch(r"[0-9a-fA-F]+", tok)):
                yield "token", tok[:4] + "..."

    if not allow.skipped("hex32", path):
        for m in HEX32_RE.finditer(text):
            tok = m.group(0)
            if len(set(tok.lower())) > 1:
                yield "hex32", tok[:4] + "..."

    if not allow.skipped("ntfy-topic", path):
        for m in NTFY_RE.finditer(text):
            if not NTFY_OK.match(m.group(1)):
                yield "ntfy-topic", m.group(1)[:4] + "..."


class Report:
    def __init__(self):
        self.findings = []

    def add(self, rule, where, detail):
        self.findings.append((rule, where, detail))


def load_denylist(path):
    """Return (patterns_file_path, count) with comments/blank lines removed."""
    patterns = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            patterns.append(line)
    tmp = tempfile.NamedTemporaryFile("w", delete=False, prefix="pii-deny.", encoding="utf-8")
    os.chmod(tmp.name, 0o600)
    tmp.write("\n".join(patterns) + "\n")
    tmp.close()
    return tmp.name, patterns


def denylist_hits(patfile, patterns, lines):
    """lines: list of text. Return {line_index: first_matching_entry_number}."""
    if not lines or not patterns:
        return {}
    data = "\n".join(l.replace("\n", " ").replace("\r", " ") for l in lines) + "\n"
    proc = subprocess.run(["grep", "-n", "-i", "-E", "-f", patfile], input=data.encode("utf-8", "replace"),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode == 2:
        sys.exit("pii-scan: the private denylist is not valid grep -E input (see grep's complaint on stderr, entry text is not shown)")
    hit_lines = set()
    for out in proc.stdout.decode("utf-8", "replace").splitlines():
        n = out.split(":", 1)[0]
        if n.isdigit():
            hit_lines.add(int(n) - 1)
    result = {}
    for count, idx in enumerate(sorted(hit_lines)):
        # Find which entry matched (by number) without ever printing the entry.
        # Only the first 50 hits are attributed: the rest are already damning.
        entry = 0
        for i, pat in enumerate(patterns, 1):
            if count >= 50:
                break
            p = subprocess.run(["grep", "-q", "-i", "-E", "-e", pat],
                               input=(lines[idx] + "\n").encode("utf-8", "replace"))
            if p.returncode == 0:
                entry = i
                break
        result[idx] = entry
    return result


def git(args, root, text=True):
    return subprocess.run(["git", "-C", root] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def tree_files(root):
    out = git(["ls-files", "-co", "--exclude-standard", "-z"], root)
    if out.returncode != 0:
        sys.exit("pii-scan: %s is not a git repository" % root)
    return [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]


def is_text(path):
    try:
        with open(path, "rb") as fh:
            return b"\0" not in fh.read(8192)
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    ap.add_argument("--allow", default=None, help="allow-list file (default: <root>/tools/pii-allow.txt)")
    ap.add_argument("--history", action="store_true", help="also scan every line ever added in any commit")
    ap.add_argument("--no-git-log", action="store_true", help="skip commit message and identity checks")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    allow = Allow.load(args.allow or os.path.join(root, "tools", "pii-allow.txt"))
    report = Report()

    deny_path = os.environ.get("CASAVPN_PII_DENYLIST") or DEFAULT_DENYLIST
    patfile, patterns = None, []
    if os.path.isfile(deny_path):
        patfile, patterns = load_denylist(deny_path)
        if not patterns:
            print("pii-scan: WARNING: the private denylist is empty; only the generic rules are active", file=sys.stderr)
    else:
        banner = "!" * 72
        print(banner, file=sys.stderr)
        print("pii-scan: WARNING: no private denylist found.", file=sys.stderr)
        print("  Set CASAVPN_PII_DENYLIST or create ~/.config/casavpn/pii-denylist.txt", file=sys.stderr)
        print("  (one regex per line, kept OUTSIDE the repo). Without it only the generic", file=sys.stderr)
        print("  patterns run, and names, domains and hostnames are NOT checked.", file=sys.stderr)
        print(banner, file=sys.stderr)
        if os.environ.get("CASAVPN_REQUIRE_DENYLIST") == "1":
            print("pii-scan: CASAVPN_REQUIRE_DENYLIST=1, refusing to continue", file=sys.stderr)
            return 2

    # --- working tree ---------------------------------------------------------
    files = [f for f in tree_files(root) if os.path.exists(os.path.join(root, f))]
    scanned = 0
    deny_lines, deny_where = [], []

    for rel in files:
        if allow.path_skipped(rel):
            continue
        # path names count too
        stripped = allow.strip_literals(rel)
        deny_lines.append(stripped)
        deny_where.append((rel, 0, "path name"))
        # ...and the generic rules apply to the name as well: a file called after
        # an e-mail address or an IP leaks it even when it is empty.
        for rule, tok in scan_text(rel, rel, allow):
            report.add(rule, "%s (path name)" % rel, tok)
        full = os.path.join(root, rel)
        if os.path.islink(full) or not is_text(full):
            continue
        scanned += 1
        with open(full, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                line = line.rstrip("\n")
                for rule, tok in scan_text(line, rel, allow):
                    report.add(rule, "%s:%d" % (rel, n), tok)
                if patterns and not allow.skipped("denylist", rel):
                    deny_lines.append(allow.strip_literals(line))
                    deny_where.append((rel, n, "line"))

    # --- git log: messages and identities ---------------------------------------
    commits = 0
    if not args.no_git_log:
        sep_rec, sep_fld = "\x1e", "\x1f"
        fmt = sep_rec + "%H" + sep_fld + "%an" + sep_fld + "%ae" + sep_fld + "%cn" + sep_fld + "%ce" + sep_fld + "%B"
        out = git(["log", "--all", "--format=" + fmt], root)
        if out.returncode == 0:
            for rec in out.stdout.decode("utf-8", "replace").split(sep_rec):
                if not rec.strip():
                    continue
                commits += 1
                parts = rec.split(sep_fld, 5)
                if len(parts) < 6:
                    continue
                sha = parts[0][:10]
                # lines 1-4 are author name/e-mail and committer name/e-mail
                acked = 4 if allow.identity_acked(parts[0]) else 0
                blob = "\n".join(parts[1:6])
                for n, line in enumerate(blob.splitlines(), 1):
                    if n <= acked:
                        continue
                    for rule, tok in scan_text(line, "git-log", allow):
                        report.add(rule, "commit %s (message/identity)" % sha, tok)
                    if patterns:
                        deny_lines.append(allow.strip_literals(line))
                        deny_where.append(("commit %s" % sha, n, "message/identity"))

        if args.history:
            # -m: a merge commit is diffed against each parent in turn, so a line
            # added only while resolving a merge (and deleted again afterwards) is
            # seen. Plain `git log -p` prints nothing for merges.
            out = git(["log", "--all", "-m", "-p", "--unified=0", "--no-color", "--format=\x1eCOMMIT %H"], root)
            sha, cur = "", ""
            for line in out.stdout.decode("utf-8", "replace").splitlines():
                if line.startswith("\x1eCOMMIT "):
                    sha, cur = line.split(" ", 1)[1][:10], ""
                elif line.startswith("diff --git "):
                    m = re.match(r"diff --git a/(.*) b/(.*)$", line)
                    cur = m.group(2) if m else ""
                elif line.startswith("+") and not line.startswith("+++"):
                    if allow.path_skipped(cur):
                        continue
                    body = line[1:]
                    for rule, tok in scan_text(body, cur, allow):
                        report.add(rule, "history %s %s" % (sha, cur), tok)
                    if patterns and not allow.skipped("denylist", cur):
                        deny_lines.append(allow.strip_literals(body))
                        deny_where.append(("history %s %s" % (sha, cur), 0, "added line"))

    # --- history: every path name ever committed (a deleted file keeps its name) ---
    if args.history and not args.no_git_log:
        out = git(["log", "--all", "-m", "--name-only", "--no-color", "-z", "--format="], root)
        seen = set(files)
        for rel in out.stdout.decode("utf-8", "replace").split("\0"):
            rel = rel.strip("\n")
            if not rel or rel in seen:
                continue
            seen.add(rel)
            if allow.path_skipped(rel):
                continue
            for rule, tok in scan_text(rel, rel, allow):
                report.add(rule, "history path %s" % rel, tok)
            if patterns:
                deny_lines.append(allow.strip_literals(rel))
                deny_where.append(("history path %s" % rel, 0, "path name"))

    # --- private denylist ----------------------------------------------------------
    if patterns:
        hits = denylist_hits(patfile, patterns, deny_lines)
        for idx, entry in hits.items():
            where, n, kind = deny_where[idx]
            loc = "%s:%d" % (where, n) if n else where
            report.add("denylist", loc, "private denylist entry #%d (%s; text withheld)" % (entry, kind))
        os.unlink(patfile)

    if not args.quiet:
        print("pii-scan: %d text files, %d commits%s, %s" % (
            scanned, commits, " + full history" if args.history else "",
            "private denylist: %d entries" % len(patterns) if patterns else "private denylist: NONE"))

    if report.findings:
        for rule, where, detail in report.findings:
            print("PII[%s] %s  %s" % (rule, where, detail))
        print("pii-scan: %d finding(s). Replace the value with a placeholder, or add a justified rule to "
              "tools/pii-allow.txt." % len(report.findings), file=sys.stderr)
        return 1
    if not args.quiet:
        print("pii-scan: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
