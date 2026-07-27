#!/usr/bin/env bash
#
# restore.sh - Restore a backup created by backup.sh into a Docker Compose deployment.
#
# WARNING: this REPLACES the current data volumes and overwrites local config files.
# Stop and think before running it against a live deployment. Restore into a clean or
# test environment first when you can.
#
# Usage: ./restore.sh BACKUP_DIR [--yes] [--help]

set -euo pipefail

cd "$(dirname "$0")"

RESTORE_DIR=""
ASSUME_YES=false

for arg in "$@"; do
    case $arg in
        --yes)  ASSUME_YES=true ;;
        --help)
            echo "Usage: $0 BACKUP_DIR [OPTIONS]"
            echo "Arguments:"
            echo "  BACKUP_DIR    A backup directory created by backup.sh"
            echo "Options:"
            echo "  --yes         Do not prompt for confirmation"
            echo "  --help        Show this help message"
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
        *) RESTORE_DIR="$arg" ;;
    esac
done

if [ -z "$RESTORE_DIR" ] || [ ! -d "$RESTORE_DIR" ]; then
    echo "Error: provide a valid backup directory. See --help." >&2
    exit 1
fi
if [ ! -f "$RESTORE_DIR/manifest.txt" ]; then
    echo "Error: $RESTORE_DIR does not look like a backup (no manifest.txt)." >&2
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "Error: docker compose is not available." >&2
    exit 1
fi

SRC_ABS=$(cd "$RESTORE_DIR" && pwd)

echo -e "\033[1;33mThis will overwrite current data and config from:\033[0m $SRC_ABS"
cat "$RESTORE_DIR/manifest.txt"
if [ "$ASSUME_YES" != true ]; then
    read -r -p "Continue and overwrite the current deployment? (y/N): " ANSWER
    case "${ANSWER:-N}" in
        [Yy]*) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# Ensure containers and volumes exist, then stop everything so the volumes are safe
# to overwrite (never write to a volume while its container is running).
echo "Preparing stack (creating containers, stopping the stack)..."
$COMPOSE up --no-start
$COMPOSE stop

source_on() {
    # $1 = container id, $2 = mount destination
    docker inspect "$1" --format \
        "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}" 2>/dev/null || true
}

# Resolve the volume backing a mount destination: try the expected service name
# first, then scan every container in the project (so deployments that name the
# service differently, e.g. "cockroach" vs "cockroachdb", still resolve).
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

restore_vol() {
    # $1 = target source (volume name or host path), $2 = tar file in the backup
    [ -f "$SRC_ABS/$2" ] || return 0
    if [ -z "$1" ]; then
        echo -e "  \033[33mcannot resolve target for $2, skipping\033[0m"
        return 0
    fi
    echo "  - $2 -> $1"
    docker run --rm -v "$1":/data -v "$SRC_ABS":/backup:ro alpine \
        sh -c 'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null; tar xzf "/backup/'"$2"'" -C /data'
}

echo "Restoring data volumes..."
restore_vol "$(mount_source cockroach /cockroach/cockroach-data)" cockroach.tar.gz
restore_vol "$(mount_source minio /data)" files.tar.gz
restore_vol "$(mount_source mongodb /data/db)" mongodb.tar.gz
restore_vol "$(mount_source elastic /usr/share/elasticsearch/data)" elastic.tar.gz
restore_vol "$(mount_source redpanda /var/lib/redpanda/data)" redpanda.tar.gz

echo "Restoring config and secret files..."
if [ -d "$RESTORE_DIR/config" ]; then
    cp -rp "$RESTORE_DIR"/config/. .
fi

echo "Starting stack..."
$COMPOSE up -d

echo -e "\033[1;32mRestore complete.\033[0m The search index may take a few minutes to rebuild."
