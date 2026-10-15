# Moving your domain's DNS to Cloudflare

Only needed if your domain's DNS is hosted somewhere else (your registrar, another
provider). CasaVPN's dynamic-IP updater and certificates use the Cloudflare API, so
the zone must be on Cloudflare. A zone that is already there: skip this page.

> **Moving DNS hosting can take your whole domain offline** (website and mail
> included) if DNSSEC is on and you skip step 0. Read the whole page first. A
> subdomain-only alternative is in [the last section](#if-you-cannot-move-the-whole-domain).

You move *DNS hosting* (who answers questions about the domain). The *registration*
(who you pay) can stay where it is.

## Step 0: remove DNSSEC (the one thing that can break everything)

If the zone is signed, a **DS record** exists at the TLD's parent. Cloudflare's new
zone starts unsigned, so after you switch nameservers every validating resolver
(1.1.1.1, 8.8.8.8, 9.9.9.9 all validate) answers `SERVFAIL` for the whole domain
until the old DS expires from caches.

```bash
dig +short DS example.com @1.1.1.1          # any output means DNSSEC is on
./scripts/dns-diff.sh <old-ns> <new-ns>     # exits 2 and prints a banner if a DS exists
```

If a DS exists: disable DNSSEC at your registrar (Domain > DNSSEC > off), wait until
the lookup above is empty **with a proper `NOERROR`** (a `SERVFAIL`, `REFUSED` or a
timeout proves nothing), then wait out the DS TTL (24 hours for most TLDs), and only
then switch. You can re-enable DNSSEC later from Cloudflare.

## Step 1: add the zone to Cloudflare

1. Create a free Cloudflare account and **Add a site** with your domain. Pick the
   free plan. Cloudflare imports the records it can find.
2. Note the two nameservers it assigns (`<name>.ns.cloudflare.com`).
3. Create an API token: My Profile > API Tokens > Create > "Edit zone DNS" template,
   restricted to this one zone. Put it in a secret store, then:

```bash
export CF_API_TOKEN="$(pass show casavpn/cf-dns-token)"     # or the keychain, or any secret store
./scripts/cf-api.sh verify-token
./scripts/cf-api.sh zone-status example.com                 # pending + the assigned nameservers
./scripts/cf-api.sh zone-id example.com                     # -> CF_ZONE_ID in casavpn.env
```

## Step 2: audit the imported records

An import misses things (and, worse, the old zone may hold records nobody remembers:
mail, verification tokens, a forgotten subdomain). List what exists in Cloudflare and
fix the VPN hostname:

```bash
./scripts/cf-api.sh list-records example.com
./scripts/cf-api.sh ensure-grey example.com            # preview: proxied records that should be DNS-only
./scripts/cf-api.sh ensure-grey example.com --apply    # the VPN hostname must NOT be proxied (grey cloud)
./scripts/cf-api.sh set-ttl example.com vpn.example.com 60 --apply
```

Do not blanket-grey records that belong behind the proxy (a website, say):
`ensure-grey` previews first for a reason. Only the VPN name has to be DNS-only.

## Step 3: prove the new zone answers like the old one

Before the switch, ask both nameservers the same questions and compare:

```bash
cp config/dns/inventory.example.txt   config/dns/inventory.txt
cp config/dns/allowlist.example.txt   config/dns/allowlist.txt
cp config/dns/key-records.example.txt config/dns/key-records.txt
$EDITOR config/dns/inventory.txt        # every name and type you know exists, plus probes
./scripts/dns-diff.sh <old-ns> <new-ns> --domain example.com
```

The files hold your real record names, so they are git-ignored. Repeat until the
output is clean. Exit codes: `0` clean, `1` differences, `2` DS record present
(a blocker, step 0), `3` usage or query error. A timeout, `SERVFAIL` or `REFUSED`
is never counted as an answer, on either side. Differences listed in the allow-list
(for example the `NS` set, which differs by design) are tolerated.

## Step 4: switch the nameservers

At your registrar, replace the nameservers with the two Cloudflare gave you. Nothing
else changes. Cloudflare marks the zone active within minutes to a few hours.

## Step 5: watch the switch

```bash
./scripts/dns-diff.sh --resolvers --domain example.com   # public resolvers vs the authoritative answer
```

It asks 1.1.1.1, 8.8.8.8 and 9.9.9.9 for the key records and compares them with the
authoritative answer. Run it a few times over the first hours. Disagreement for a
while is caching; a `SERVFAIL` is the DNSSEC problem from step 0 (re-add a signed
zone or remove the DS, quickly).

## Step 6: let the updater take over

With `CF_API_TOKEN` and `CF_ZONE_ID` in `casavpn.env`, `sudo casavpn-ddns --force`
proves the write path, and the timer keeps the record correct from then on
([DYNAMIC-IP.md](DYNAMIC-IP.md)).

## Rollback

Put the old nameservers back at the registrar. The old zone is untouched until you
delete it, so keep it until you are sure. Cached answers fade within the old NS TTL.

## If you cannot move the whole domain

Cloudflare's free plan needs the whole zone. Alternatives, in order of effort:

1. Move only a *subdomain's* DNS to Cloudflare by delegating `vpn.example.com` with
   `NS` records at your current host (works if it supports delegation).
2. Register a cheap separate domain just for the VPN and put that on Cloudflare.
3. Use another DDNS provider: [DYNAMIC-IP.md](DYNAMIC-IP.md#not-using-cloudflare)
   (certificates then need `--skip-certs` and a certificate you manage).
