# Reverse proxy options

The platform's `front` service is served on a single local port (`HTTP_PORT`, default `8087`), and
the app uses **WebSockets** (the transactor). So any reverse proxy in front of it must
forward WebSocket upgrades and the usual `X-Forwarded-*` headers, and the platform must be told it
is behind TLS so it emits `https`/`wss` URLs.

> [!IMPORTANT]
> Keep the platform config consistent with the proxy. When you terminate TLS at the proxy, set
> `SECURE=true` and `HOST_ADDRESS=your-domain` in `huly.conf` / `.env`. A mismatch (proxy on
> HTTPS while the platform still emits `http://` / `ws://`) is the usual cause of "Failed to fetch"
> and WebSocket errors after the UI loads.

## nginx (default)

`./setup.sh` generates `nginx.conf`, and `./nginx.sh` keeps `server_name`, `listen`, and
`proxy_pass` in sync with your config. See the main README for the full walk-through.

## Caddy (automatic HTTPS)

[`examples/Caddyfile`](../examples/Caddyfile) fronts the platform with automatic Let's Encrypt TLS
and transparent WebSocket support - no manual certificates, no renewal cron:

```caddy
huly.example.com {
    reverse_proxy 127.0.0.1:8087
}
```

Set `HTTP_BIND=127.0.0.1`, `HTTP_PORT=8087`, `SECURE=true`, and `HOST_ADDRESS=huly.example.com`
in your config, then run `caddy run --config ./Caddyfile` (or point your system Caddy at the
file). Caddy handles certificate issuance/renewal and the WebSocket upgrade for you.

## Traefik

Traefik runs as a container next to the platform and replaces the host nginx: it gets
certificates from Let's Encrypt (or uses your own), redirects HTTP to HTTPS, and forwards
everything to the bundled nginx container. Run `./setup.sh` with your domain and SSL enabled,
then `traefik/setup.sh`. See [`traefik/README.md`](../traefik/README.md).
