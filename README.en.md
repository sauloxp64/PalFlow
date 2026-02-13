🇧🇷 Versao em Portugues disponivel aqui: [README.md](README.md)

# PalFlow

Palworld breeding planner. Visual DAG-based tool that maps optimal breeding paths from captured base pals to target pals.

Single-page static app (HTML/CSS/JS, zero dependencies) served via a fully containerized Docker stack with automated TLS.

## Architecture

```
                    Browser
                      |
               HTTPS :443 / HTTP :80
                      |
              +-------+-------+
              |     edge      |   nginx reverse proxy
              | TLS termination|   (Cloudflare Origin / Let's Encrypt / self-signed)
              +-------+-------+
                      |
              HTTP (Docker internal)
                      |
              +-------+-------+
              |   palflow     |   nginx:alpine
              |  static site  |   index.html + /assets/icons/
              +---------------+

              +---------------+
              |   certbot     |   certbot/certbot
              | renewal loop  |   webroot challenge, every 12h
              +---------------+
```

**With Cloudflare proxy (orange cloud):**

```
Browser --> Cloudflare CDN --> edge :443 (CF Origin cert) --> palflow
```

Cloudflare terminates the public TLS connection. The edge container uses a Cloudflare Origin Certificate to secure the link between Cloudflare and the origin server. This cert is not browser-trusted on its own.

**Without Cloudflare (direct DNS):**

```
Browser --> edge :443 (Let's Encrypt cert) --> palflow
```

The edge container uses a browser-trusted Let's Encrypt certificate. Certbot handles issuance and automatic renewal via the ACME webroot challenge.

## Services

| Service | Image | Role | Ports |
|---------|-------|------|-------|
| `palflow` | nginx:alpine (custom) | Static site server | Internal :80 only |
| `edge` | nginx:alpine (custom) | TLS termination + reverse proxy | 0.0.0.0:80, 0.0.0.0:443 |
| `certbot` | certbot/certbot | Let's Encrypt renewal loop | None |

The edge container binds to `0.0.0.0` (all interfaces) on ports 80 and 443 because it is the public-facing entrypoint. Port 80 must be reachable from the internet for ACME challenges and HTTP-to-HTTPS redirects. Port 443 serves all HTTPS traffic. The palflow container has no published ports — it is only reachable by edge via Docker's internal network.

## Requirements

- Ubuntu 22.04+ (or compatible Linux)
- Docker 24+
- Docker Compose v2+
- A domain with DNS pointing to the server
- Ports 80 and 443 open (firewall/security group)

### Firewall (UFW)

If UFW is enabled on the server, allow the required ports:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw reload
```

Verify:

```bash
sudo ufw status
```

## Docker Installation (Ubuntu)

### Method A: Official APT Repository

Follow the official guide:
https://docs.docker.com/engine/install/ubuntu/

### Method B: Quick Script (recommended for fast setup)

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

### Post-Install Steps

Add your user to the `docker` group so you can run Docker without `sudo`:

```bash
sudo usermod -aG docker $USER
```

Log out and back in for the group change to take effect, or run:

```bash
newgrp docker
```

Enable Docker to start on boot:

```bash
sudo systemctl enable docker
```

Verify the installation:

```bash
docker --version
docker compose version
```

Reference: https://docs.docker.com/engine/install/linux-postinstall/

## Quick Start

### 1. Clone and configure

```bash
git clone <repo-url> palflow
cd palflow
```

Copy the configuration template and edit with your actual values:

```bash
cp .env.example .env
```

Edit `.env` with your domain and email:

```
PALFLOW_DOMAIN=palflow.yourdomain.com
TLS_MODE=auto
ALLOW_SELF_SIGNED=0
LETSENCRYPT_EMAIL=your-email@example.com
```

### 2. Bootstrap (first deploy)

On first deploy, no TLS certificate exists yet. The edge container needs to be running on port 80 for certbot to complete the ACME challenge. Use `ALLOW_SELF_SIGNED=1` to start with a temporary self-signed cert:

```bash
ALLOW_SELF_SIGNED=1 docker compose up -d --build
```

### 3. Issue Let's Encrypt certificate

```bash
docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    -d $PALFLOW_DOMAIN \
    --email $LETSENCRYPT_EMAIL \
    --agree-tos --no-eff-email
