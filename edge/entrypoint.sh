#!/bin/sh
set -eu

DOMAIN="${PALFLOW_DOMAIN:?PALFLOW_DOMAIN must be set}"
MODE="${TLS_MODE:-auto}"
SELF_SIGNED="${ALLOW_SELF_SIGNED:-0}"

CF_CERT="/etc/nginx/cf_certs/fullchain.pem"
CF_KEY="/etc/nginx/cf_certs/privkey.pem"
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
SS_DIR="/etc/nginx/ssl"
SS_CERT="${SS_DIR}/selfsigned.pem"
SS_KEY="${SS_DIR}/selfsigned.key"

# ── helpers ──

cert_valid() {
    [ -f "$1" ] && [ -f "$2" ] && \
        openssl x509 -in "$1" -checkend 86400 -noout 2>/dev/null
}

gen_selfsigned() {
    mkdir -p "$SS_DIR"
    openssl req -x509 -nodes -days 7 -newkey rsa:2048 \
        -keyout "$SS_KEY" -out "$SS_CERT" \
        -subj "/CN=${DOMAIN}" 2>/dev/null
    echo "[edge] Generated temporary self-signed certificate (7 day)"
}

# Called when no real cert is available.
# Exits 1 unless ALLOW_SELF_SIGNED=1.
no_cert_fallback() {
    echo "[edge] ERROR: No valid TLS certificate found." >&2
    echo "[edge]   Issue a Let's Encrypt cert:" >&2
    echo "[edge]   docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d $DOMAIN --email \$LETSENCRYPT_EMAIL --agree-tos --no-eff-email" >&2
    echo "[edge]   Or place Cloudflare Origin cert in certs/cloudflare/" >&2
    if [ "$SELF_SIGNED" = "1" ]; then
        echo "[edge]   ALLOW_SELF_SIGNED=1 — starting with self-signed cert" >&2
        gen_selfsigned
        SSL_CERT="$SS_CERT"; SSL_KEY="$SS_KEY"
    else
        echo "[edge] FATAL: Set ALLOW_SELF_SIGNED=1 in .env to start without a real cert." >&2
        exit 1
    fi
}

# ── cert selection ──

case "$MODE" in
    cloudflare)
        if cert_valid "$CF_CERT" "$CF_KEY"; then
            SSL_CERT="$CF_CERT"; SSL_KEY="$CF_KEY"
            echo "[edge] TLS_MODE=cloudflare — using Cloudflare Origin certificate"
        else
            echo "[edge] FATAL: TLS_MODE=cloudflare but cert missing/expired" >&2
            echo "[edge]   Expected: $CF_CERT" >&2
            echo "[edge]   Place valid Cloudflare Origin cert files and restart." >&2
            exit 1
        fi
        ;;
    letsencrypt)
        if cert_valid "$LE_CERT" "$LE_KEY"; then
            SSL_CERT="$LE_CERT"; SSL_KEY="$LE_KEY"
            echo "[edge] TLS_MODE=letsencrypt — using Let's Encrypt certificate"
        else
            no_cert_fallback
        fi
        ;;
    auto|*)
        if cert_valid "$CF_CERT" "$CF_KEY"; then
            SSL_CERT="$CF_CERT"; SSL_KEY="$CF_KEY"
            echo "[edge] TLS_MODE=auto — using Cloudflare Origin certificate"
        elif cert_valid "$LE_CERT" "$LE_KEY"; then
            SSL_CERT="$LE_CERT"; SSL_KEY="$LE_KEY"
            echo "[edge] TLS_MODE=auto — using Let's Encrypt certificate"
        else
            no_cert_fallback
        fi
        ;;
esac

export SSL_CERT SSL_KEY PALFLOW_DOMAIN

# ── render nginx config (substitute only our vars) ──

envsubst '${PALFLOW_DOMAIN} ${SSL_CERT} ${SSL_KEY}' \
    < /etc/nginx/nginx.template.conf \
    > /etc/nginx/conf.d/default.conf

echo "[edge] Nginx configured: domain=$DOMAIN cert=$SSL_CERT"

# ── background: watch for cert renewals (poll every 5s) ──

(
    RELOAD_FLAG="/etc/letsencrypt/.reload-flag"
    LAST_SEEN=0
    while true; do
        sleep 5
        [ -f "$RELOAD_FLAG" ] || continue
        STAMP=$(stat -c %Y "$RELOAD_FLAG" 2>/dev/null || echo 0)
        if [ "$STAMP" -gt "$LAST_SEEN" ]; then
            LAST_SEEN=$STAMP
            echo "[edge] Cert renewal detected — reloading nginx"
            nginx -s reload 2>/dev/null || true
        fi
    done
) &

exec nginx -g 'daemon off;'
