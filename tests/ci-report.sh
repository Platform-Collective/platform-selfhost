#!/usr/bin/env bash
#
# tests/ci-report.sh - on a failed CI run, turn container state and the tail of
# service logs into GitHub annotations, so the cause is visible on the PR
# without downloading logs.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 0

annotate() { # annotate <title> <file>
  local msg
  msg=$(tail -c 3500 "$2")
  msg=${msg//'%'/'%25'}; msg=${msg//$'\r'/}; msg=${msg//$'\n'/'%0A'}
  echo "::error title=$1::$msg"
}

docker compose ps -a --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' > /tmp/ci-ps.txt 2>&1
annotate "docker compose ps" /tmp/ci-ps.txt

# services that are not running, unhealthy or restarted: show their last log lines
n=0
for cid in $(docker compose ps -aq); do
  read -r svc state health restarts < <(docker inspect "$cid" --format \
    '{{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}}')
  if [ "$state" != running ] || [ "$health" = unhealthy ] || [ "${restarts:-0}" -gt 0 ]; then
    {
      docker logs --tail 15 "$cid" 2>&1 | cut -c1-300
      if [ "$health" != - ]; then
        echo "--- last healthcheck output:"
        docker inspect "$cid" --format '{{range .State.Health.Log}}exit={{.ExitCode}} {{.Output}}{{end}}' | tail -c 800
      fi
    } > "/tmp/ci-$svc.log"
    annotate "$svc: $state/$health, restarts=$restarts" "/tmp/ci-$svc.log"
    n=$((n + 1))
  fi
  [ "$n" -ge 5 ] && break # GitHub shows at most 10 annotations per step
done

# errors from the services the smoke test talks to
for svc in account workspace transactor front; do
  docker compose logs --no-color --tail 400 "$svc" 2>/dev/null \
    | grep -iE 'error|exception|fatal' \
    | sed -E 's/"timestamp":"[^"]*"//; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z//g' | awk '!seen[$0]++' \
    | tail -8 | cut -c1-400 > "/tmp/ci-err-$svc.log"
  [ -s "/tmp/ci-err-$svc.log" ] && annotate "$svc errors" "/tmp/ci-err-$svc.log"
done
exit 0
