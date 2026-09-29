#!/usr/bin/env bash
#
# tests/smoke.sh - end-to-end smoke test of a running Docker Compose deployment.
#
# Talks to the stack only through its public URL (the bundled nginx), the same
# way a browser does, so it also catches broken proxy routes and wrong public
# URLs in the service config.
#
# Usage:
#   tests/smoke.sh            fresh check: sign up a new user, create a workspace,
#                             upload a file; saves what it created to tests/.smoke-state
#   tests/smoke.sh --verify   re-check data created by an earlier run (e.g. after an
#                             upgrade): log in as that user, wait for the workspace
#                             to become active again, download the same file
#
# Env:
#   HULY_URL       public URL (default: from .env HOST_ADDRESS/SECURE)
#   SMOKE_TIMEOUT  seconds to wait for the stack / workspace (default: 600)

set -euo pipefail
cd "$(dirname "$0")/.."

MODE=fresh
case "${1:-}" in
  --verify) MODE=verify ;;
  --help)   sed -n '2,20p' "$0"; exit 0 ;;
  "")       ;;
  *)        echo "Unknown option: $1" >&2; exit 2 ;;
esac

STATE_FILE=tests/.smoke-state
TIMEOUT=${SMOKE_TIMEOUT:-600}

if [ -z "${HULY_URL:-}" ]; then
  # shellcheck disable=SC1091
  [ -f .env ] && source .env
  HULY_URL="http${SECURE:+s}://${HOST_ADDRESS:?HOST_ADDRESS is not set, run setup.sh or pass HULY_URL}"
fi
HULY_URL=${HULY_URL%/}

