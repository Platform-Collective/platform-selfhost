#!/usr/bin/env bash
#
# migrate-from-huly.sh - move a Docker Compose install of upstream Huly
# (hcengineering/huly-selfhost, v0.7.x) to this repository, in place.
#
# The data stays where it is: the Docker project name (DOCKER_NAME) and its volumes are
# reused, only the images change to Platform Collective's. On first start the platform's
# own migrations bring the workspaces to this version.
#
# What is carried over from the Huly folder:
#   - config values (host, SSL, ports, title, volume paths, ...) and the secrets
#   - variables that are not in this repository's template -> custom.conf
#   - your changes to upstream compose.yml (added services such as mail, love, github,
#     changed environment, ports, ...) -> compose.override.yml, images switched to
#     platformcollective/*
#   - your changes to .huly.nginx (uncommented locations, extra directives), merged into
#     this repository's version
#   - nginx.conf (host nginx), as is
# Changes are worked out against the pristine upstream files in migration/huly-v0.7.426.
#
# The Huly folder itself is never modified. A backup (backup.sh) is taken before the
# switch unless --skip-backup is given.
#
# Usage: ./migrate-from-huly.sh HULY_DIR [OPTIONS]
#   --dry-run              Only show what would be done (nothing is changed)
#   --yes                  Do not ask for confirmation
#   --skip-backup          Do not run backup.sh before switching
#   --on-conflict=MODE     When you and this repository changed the same setting:
#                          stop (default), ours (keep this repository's), theirs (keep yours)
#   --help

set -euo pipefail

cd "$(dirname "$0")"
REPO=$(pwd)
STATE_DIR="$REPO/.migration"
STAGE="$STATE_DIR/stage"
PLAN="$STATE_DIR/plan.md"
BASE="$REPO/migration/huly-v0.7.426"

HULY_DIR=""
DRY_RUN=false
ASSUME_YES=false
SKIP_BACKUP=false
ON_CONFLICT=stop

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case $arg in
        --dry-run)       DRY_RUN=true ;;
        --yes)           ASSUME_YES=true ;;
        --skip-backup)   SKIP_BACKUP=true ;;
        --on-conflict=*) ON_CONFLICT="${arg#*=}" ;;
        --help|-h)       usage; exit 0 ;;
        -*)              echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
        *)
            if [ -n "$HULY_DIR" ]; then echo "Unexpected argument: $arg" >&2; exit 1; fi
            HULY_DIR="$arg"
            ;;
    esac
done

red()    { echo -e "\033[1;31m$*\033[0m"; }
green()  { echo -e "\033[1;32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue()   { echo -e "\033[1;34m$*\033[0m"; }
die()    { red "$*" >&2; exit 1; }

case "$ON_CONFLICT" in stop|ours|theirs) ;; *) die "--on-conflict must be stop, ours or theirs" ;; esac
[ -n "$HULY_DIR" ] || { usage; exit 1; }
[ -d "$HULY_DIR" ] || die "Not a directory: $HULY_DIR"
HULY_DIR=$(cd "$HULY_DIR" && pwd)
[ "$HULY_DIR" != "$REPO" ] || die "HULY_DIR must be the upstream Huly folder, not this one."

# --------------------------------------------------------------------------- preflight
blue "Checking the Huly install in $HULY_DIR"

[ -f "$HULY_DIR/compose.yml" ] || [ -f "$HULY_DIR/docker-compose.yml" ] || [ -f "$HULY_DIR/docker-compose.yaml" ] \
    || die "No compose file in $HULY_DIR - is this a huly-selfhost checkout?"

HULY_CONF=""
for c in huly_v7.conf .env; do
    if [ -f "$HULY_DIR/$c" ]; then HULY_CONF="$HULY_DIR/$c"; break; fi
done
if [ -z "$HULY_CONF" ]; then
    if [ -f "$HULY_DIR/huly.conf" ]; then
        die "Only huly.conf found: this is a v0.6 (MongoDB) install. Follow the v0.7.204 section of MIGRATION.md instead."
    fi
    die "No huly_v7.conf or .env in $HULY_DIR - run its setup.sh first, or point at the right folder."
fi
echo "  config: $HULY_CONF"

conf_get() { sed -n "s/^$1=//p" "$HULY_CONF" | tail -1 | sed -e "s/^['\"]//" -e "s/['\"]$//"; }
PROJECT=$(conf_get DOCKER_NAME)
PROJECT=${PROJECT:-huly}
echo "  Docker project: $PROJECT"
echo "  version: $(conf_get HULY_VERSION)"

if [ -f "$REPO/huly_v7.conf" ] && [ "$DRY_RUN" = false ]; then
    existing=$(sed -n 's/^DOCKER_NAME=//p' "$REPO/huly_v7.conf" | tail -1)
    if [ -z "${MIGRATE_ALLOW_EXISTING:-}" ]; then
        die "This folder already has an install (huly_v7.conf, project '${existing:-?}'). Migrate into a fresh checkout of this repository."
    fi
fi

docker compose version >/dev/null 2>&1 || die "docker compose (v2) is required."
compose_version=$(docker compose version --short 2>/dev/null | sed 's/^v//')
if [ "$(printf '%s\n' 2.24.4 "$compose_version" | sort -V | head -1)" != "2.24.4" ]; then
    die "Docker Compose $compose_version is too old: compose.override.yml uses !override/!reset (needs 2.24.4+)."
fi

if docker compose --project-directory "$HULY_DIR" -p "$PROJECT" ps -a --format '{{.Image}}' 2>/dev/null | grep -q '^mongo'; then
    die "The Huly stack runs MongoDB: this is a v0.6 install. Follow the v0.7.204 section of MIGRATION.md instead."
fi

# Python 3.8+ for the planner; fall back to a container when the host has none.
run_planner() {
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))'; then
        python3 "$REPO/migration/huly_migrate.py" "$@"
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$REPO:$REPO" -v "$HULY_DIR:$HULY_DIR:ro" -w "$REPO" \
            python:3.12-alpine python3 "$REPO/migration/huly_migrate.py" "$@"
    fi
}

