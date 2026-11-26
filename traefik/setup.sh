#!/usr/bin/env bash
#
# traefik/setup.sh - serve the platform through Traefik (automatic HTTPS) instead of a
# host nginx.
#
# Run ./setup.sh in the repository root first, with your domain as the host address and
# SSL enabled, then run this script. It:
#   - writes traefik/config/traefik.yml and traefik/config/dynamic.yml (generated, not tracked)
#   - adds compose.traefik.yml to COMPOSE_FILE in huly_v7.conf
#   - optionally runs `docker compose up -d`
# Re-run it to change the settings; it overwrites the generated config.
#
# All questions can be answered through the environment (for automation / CI):
#   TRAEFIK_TLS          acme (default): Let's Encrypt; files: your own certificate
#   LETSENCRYPT_EMAIL    contact e-mail for Let's Encrypt (acme)
#   LETSENCRYPT_STAGING  1 = use the Let's Encrypt staging CA (test certificates, not trusted)
#   TRAEFIK_CERT         certificate file, full chain in PEM (files); copied to traefik/certs/
#   TRAEFIK_KEY          private key file in PEM (files); copied to traefik/certs/
#   TRAEFIK_DASHBOARD    yes / no (default: no)
#   DASHBOARD_USER       dashboard login (default: admin)
#   DASHBOARD_PASSWORD   dashboard password (default: generated, kept in traefik/.dashboard.password)
#   TRAEFIK_START        yes / no: run `docker compose up -d` at the end

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG_FILE=huly_v7.conf
COMPOSE_OVERRIDE=compose.traefik.yml
CONF_DIR=traefik/config
CERT_DIR=traefik/certs
PASSWORD_FILE=traefik/.dashboard.password

die() { echo -e "\033[1;31m$*\033[0m" >&2; exit 1; }

# ask VAR "question" [default]: keep VAR if it is already set, otherwise prompt
ask() {
  local var=$1 question=$2 default=${3:-} input=""
  [ -n "${!var:-}" ] && return
  read -r -p "$question${default:+ [$default]}: " input || true
  printf -v "$var" '%s' "${input:-$default}"
}

yes_no() { case "$1" in [Yy]*) return 0 ;; *) return 1 ;; esac }

[ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE not found. Run ./setup.sh first (host address = your domain, SSL = yes)."

HOST_ADDRESS=$(sed -n 's/^HOST_ADDRESS=//p' "$CONFIG_FILE" | tail -1)
SECURE=$(sed -n 's/^SECURE=//p' "$CONFIG_FILE" | tail -1)

[ -n "$HOST_ADDRESS" ] || die "HOST_ADDRESS is empty in $CONFIG_FILE. Run ./setup.sh first."
case "$HOST_ADDRESS" in
  *:*) die "HOST_ADDRESS=$HOST_ADDRESS contains a port. Traefik serves the platform on 443: re-run ./setup.sh with the bare domain." ;;
esac
[ "$SECURE" = true ] || die "SECURE is not 'true' in $CONFIG_FILE. Re-run ./setup.sh and answer 'y' to serving over SSL."

# --- TLS ---------------------------------------------------------------------------
ask TRAEFIK_TLS "Certificates: 'acme' (Let's Encrypt, automatic) or 'files' (your own)" acme
case "$TRAEFIK_TLS" in
  acme)
    if [[ "$HOST_ADDRESS" == localhost || "$HOST_ADDRESS" =~ ^[0-9.]+$ ]]; then
      die "Let's Encrypt needs a public domain name, not '$HOST_ADDRESS'. Use TRAEFIK_TLS=files with your own certificate."
    fi
    ask LETSENCRYPT_EMAIL "E-mail for Let's Encrypt (expiry notices)"
    [ -n "$LETSENCRYPT_EMAIL" ] || die "An e-mail address is required for Let's Encrypt."
    TLS_BLOCK="      tls:
        certResolver: letsencrypt"
    ;;
  files)
    ask TRAEFIK_CERT "Certificate file (PEM, full chain)"
    ask TRAEFIK_KEY "Private key file (PEM)"
    [ -f "$TRAEFIK_CERT" ] || die "Certificate file not found: $TRAEFIK_CERT"
    [ -f "$TRAEFIK_KEY" ] || die "Key file not found: $TRAEFIK_KEY"
    mkdir -p "$CERT_DIR"
    # copy unless the file already is the target (e.g. placed there by hand)
    [ "$TRAEFIK_CERT" -ef "$CERT_DIR/cert.pem" ] || cp "$TRAEFIK_CERT" "$CERT_DIR/cert.pem"
    [ "$TRAEFIK_KEY" -ef "$CERT_DIR/key.pem" ] || cp "$TRAEFIK_KEY" "$CERT_DIR/key.pem"
    chmod 644 "$CERT_DIR/key.pem" # read by the traefik container; the folder is not tracked
    TLS_BLOCK="      tls: {}"
    ;;
  *) die "Unknown TRAEFIK_TLS '$TRAEFIK_TLS' (expected 'acme' or 'files')." ;;
esac

