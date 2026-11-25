#!/usr/bin/env bash
# shellcheck disable=SC2013  # image names are single words
#
# tests/migration/check-images.sh - checks migration/image-map.txt against upstream.
#
#   1. every hardcoreeng/* image an upstream huly-selfhost checkout mentions (compose,
#      README guides, kube, helm) has an entry in the map, so a user who enabled it can
#      migrate;
#   2. every Platform Collective image in the map is published for VERSION, so the
#      migrated stack can actually pull it.
#
# Usage: tests/migration/check-images.sh UPSTREAM_DIR VERSION

set -euo pipefail
cd "$(dirname "$0")/../.."

UPSTREAM=${1:?usage: $0 UPSTREAM_DIR VERSION}
VERSION=${2:?usage: $0 UPSTREAM_DIR VERSION}
MAP=migration/image-map.txt
fail=0

echo "Upstream images without a mapping:"
for img in $(grep -rhoE 'hardcoreeng/[a-z0-9_-]+' "$UPSTREAM" --include='*.yml' --include='*.yaml' --include='*.md' --include='*.conf' | sort -u); do
    if ! grep -qE "^${img}[[:space:]]" "$MAP"; then
        echo "  MISSING: $img"
        fail=1
    fi
done
[ "$fail" = 0 ] && echo "  none"

echo "Mapped images not published as :$VERSION:"
missing=0
for img in $(grep -vE '^\s*(#|$)' "$MAP" | awk '{print $2}' | sort -u); do
    if ! docker manifest inspect "$img:$VERSION" >/dev/null 2>&1; then
        echo "  MISSING: $img:$VERSION"
        missing=1
    fi
done
[ "$missing" = 0 ] && echo "  none"

exit $((fail | missing))