# --------------------------------------------------------------------------- plan
blue "Working out what to carry over"
rm -rf "$STATE_DIR"
mkdir -p "$STAGE"

compose_json() {
    # $1 = project directory, rest = extra args. --no-interpolate keeps ${VARS} as written,
    # --no-path-resolution keeps relative paths, so the output can be written back as is.
    local dir=$1; shift
    docker compose --project-directory "$dir" -p "$PROJECT" "$@" \
        config --format json --no-interpolate --no-path-resolution
}
compose_json "$HULY_DIR" > "$STATE_DIR/user.json" \
    || die "docker compose could not read the Huly compose files (see above)."
compose_json "$BASE" -f "$BASE/compose.yml" > "$STATE_DIR/base.json"
compose_json "$REPO" -f "$REPO/compose.yml" > "$STATE_DIR/ours.json"

set +e
run_planner \
    --repo "$REPO" --huly-dir "$HULY_DIR" --huly-conf "$HULY_CONF" --stage "$STAGE" \
    --project "$PROJECT" --base-compose "$STATE_DIR/base.json" \
    --user-compose "$STATE_DIR/user.json" --ours-compose "$STATE_DIR/ours.json" \
    --base-nginx "$BASE/.huly.nginx" --image-map "$REPO/migration/image-map.txt" \
    --on-conflict "$ON_CONFLICT" --report "$PLAN"
rc=$?
set -e

if [ -f "$HULY_DIR/nginx.conf" ] && [ ! -f "$REPO/nginx.conf" ]; then
    cp -p "$HULY_DIR/nginx.conf" "$STAGE/nginx.conf"
    {
        echo "## Host nginx"
        echo ""
        echo "- \`nginx.conf\` copied as is. If your host nginx includes it by path (sites-enabled),"
        echo "  point that link at \`$REPO/nginx.conf\`."
        echo ""
    } >> "$PLAN"
fi
not_migrated_header=false
for extra in traefik/docker-compose.yaml letsencrypt; do
    if [ -e "$HULY_DIR/$extra" ]; then
        if [ "$not_migrated_header" = false ]; then
            printf '\n## Not migrated\n\n' >> "$PLAN"
            not_migrated_header=true
        fi
        echo "- \`$extra\` exists in the Huly folder and is not migrated automatically: see traefik/README.md here." >> "$PLAN"
    fi
done

echo ""
cat "$PLAN"
echo ""
[ -f "$STAGE/compose.override.yml" ] && { blue "compose.override.yml:"; cat "$STAGE/compose.override.yml"; echo ""; }
[ -f "$STAGE/custom.conf" ] && { blue "custom.conf:"; grep -vE '^#' "$STAGE/custom.conf" | sed -E 's/=.*/=***/'; echo ""; }

case $rc in
    0) ;;
    2) die "Cannot migrate, see 'Cannot migrate' above." ;;
    3) die "Resolve the conflicts above first (or rerun with --on-conflict=ours|theirs)." ;;
    *) die "The planner failed (exit $rc)." ;;