# --- Dashboard -----------------------------------------------------------------------
ask TRAEFIK_DASHBOARD "Enable the Traefik dashboard on https://$HOST_ADDRESS:8443/dashboard/ (password-protected)? (y/N)" n
DASHBOARD=false
if yes_no "$TRAEFIK_DASHBOARD"; then
  DASHBOARD=true
  ask DASHBOARD_USER "Dashboard user" admin
  if [ -z "${DASHBOARD_PASSWORD:-}" ] && [ -f "$PASSWORD_FILE" ]; then
    DASHBOARD_PASSWORD=$(cat "$PASSWORD_FILE")
    echo "Using the dashboard password from $PASSWORD_FILE."
  fi
  if [ -z "${DASHBOARD_PASSWORD:-}" ]; then
    DASHBOARD_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')
    echo -e "Generated dashboard password for '$DASHBOARD_USER': \033[1;33m$DASHBOARD_PASSWORD\033[0m"
  fi
  (umask 077 && printf '%s\n' "$DASHBOARD_PASSWORD" > "$PASSWORD_FILE")
  echo "Dashboard password stored in $PASSWORD_FILE."
  if command -v htpasswd >/dev/null 2>&1; then
    DASHBOARD_HASH=$(htpasswd -nbB "$DASHBOARD_USER" "$DASHBOARD_PASSWORD")
  else
    DASHBOARD_HASH="$DASHBOARD_USER:$(openssl passwd -apr1 "$DASHBOARD_PASSWORD")"
  fi
fi

# --- Generate config ---------------------------------------------------------------------
mkdir -p "$CONF_DIR" "$CERT_DIR" traefik/letsencrypt

{
  cat <<YAML
# Generated by traefik/setup.sh - re-run it instead of editing this file.
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        # Traefik v3 defaults to 60s, which cuts off large uploads on slow connections.
        readTimeout: 600s
YAML
  if $DASHBOARD; then
    cat <<YAML
  dashboard:
    address: ":8443"

api:
  dashboard: true
YAML
  fi
  cat <<YAML

providers:
  file:
    filename: /etc/traefik/dynamic.yml
YAML
  if [ "$TRAEFIK_TLS" = acme ]; then
    cat <<YAML

certificatesResolvers:
  letsencrypt:
    acme:
      email: "$LETSENCRYPT_EMAIL"
      storage: /letsencrypt/acme.json
      tlsChallenge: {}
YAML
    if [ "${LETSENCRYPT_STAGING:-}" = 1 ]; then
      echo '      caServer: https://acme-staging-v02.api.letsencrypt.org/directory'
    fi
  fi
} > "$CONF_DIR/traefik.yml"

{
  cat <<YAML
# Generated by traefik/setup.sh - re-run it instead of editing this file.
http:
  routers:
    platform:
      entryPoints: [websecure]
      rule: "Host(\`$HOST_ADDRESS\`)"
      service: platform
$TLS_BLOCK
YAML
  if $DASHBOARD; then
    cat <<YAML
    dashboard:
      entryPoints: [dashboard]
      rule: "Host(\`$HOST_ADDRESS\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`))"
      service: api@internal
      middlewares: [dashboard-auth]
$TLS_BLOCK

  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - '$DASHBOARD_HASH'
YAML
  fi
  cat <<YAML

  services:
    platform:
      loadBalancer:
        servers:
          # the bundled nginx container, which routes to the platform services
          - url: "http://nginx:80"
YAML
  if [ "$TRAEFIK_TLS" = files ]; then
    cat <<YAML

tls:
  stores:
    default:
      defaultCertificate:
        certFile: /certs/cert.pem
        keyFile: /certs/key.pem
YAML
  fi
} > "$CONF_DIR/dynamic.yml"

# --- Enable the compose override ---------------------------------------------------------
current=$(sed -n 's/^COMPOSE_FILE=//p' "$CONFIG_FILE" | tail -1)
case ":$current:" in
  *":$COMPOSE_OVERRIDE:"*) ;;
  "::") printf '\n# Traefik in front of the platform (traefik/setup.sh). setup.sh keeps this line.\nCOMPOSE_FILE=compose.yml:%s\n' "$COMPOSE_OVERRIDE" >> "$CONFIG_FILE" ;;
  *) sed -i.bak "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$current:$COMPOSE_OVERRIDE|" "$CONFIG_FILE" && rm -f "$CONFIG_FILE.bak" ;;
esac

echo -e "\n\033[1;32mTraefik is configured.\033[0m"
echo -e "Platform:  \033[1;36mhttps://$HOST_ADDRESS\033[0m"
$DASHBOARD && echo -e "Dashboard: \033[1;36mhttps://$HOST_ADDRESS:8443/dashboard/\033[0m (user '$DASHBOARD_USER')"
if command -v nginx >/dev/null 2>&1; then
  echo -e "\033[33mA host nginx is installed. Stop it (or free ports 80/443) before starting Traefik:\033[0m"
  echo "  sudo systemctl disable --now nginx"
fi

ask TRAEFIK_START "Run 'docker compose up -d' now? (Y/n)" y
if yes_no "$TRAEFIK_START"; then
  docker compose up -d
  # the config is read at startup: pick up a re-generated one
  docker compose restart traefik
else
  echo "Run 'docker compose up -d' when ready."
fi
