#!/bin/sh
set -eu

RELOAD_FLAG="/etc/letsencrypt/.reload-flag"

echo "[certbot] Renewal loop started (every 12h)"

# Let edge finish starting before first check
sleep 30

while true; do
    echo "[certbot] Running certbot renew..."
    certbot renew \
        --webroot -w /var/www/certbot \
        --deploy-hook "touch $RELOAD_FLAG" \
        --quiet \
    || echo "[certbot] Renewal returned non-zero (may be normal if no certs yet)" >&2
    echo "[certbot] Next check in 12h"
    sleep 12h
done
