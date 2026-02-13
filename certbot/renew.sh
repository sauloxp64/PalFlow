#!/bin/sh
set -eu

# ── fail-fast validation ──

DOMAIN="${PALFLOW_DOMAIN:?PALFLOW_DOMAIN must be set}"
EMAIL="${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL must be set}"
MODE="${TLS_MODE:-auto}"

CF_CERT="/etc/nginx/cf_certs/fullchain.pem"
CF_KEY="/etc/nginx/cf_certs/privkey.pem"
RELOAD_FLAG="/etc/letsencrypt/.reload-flag"

# ── helpers ──

cert_valid() {
    [ -f "$1" ] && [ -f "$2" ] && \
        openssl x509 -in "$1" -checkend 86400 -noout 2>/dev/null
}

# ── should certbot be active? ──

case "$MODE" in
    cloudflare)
        echo "[certbot] TLS_MODE=cloudflare — certbot not needed."
        exit 0
        ;;
    letsencrypt)
        # Explicit LE mode — always manage LE certs
        ;;
    auto|*)
        if cert_valid "$CF_CERT" "$CF_KEY"; then
            echo "[certbot] TLS_MODE=auto — Cloudflare cert active, certbot not needed."
            exit 0
        fi
        ;;
esac

# ── first issuance (if no LE certs exist) ──

if [ ! -d /etc/letsencrypt/renewal ] || [ -z "$(ls /etc/letsencrypt/renewal/ 2>/dev/null)" ]; then
    echo "[certbot] No LE certificates found. Attempting first issuance..."

    if certbot certonly --dry-run \
        --webroot -w /var/www/certbot \
        -d "$DOMAIN" --email "$EMAIL" \
        --agree-tos --no-eff-email 2>&1; then

        echo "[certbot] Dry-run passed. Issuing real certificate..."
        certbot certonly \
            --webroot -w /var/www/certbot \
            -d "$DOMAIN" --email "$EMAIL" \
            --agree-tos --no-eff-email

        touch "$RELOAD_FLAG"
        echo "[certbot] Certificate issued. Signaled edge to reload."
    else
        echo "[certbot] Dry-run failed. DNS may not point to this server," >&2
        echo "[certbot] or port 80 is not reachable from the internet." >&2
        echo "[certbot] Issue manually when ready:" >&2
        echo "[certbot]   docker compose run --rm certbot certonly \\" >&2
        echo "[certbot]     --webroot -w /var/www/certbot -d $DOMAIN \\" >&2
        echo "[certbot]     --email $EMAIL --agree-tos --no-eff-email" >&2
        exit 0
    fi
fi

# ── renewal loop ──

echo "[certbot] Renewal loop started (every 12h)"

while true; do
    certbot renew \
        --webroot -w /var/www/certbot \
        --deploy-hook "touch $RELOAD_FLAG" \
        --quiet \
    || echo "[certbot] Renewal returned non-zero" >&2
    echo "[certbot] Next check in 12h"
    sleep 12h
done
