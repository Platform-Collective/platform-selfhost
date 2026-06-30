#!/usr/bin/env bash
#
# backup.sh - Offline backup of a Docker Compose deployment.
#
# Creates a timestamped, self-contained backup of everything needed to restore the
# deployment: the CockroachDB data, the MinIO file store, and the local config and
# secret files. The stack is stopped only while the volumes are archived so the copy
# is crash-consistent, then restarted immediately. This is the recommended backup to
# take before a version upgrade (see MIGRATION.md).
#
# The search index (elastic) and event log (redpanda) are skipped by default: they
# are rebuilt automatically and are not required to restore. Use --full to include
# them.
#
# Usage: ./backup.sh [--output=DIR] [--keep=N] [--full] [--help]

set -euo pipefail

cd "$(dirname "$0")"

OUTPUT_DIR="./backups"
KEEP=0
FULL=false

for arg in "$@"; do
    case $arg in
        --output=*) OUTPUT_DIR="${arg#*=}" ;;
        --keep=*)   KEEP="${arg#*=}" ;;
        --full)     FULL=true ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --output=DIR  Directory to write backups into (default: ./backups)"
            echo "  --keep=N      Keep only the N most recent backups (default: keep all)"
            echo "  --full        Also back up the search index (elastic) and event log (redpanda)"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "Error: docker compose is not available." >&2
    exit 1
fi

# Always bring the stack back up, even if archiving fails partway through, so a
# failed backup can never leave the deployment stopped.
STOPPED=false
restart_stack() {
    if [ "$STOPPED" = true ]; then
        echo "Ensuring the stack is running again..."
        $COMPOSE start || echo -e "\033[31mWARNING: could not restart the stack - check 'docker compose ps'.\033[0m"
        STOPPED=false
    fi
}
trap restart_stack EXIT

# Print the host source (named volume or bind path) backing the given mount
# destination on a specific container, or nothing.
source_on() {
    # $1 = container id, $2 = mount destination
    docker inspect "$1" --format \
        "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}" 2>/dev/null || true
}

# Resolve the volume backing a mount destination. Try the expected service name
# first; if that service does not exist (deployments differ, e.g. "cockroach" vs
# "cockroachdb"), scan every container in the project for the destination.
# Always exits 0 (prints nothing when not found) so it is safe under `set -e`.
mount_source() {
    # $1 = expected service name, $2 = mount destination
    local cid src
    cid=$($COMPOSE ps -aq "$1" 2>/dev/null | head -1 || true)
    if [ -n "$cid" ]; then
        src=$(source_on "$cid" "$2")
        [ -n "$src" ] && { echo "$src"; return 0; }
    fi
    for cid in $($COMPOSE ps -aq 2>/dev/null || true); do
        src=$(source_on "$cid" "$2")
        [ -n "$src" ] && { echo "$src"; return 0; }
    done
    return 0
}

# Archive a volume or bind path into the backup directory.
archive() {
    # $1 = source (volume name or host path), $2 = output tar name, $3 = label
    if [ -z "$1" ]; then
        echo -e "  \033[33mskipping $3 (not found)\033[0m"
        return 0
    fi
    echo "  - $3 -> $2"
    docker run --rm -v "$1":/data:ro -v "$DEST_ABS":/backup alpine \
        tar czf "/backup/$2" -C /data .
}

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$OUTPUT_DIR/huly-backup-$STAMP"
mkdir -p "$DEST/config"
DEST_ABS=$(cd "$DEST" && pwd)

echo -e "\033[1;34mResolving data volumes...\033[0m"
CR_SRC=$(mount_source cockroach /cockroach/cockroach-data)
FILES_SRC=$(mount_source minio /data)
MONGO_SRC=$(mount_source mongodb /data/db)
ELASTIC_SRC=$(mount_source elastic /usr/share/elasticsearch/data)
REDPANDA_SRC=$(mount_source redpanda /var/lib/redpanda/data)

echo "Stopping stack for a consistent snapshot..."
$COMPOSE stop
STOPPED=true

echo "Archiving data volumes..."
archive "$CR_SRC" cockroach.tar.gz "CockroachDB"
archive "$FILES_SRC" files.tar.gz "MinIO files"
[ -n "$MONGO_SRC" ] && archive "$MONGO_SRC" mongodb.tar.gz "MongoDB (legacy)"
if [ "$FULL" = true ]; then
    archive "$ELASTIC_SRC" elastic.tar.gz "Elasticsearch index"
    archive "$REDPANDA_SRC" redpanda.tar.gz "Redpanda log"
fi

# Bring the stack back up as soon as the volumes are archived; the rest of the work
# (copying config, manifest, pruning) does not need the stack stopped.
restart_stack

echo "Copying config and secret files..."
for f in .env huly.conf huly_v7.conf nginx.conf .huly.secret .cr.secret .rp.secret; do
    [ -f "$f" ] && cp -p "$f" "$DEST/config/"
done
[ -d traefik ] && cp -rp traefik "$DEST/config/"

{
    echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "full: $FULL"
    grep -hE '^HULY_VERSION=' .env huly.conf huly_v7.conf 2>/dev/null | tail -1 || true
    echo "archives:"
    for a in "$DEST"/*.tar.gz; do
        [ -f "$a" ] && echo "  - $(basename "$a")"
    done
} > "$DEST/manifest.txt"

if [ "$KEEP" -gt 0 ]; then
    echo "Pruning old backups, keeping $KEEP..."
    # Timestamped names sort chronologically, and bash expands globs lexically,
    # so this array is oldest-first.
    shopt -s nullglob
    existing=("$OUTPUT_DIR"/huly-backup-*/)
    shopt -u nullglob
    remove=$((${#existing[@]} - KEEP))
    if [ "$remove" -gt 0 ]; then
        for ((i = 0; i < remove; i++)); do
            echo "  removing ${existing[i]}"
            rm -rf "${existing[i]}"
        done
    fi
fi

echo -e "\033[1;32mBackup complete: $DEST\033[0m"
du -sh "$DEST" | awk '{print "Total size: " $1}'
