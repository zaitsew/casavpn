#!/bin/sh
# CasaVPN: /etc/letsencrypt/renewal-hooks/deploy/casavpn-reload-nginx.sh
# Runs after every successful renewal; nginx picks up the new certificate.
set -eu
systemctl reload nginx