esac

if [ "$DRY_RUN" = true ]; then
    green "Dry run: nothing was changed. Staged files are in $STAGE"
    exit 0
fi

if [ "$ASSUME_YES" = false ]; then
    echo -e "\033[1;33mThe Huly stack '$PROJECT' will be stopped and started again from this folder with Platform Collective images.\033[0m"
    read -r -p "Continue? (y/N): " answer
    case "$answer" in [Yy]*) ;; *) echo "Aborted, nothing was changed."; exit 1 ;; esac
fi

# --------------------------------------------------------------------------- apply
BACKUP_DIR=""
if [ "$SKIP_BACKUP" = false ]; then
    blue "Backing up (backup.sh) - the stack is stopped while volumes are archived"
    # Nothing is written here yet, so backup.sh is pointed at the Huly containers through
    # the project name. Its config/ is then replaced with the Huly originals: the backup
    # is a Huly backup, restored from the Huly folder (see the report).
    if ! COMPOSE_PROJECT_NAME="$PROJECT" docker compose ps -aq 2>/dev/null | grep -q .; then
        die "No containers of project '$PROJECT' found, so nothing can be backed up. Start the Huly stack, or rerun with --skip-backup."
    fi
    COMPOSE_PROJECT_NAME="$PROJECT" "$REPO/backup.sh"
    BACKUP_DIR=$(find "$REPO/backups" -maxdepth 1 -type d -name 'huly-backup-*' | sort | tail -1)
    rm -rf "$BACKUP_DIR/config"
    mkdir -p "$BACKUP_DIR/config"
    for f in huly_v7.conf custom.conf compose.override.yml .huly.nginx nginx.conf .huly.secret .cr.secret .rp.secret; do
        if [ -f "$HULY_DIR/$f" ] && [ ! -L "$HULY_DIR/$f" ]; then cp -p "$HULY_DIR/$f" "$BACKUP_DIR/config/"; fi
    done
    sed -i "s|^HULY_VERSION=.*|HULY_VERSION=$(conf_get HULY_VERSION)|" "$BACKUP_DIR/manifest.txt" 2>/dev/null || true
    echo "migrated-from: $HULY_DIR (restore from that folder to roll back)" >> "$BACKUP_DIR/manifest.txt"
    green "Backup: $BACKUP_DIR"
fi

blue "Writing config into $REPO"
cp -a "$STAGE"/. "$REPO"/
ln -sfn huly_v7.conf "$REPO/.env"

blue "Stopping the Huly stack (data volumes are kept)"
(cd "$HULY_DIR" && docker compose down --remove-orphans)

blue "Starting from this folder (setup.sh, keeping the carried-over values)"
./setup.sh < /dev/null

# --------------------------------------------------------------------------- report
REPORT="$REPO/migration-report.md"
{
    echo "# Migration from Huly: done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "- From: \`$HULY_DIR\` ($(conf_get HULY_VERSION))"
    echo "- To: \`$REPO\` ($(sed -n 's/^HULY_VERSION=//p' "$REPO/huly_v7.conf" | tail -1))"
    echo "- Backup: \`${BACKUP_DIR:-skipped}\`"
    echo ""
    echo "Workspaces are upgraded in the background on first start; watch \`docker compose logs -f workspace\`."
    echo "Desktop app: the upstream Huly app updates from Huly's channel; install the Platform Collective build matching DESKTOP_CHANNEL."
    echo ""
    echo "## Rolling back"
    echo ""
    echo "The database schema is upgraded on first start, so going back needs the backup. It is"
    echo "restored from the Huly folder, with the Huly images and config:"
    echo ""
    echo '```bash'
    echo "cd $REPO && docker compose down"
    if [ -n "$BACKUP_DIR" ]; then
        echo "cp $REPO/restore.sh $HULY_DIR/ && cd $HULY_DIR && ./restore.sh $BACKUP_DIR --yes"
    else
        echo "# no backup was taken (--skip-backup): restore your own backup of the volumes, then"
        echo "cd $HULY_DIR && docker compose up -d"
    fi
    echo '```'
    echo ""
    tail -n +2 "$PLAN"
} > "$REPORT"

blue "Waiting for services"
for _ in $(seq 1 60); do
    if ./healthcheck.sh >/dev/null 2>&1; then break; fi
    sleep 5
done
./healthcheck.sh || yellow "Some services are not healthy yet - check 'docker compose ps' and the logs."

green "Migration finished. Report: $REPORT"
