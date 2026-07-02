# Reverse proxy options

Huly's `front` service is served on a single local port (`HTTP_PORT`, default `8087`), and
the app uses **WebSockets** (the transactor). So any reverse proxy in front of it must
forward WebSocket upgrades and the usual `X-Forwarded-*` headers, and Huly must be told it
is behind TLS so it emits `https`/`wss` URLs.

> [!IMPORTANT]
> Keep Huly's config consistent with the proxy. When you terminate TLS at the proxy, set
> `SECURE=true` and `HOST_ADDRESS=your-domain` in `huly.conf` / `.env`. A mismatch (proxy on
> HTTPS while Huly still emits `http://` / `ws://`) is the usual cause of "Failed to fetch"
> and WebSocket errors after the UI loads.

## nginx (default)

`./setup.sh` generates `nginx.conf`, and `./nginx.sh` keeps `server_name`, `listen`, and
`proxy_pass` in sync with your config. See the main README for the full walk-through.

## Caddy (automatic HTTPS)

[`examples/Caddyfile`](../examples/Caddyfile) fronts Huly with automatic Let's Encrypt TLS
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

A sample Traefik setup lives under [`traefik/`](../traefik). As with the others, set
`SECURE=true` and `HOST_ADDRESS` so Huly emits `https`/`wss`, and make sure the router
forwards WebSockets to the `front` service.
