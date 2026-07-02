#!/usr/bin/env bash
#
# healthcheck.sh - quick health check of a Docker Compose deployment.
#
# Reports every service's container status (and Docker health, where a service defines
# a healthcheck), and optionally whether the front is reachable. Exits 0 if all services
# are running and none are unhealthy, non-zero otherwise - so it is usable in cron/CI or
# a monitoring probe. Read-only; does not touch the stack.
#
# Usage: ./healthcheck.sh [--help]

set -uo pipefail

cd "$(dirname "$0")" || exit 1

case "${1:-}" in
    --help)
        echo "Usage: $0"
        echo "Checks that all Compose services are running (and healthy where a healthcheck"
        echo "is defined), plus front reachability if the port is known. Exit 0 = all good."
        exit 0
        ;;
esac

if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "Error: docker compose is not available." >&2
    exit 1
fi

# Portable array fill (avoid mapfile; not present in bash 3.x).
SERVICES=()
while IFS= read -r line; do
    [ -n "$line" ] && SERVICES+=("$line")
done < <($COMPOSE config --services 2>/dev/null | sort)
if [ "${#SERVICES[@]}" -eq 0 ]; then
    echo "No services found. Run this from the directory with compose.yml." >&2
    exit 1
fi

bad=0
printf '%-14s %-12s %s\n' "SERVICE" "STATE" "HEALTH"
for svc in "${SERVICES[@]}"; do
    cid=$($COMPOSE ps -aq "$svc" 2>/dev/null | head -1)
    if [ -z "$cid" ]; then
        printf '%-14s %-12s %s\n' "$svc" "no-container" "-"
        bad=1
        continue
    fi
    state=$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null)
    health=$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' 2>/dev/null)
    printf '%-14s %-12s %s\n' "$svc" "${state:-unknown}" "${health:-'-'}"
    [ "$state" = "running" ] || bad=1
    [ "$health" = "unhealthy" ] && bad=1
done

# Optional: front reachability, if we can determine the local HTTP port from config.
PORT=$(grep -hE '^HTTP_PORT=' .env huly.conf huly_v7.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d '[:space:]')
if [ -n "${PORT:-}" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://localhost:${PORT}" 2>/dev/null || true)
    case "$code" in
        200|301|302) echo "front: http://localhost:${PORT} -> HTTP $code (reachable)" ;;
        *)           echo "front: http://localhost:${PORT} -> ${code:-no response}"; bad=1 ;;
    esac
fi

if [ "$bad" -eq 0 ]; then
    echo -e "\033[1;32mOK: all services running.\033[0m"
    exit 0
else
    echo -e "\033[31mPROBLEM: one or more services are not running/healthy.\033[0m Check 'docker compose ps' and logs."
    exit 1
fi
