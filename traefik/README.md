# Instructions to deploy Huly on a `self-hosted` server with SSL using `Traefik`

### Prerequisites

- A domain name pointing to the server
- A server with Docker and Docker Compose installed

### Steps

1. Clone the repository

   ```bash
   git clone https://github.com/Platform-Collective/platform-selfhost.git
   cd platform-selfhost/traefik
   ```

2. Run setup.sh

   ```bash
   chmod +x setup.sh
   ./setup.sh
   ```

3. Follow the instructions in the setup script to configure your domain name and email address

   ```bash
   $ ./setup.sh
   Enter the domain name: example.com
   Enter the email address: admin@example.com
   Setup is complete. Run 'docker compose up -d' to start the services.
   ```

4. Modify the `docker-compose.yaml` file to customize any settings

5. Start the services

   ```bash
   docker compose up -d
   ```

6. Access Huly at `https://example.com`

### Upgrading Traefik

`docker-compose.yaml` is generated once from `template-compose.yaml`, so a new Traefik version
in the template does not reach an existing install by itself. Re-running `setup.sh` would
overwrite your customizations, so update the image line instead:

```bash
sed -i 's|image: "traefik:v2.10"|image: "traefik:v3.7"|' docker-compose.yaml
docker compose pull traefik
docker compose up -d traefik
```

The labels and command-line flags used here are unchanged in Traefik v3, and the existing
`letsencrypt/acme.json` is reused, so certificates are not re-issued. The `v3.7` tag follows
patch releases: run `docker compose pull traefik && docker compose up -d traefik` regularly to
pick up security fixes.
