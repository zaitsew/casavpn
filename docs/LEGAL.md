# Legal and responsible use

CasaVPN is a tool. This page is not legal advice; it lists what to think about
before you run one. The software is provided as is (see [LICENSE](../LICENSE)).

## You are the operator

Everything that goes through the VPN reaches the internet from **your** connection
and **your** IP address. Your ISP's terms of service, the law where you live, and any
abuse complaint attach to you, not to the person using the profile.

- Check your ISP's terms. Some forbid running servers or reselling a connection on a
  residential line.
- Give profiles only to people you know and would vouch for. One identity per person,
  so you can cut one off without touching the others.
- Keep the panel's access logs in mind: you can see per-client traffic totals. Tell
  the people you invite what you can and cannot see, and keep it that way.

## Laws on VPNs differ

In many places running a private VPN for yourself and your family is ordinary. In
some, VPNs, circumvention tools or encryption are restricted or licensed, and the
risk may fall on the people who use it rather than on you. Know the rules where the
server is **and** where the users are. If you are unsure, ask someone qualified
before you invite anyone.

## BitTorrent is blocked by default

3x-ui's default Xray template includes a rule that sends BitTorrent to a blackhole.
CasaVPN keeps it, and `casavpn-healthcheck --local` fails if it disappears. The
reasons: copyright complaints arrive at the account holder of the connection, and a
residential line is rarely sized or contracted for it. If you remove the rule, you
accept that.

## Private networks are blocked by default

A second default rule blocks `geoip:private`, which stops a VPN client from reaching
your home LAN. Removing it gives every client a route to your router, printers and
other devices. Do not.

## What CasaVPN does not do

- It does not make you anonymous to the sites you visit or to the operator.
- It does not log traffic content, and it does not promise to defeat any particular
  network's censorship. Detection methods evolve.
- It makes no warranty. Keep your software updated ([UPGRADING.md](UPGRADING.md)).

## Data you hold

Client UUIDs, the traffic totals, the Reality private key, your Cloudflare token and
the backups are sensitive. If other people's use of your VPN means you hold their
data, you may have obligations under data-protection law where you live. Keep the
panel closed, the backups encrypted, and delete clients you no longer serve.