```

### 4. Restart edge with real cert

```bash
docker compose restart edge
```

Edge will detect the new Let's Encrypt certificate and use it automatically.

### 5. Verify

```bash
curl -sI https://palflow.example.com | head -5
docker compose logs edge --no-log-prefix | grep "\[edge\]"
```

## TLS Modes

Set `TLS_MODE` in `.env`:

| Mode | Behavior |
|------|----------|
| `auto` (default) | Use Cloudflare Origin cert if valid, else Let's Encrypt if valid, else fail |
| `cloudflare` | Require Cloudflare Origin cert. Exit 1 if missing or expired |
| `letsencrypt` | Require Let's Encrypt cert. Fall back to self-signed only if `ALLOW_SELF_SIGNED=1` |

### Certificate validation

The edge entrypoint checks certificates at startup using:

```
openssl x509 -in <cert> -checkend 86400 -noout
```

A certificate is considered invalid if it is missing, unreadable, or expires within 24 hours.

### ALLOW_SELF_SIGNED

| Value | Behavior |
|-------|----------|
| `0` (default) | Edge exits with code 1 if no valid cert is found. Logs the exact command to issue a cert. |
| `1` | Edge generates a temporary self-signed cert (7-day, RSA 2048) and starts anyway. |

**Keep `ALLOW_SELF_SIGNED=0` in production.** The self-signed fallback exists solely for bootstrapping the first deploy — edge must be running on port 80 before certbot can complete the ACME challenge. Once a real certificate is issued, set it back to `0` so that edge refuses to start if the cert is missing or expired, rather than silently serving untrusted TLS.

## Cloudflare Origin Certificate

If your domain is proxied through Cloudflare (orange cloud enabled), use a Cloudflare Origin Certificate instead of Let's Encrypt.

### 1. Generate in Cloudflare dashboard

Go to **SSL/TLS > Origin Server > Create Certificate** in the Cloudflare dashboard. Download the PEM-format certificate and private key.

### 2. Place on server

```bash
cp origin-cert.pem certs/cloudflare/fullchain.pem
cp origin-key.pem  certs/cloudflare/privkey.pem
```

### 3. Configure and restart

```
TLS_MODE=cloudflare
```

```bash
docker compose restart edge
```

## Certificate Renewal

The `certbot` service runs a renewal loop every 12 hours. When a certificate is actually renewed, certbot's `--deploy-hook` touches a flag file. The edge container polls this file every 5 seconds and reloads nginx when it detects a change. No Docker socket access is required.

The flag file path mapping:

| Context | Path |
|---------|------|
| Host | `./certs/letsencrypt/.reload-flag` |
| certbot container | `/etc/letsencrypt/.reload-flag` |
| edge container | `/etc/letsencrypt/.reload-flag` |

Both containers mount `./certs/letsencrypt:/etc/letsencrypt`, so the flag file is the same physical file accessed via the shared volume.

This happens automatically with no manual intervention.

## Environment Variables

All variables are set in `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `PALFLOW_DOMAIN` | (required) | Domain name for the site |
| `TLS_MODE` | `auto` | Certificate selection: `auto`, `cloudflare`, or `letsencrypt` |
| `ALLOW_SELF_SIGNED` | `0` | Set to `1` to allow self-signed cert fallback |
| `LETSENCRYPT_EMAIL` | (required for LE) | Email for Let's Encrypt registration and expiry notices. Required when using `TLS_MODE=letsencrypt` or when `auto` mode falls back to Let's Encrypt |

## Project Structure

```
palflow/
├── index.html                 # PalFlow app (single-file, HTML/CSS/JS)
├── assets/icons/              # 225 Pal icon PNGs
├── Dockerfile                 # palflow service (nginx:alpine + static files)
├── nginx.conf                 # palflow internal nginx config
├── docker-compose.yml         # 3-service stack
├── .env                       # Domain, TLS mode, self-signed flag
├── .dockerignore              # Build context exclusions
├── edge/
│   ├── Dockerfile             # edge service (nginx:alpine + openssl)
│   ├── entrypoint.sh          # Cert selection + template render + nginx exec
│   └── nginx.template.conf    # Nginx config template (envsubst)
├── certbot/
│   └── renew.sh               # Renewal loop (every 12h, deploy-hook)
├── certs/
│   ├── cloudflare/            # User-placed CF Origin cert (fullchain.pem, privkey.pem)
│   └── letsencrypt/           # Certbot-managed LE certs (auto-populated)
└── acme-webroot/              # Shared volume for ACME challenge files
```

## Commands

### Start / rebuild

```bash
docker compose up -d --build
```

### Stop

```bash
docker compose down
```

### View logs

```bash
docker compose logs edge certbot        # edge + certbot logs
docker compose logs palflow             # app container logs
docker compose logs -f edge             # follow edge logs
```

### Check status

```bash
docker compose ps
```

### Restart edge after cert change

```bash
docker compose restart edge
```

### Issue Let's Encrypt cert (first time)

```bash
docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    -d $PALFLOW_DOMAIN \
    --email $LETSENCRYPT_EMAIL \
    --agree-tos --no-eff-email
```

### Force cert renewal (testing)

```bash
docker compose run --rm certbot renew --force-renewal \
    --webroot -w /var/www/certbot \
    --deploy-hook "touch /etc/letsencrypt/.reload-flag"
```

## Upgrading

After pulling changes to the repository:

```bash
git pull
docker compose up -d --build
```

This rebuilds the `palflow` and `edge` images from their Dockerfiles and restarts only the containers whose images changed. The `certbot` service uses the upstream `certbot/certbot` image and is not rebuilt — Docker will pull a newer version on the next `docker compose pull`.

To update all images including certbot:

```bash
git pull
docker compose pull
docker compose up -d --build
```

Certificates, volumes, and `.env` configuration are preserved across upgrades.

## Troubleshooting

### Edge crash-loops on startup

Expected when `ALLOW_SELF_SIGNED=0` and no valid cert exists. Check logs:

```bash
docker compose logs edge
```

The log will print the exact certbot command to run.

### Port 80/443 already in use

Stop any existing web server on the host:

```bash
sudo systemctl stop nginx apache2 2>/dev/null
```

### Certbot challenge fails

Ensure DNS for your domain points to the server and port 80 is reachable from the internet. The edge container must be running (use `ALLOW_SELF_SIGNED=1` for bootstrap).

### Certificate not picking up after renewal

The edge container polls `certs/letsencrypt/.reload-flag` every 5 seconds. If reload doesn't happen, restart edge manually:

```bash
docker compose restart edge
```
