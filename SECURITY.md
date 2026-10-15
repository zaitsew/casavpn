# Security policy

CasaVPN installs a firewall, an SSH policy and a VPN on a machine at someone's
home, so a defect can matter more than a bug usually does.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private
vulnerability reporting: on the repository page, Security > Report a vulnerability.
Include what you found, how to reproduce it, and what it lets an attacker do.

You can expect an acknowledgement within a week. If the report is valid we will fix
it, say so in the CHANGELOG, and credit you if you wish.

## In scope

- The installer and the scripts (privilege handling, file permissions, command or
  argument injection, unsafe temporary files, secrets in logs or process lists).
- The generated configuration (nftables, nginx, sshd, fail2ban, systemd units): any
  exposure that contradicts [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md).
- The backup format and the restore procedure.
- The personal-data scanner failing to catch a leak it claims to catch.

## Out of scope

- Vulnerabilities in 3x-ui, Xray, nginx, OpenSSH and other upstream software: report
  them upstream. If CasaVPN's pinned version is affected, tell us so we can bump it.
- Anything that needs root on the host already.
- Detection of Reality by a specific network: no circumvention tool can promise this.

## Known limitations

Listed in [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md#known-limitations). In
particular, version 0.1.0's installer has not yet been run end to end on a clean
host, so treat the first install as a test.
