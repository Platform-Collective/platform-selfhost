# Serving the platform with Traefik (automatic HTTPS)

Instead of a host nginx, you can put [Traefik](https://traefik.io/traefik/) in front of the
platform. It runs as one more container in the same Compose project, gets certificates from
Let's Encrypt (or uses your own), redirects HTTP to HTTPS, and forwards everything to the
bundled nginx container, which keeps doing the platform routing.

```
browser ──https──> traefik (80/443) ──http──> nginx (bundled) ──> front, account, transactor, ...
```

It is enabled with the [`compose.traefik.yml`](../compose.traefik.yml) override, the same way as
the PostgreSQL setup. Traefik reads only its generated config files and does not need access to
the Docker socket.

## Prerequisites

- A domain name pointing to the server, and ports 80 and 443 reachable from the internet
  (Let's Encrypt validates on 443)
- Docker with Docker Compose v2.24.4 or newer
- No other web server on ports 80/443. If you followed the nginx instructions before, stop it:
  `sudo systemctl disable --now nginx`

## Setup

1. Configure the platform, with your domain as the host address and SSL enabled:

   ```bash
   git clone https://github.com/Platform-Collective/platform-selfhost.git
   cd platform-selfhost
   ./setup.sh
   ```

   Answer the host address with the bare domain (`huly.example.com`, no port) and `y` to
   serving over SSL. You can let it start the stack; skip the nginx steps from the main README.

2. Configure Traefik:

   ```bash
   traefik/setup.sh
   ```

   It asks for:
   - **Certificates**: `acme` (Let's Encrypt, the default; needs an e-mail address) or `files`
     (your own certificate and key in PEM, copied to `traefik/certs/`)
   - **Dashboard**: off by default. When enabled, it is served on
     `https://<domain>:8443/dashboard/` behind a login; the password is generated unless you set
     one, and kept in `traefik/.dashboard.password`

   It writes the config to `traefik/config/`, adds `compose.traefik.yml` to `COMPOSE_FILE` in
   `huly_v7.conf` (so plain `docker compose` commands use it) and starts the stack.

3. Open `https://<domain>`.

The bundled nginx is no longer published on `HTTP_PORT`: it is only reachable through Traefik.

To test the setup without hitting Let's Encrypt rate limits, run it with
`LETSENCRYPT_STAGING=1 traefik/setup.sh` (browsers will not trust those certificates), then
re-run without it and delete `traefik/letsencrypt/acme.json`.

## Changing the settings

Re-run `traefik/setup.sh`; it overwrites the generated config and restarts Traefik.
Re-running `./setup.sh` keeps Traefik enabled. If you change the host address there, re-run
`traefik/setup.sh` afterwards.

All questions can also be answered through environment variables, for automation; see the top
of [`setup.sh`](setup.sh).

## Updating Traefik

The image tag `traefik:v3.7` follows patch releases. To pick up security fixes:

```bash
docker compose pull traefik
docker compose up -d traefik
```

## Files

| Path | Tracked | Contents |
|---|---|---|
| `compose.traefik.yml` | yes | the Compose override |
| `traefik/setup.sh` | yes | generates the config |
| `traefik/config/` | no | generated `traefik.yml` (static) and `dynamic.yml` (routes, TLS, dashboard login) |
| `traefik/letsencrypt/acme.json` | no | Let's Encrypt account and certificates |
| `traefik/certs/` | no | your own certificate and key (`files` mode) |
| `traefik/.dashboard.password` | no | dashboard password |

`backup.sh` includes the whole `traefik/` folder.