step() { rm -f /tmp/smoke-last-rpc.log; echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()   { echo -e "    \033[32mok\033[0m  $*"; }
fail() {
  echo -e "    \033[31mFAIL\033[0m $*" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # annotation: visible on the PR without opening the log; attach extra context if any
    local msg="$*" ctx="" f=${FAIL_CONTEXT:-/tmp/smoke-last-rpc.log}
    [ -f "$f" ] && ctx=$(tail -c 3000 "$f")
    [ -n "$ctx" ] && msg="$msg"$'\n'"$ctx"
    msg=${msg//'%'/'%25'}; msg=${msg//$'\r'/}; msg=${msg//$'\n'/'%0A'}
    echo "::error title=smoke.sh ($MODE)::$msg"
  fi
  exit 1
}

# retry <seconds> <command...>: retry every 5s until the command succeeds
retry() {
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# JSON-RPC call to the account service. Prints .result, fails on .error.
# rpc <token|""> <method> <params-json>
rpc() {
  local token=$1 method=$2 params=$3 resp
  resp=$(curl -sS --max-time 30 -X POST "$ACCOUNTS_URL" \
    -H 'Content-Type: application/json' \
    ${token:+-H "Authorization: Bearer $token"} \
    -d "{\"method\":\"$method\",\"params\":$params}") || return 1
  if ! jq -e '.error == null and .result != null' >/dev/null 2>&1 <<<"$resp"; then
    echo "    $method -> $resp" >&2
    echo "$method -> $resp" > /tmp/smoke-last-rpc.log
    return 1
  fi
  jq -c .result <<<"$resp"
}

echo "Target: $HULY_URL (mode: $MODE)"

# ---------------------------------------------------------------------------
step "Containers are up (healthcheck.sh)"
if ! retry "$TIMEOUT" ./healthcheck.sh >/tmp/smoke-health.log 2>&1; then
  cat /tmp/smoke-health.log
  FAIL_CONTEXT=/tmp/smoke-health.log fail "services did not become healthy within ${TIMEOUT}s"
fi
ok "all services running"

# ---------------------------------------------------------------------------
step "Front and public config"
retry 120 curl -fsS --max-time 10 -o /dev/null "$HULY_URL/" || fail "GET $HULY_URL/ did not return 2xx"
curl -fsS "$HULY_URL/" | grep -qi '<html' || fail "front did not return HTML"
ok "GET / returns HTML"

CONFIG=$(curl -fsS "$HULY_URL/config.json") || fail "GET /config.json failed"
ACCOUNTS_URL=$(jq -er .ACCOUNTS_URL <<<"$CONFIG") || fail "config.json has no ACCOUNTS_URL"

# Every browser-facing URL must point at the public address, not at an
# internal service name or a leftover localhost port.
for key in ACCOUNTS_URL COLLABORATOR_URL REKONI_URL; do
  val=$(jq -r ".$key // empty" <<<"$CONFIG")
  [ -z "$val" ] && fail "config.json: $key is missing"
  host=$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$val")
  [ "$host" = "${HULY_URL#*://}" ] || fail "config.json: $key=$val does not point at ${HULY_URL#*://}"
  ok "$key=$val"
done
upload=$(jq -r '.UPLOAD_URL // empty' <<<"$CONFIG")
[[ "$upload" == /* || "$upload" == "$HULY_URL"* ]] || fail "config.json: UPLOAD_URL=$upload is not public"
ok "UPLOAD_URL=$upload"

retry 120 curl -fsS --max-time 10 -o /dev/null "$ACCOUNTS_URL/api/v1/statistics" \
  || fail "account service is not reachable at $ACCOUNTS_URL"
ok "account service responds through the proxy"

# ---------------------------------------------------------------------------
if [ "$MODE" = fresh ]; then
  step "Sign up and log in"
  SMOKE_EMAIL="smoke-$(date +%s)-$RANDOM@example.com"
  SMOKE_PASSWORD="Smoke-$(openssl rand -hex 6)"
  # the account service may still be running migrations right after start
  retry 180 rpc "" signUp "{\"email\":\"$SMOKE_EMAIL\",\"password\":\"$SMOKE_PASSWORD\",\"firstName\":\"Smoke\",\"lastName\":\"Test\"}" >/dev/null \
    || fail "signUp failed"
  ok "signed up $SMOKE_EMAIL"
else
  step "Log in as the user from the previous run"
  [ -f "$STATE_FILE" ] || fail "$STATE_FILE not found; run without --verify first"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

LOGIN=$(retry 180 rpc "" login "{\"email\":\"$SMOKE_EMAIL\",\"password\":\"$SMOKE_PASSWORD\"}") || fail "login failed"
TOKEN=$(jq -er .token <<<"$LOGIN") || fail "login returned no token"
ok "login returns a token"

bad=$(rpc "" login "{\"email\":\"$SMOKE_EMAIL\",\"password\":\"wrong-password\"}" 2>/dev/null || true)
[ -z "$bad" ] || fail "login with a wrong password succeeded"
ok "login with a wrong password is rejected"

# ---------------------------------------------------------------------------
if [ "$MODE" = fresh ]; then
  step "Create workspace"
  WS=$(rpc "$TOKEN" createWorkspace '{"workspaceName":"Smoke"}') || fail "createWorkspace failed"
  SMOKE_WS_URL=$(jq -er .workspaceUrl <<<"$WS")
  ok "workspace '$SMOKE_WS_URL' requested"
else
  step "Workspace from the previous run"
fi

SEL=$(rpc "$TOKEN" selectWorkspace "{\"workspaceUrl\":\"$SMOKE_WS_URL\"}") || fail "selectWorkspace failed"
WS_TOKEN=$(jq -er .token <<<"$SEL")
ENDPOINT=$(jq -er .endpoint <<<"$SEL")

ws_mode() { rpc "$WS_TOKEN" getWorkspaceInfo '{"updateLastVisit":false}' | jq -r '.status.mode // .mode // empty'; }
ws_active() { local m; m=$(ws_mode) || return 1; echo "    mode: ${m:-?}"; [ "$m" = active ]; }
# creation (fresh) or migration after an upgrade (verify) is done by the workspace service
retry "$TIMEOUT" ws_active || fail "workspace did not become active within ${TIMEOUT}s (workspace service / migrations)"
ok "workspace is active"

# ---------------------------------------------------------------------------
step "Transactor websocket through the proxy"
[ "$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$ENDPOINT")" = "${HULY_URL#*://}" ] \
  || fail "transactor endpoint $ENDPOINT does not point at the public address"
ws_http=${ENDPOINT/#ws/http}
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --http1.1 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
  "$ws_http/$WS_TOKEN" 2>/dev/null || true)
[ "$code" = 101 ] || fail "websocket upgrade to $ENDPOINT returned HTTP ${code:-none}, expected 101"
ok "websocket upgrade -> 101"

# ---------------------------------------------------------------------------
step "File storage"
if [ "$MODE" = fresh ]; then
  SMOKE_FILE_CONTENT="smoke $(date -u +%FT%TZ) $RANDOM"
  printf '%s' "$SMOKE_FILE_CONTENT" > /tmp/smoke-upload.txt
  up=$(curl -fsS --max-time 30 -X POST "$HULY_URL/files" \
    -H "Authorization: Bearer $WS_TOKEN" -F "file=@/tmp/smoke-upload.txt;type=text/plain") \
    || fail "upload to $HULY_URL/files failed"
  SMOKE_FILE_ID=$(jq -er '.[0].id' <<<"$up") || fail "upload returned no id: $up"
  ok "uploaded file $SMOKE_FILE_ID"
fi
got=$(curl -fsS --max-time 30 -H "Authorization: Bearer $WS_TOKEN" "$HULY_URL/files?file=$SMOKE_FILE_ID") \
  || fail "download of $SMOKE_FILE_ID failed"
[ "$got" = "$SMOKE_FILE_CONTENT" ] || fail "downloaded content differs: '$got'"
ok "file downloads with the same content"

# ---------------------------------------------------------------------------
step "No crash loops"
restarting=$(docker compose ps --format '{{.Service}} {{.State}}' | awk '$2=="restarting"{print $1}')
[ -z "$restarting" ] || fail "restarting: $restarting"
docker compose ps -q | xargs docker inspect --format '{{.Name}} restarts={{.RestartCount}}' \
  | awk -F'restarts=' '$2>0{print "    note: " $0}'
ok "no service is restarting"

if [ "$MODE" = fresh ]; then
  {
    printf 'SMOKE_EMAIL=%q\n' "$SMOKE_EMAIL"
    printf 'SMOKE_PASSWORD=%q\n' "$SMOKE_PASSWORD"
    printf 'SMOKE_WS_URL=%q\n' "$SMOKE_WS_URL"
    printf 'SMOKE_FILE_ID=%q\n' "$SMOKE_FILE_ID"
    printf 'SMOKE_FILE_CONTENT=%q\n' "$SMOKE_FILE_CONTENT"
  } > "$STATE_FILE"
fi

echo -e "\n\033[1;32mSmoke test passed ($MODE).\033[0m"
