#!/usr/bin/env bash
# Build a standalone no-install archive from an existing source tree.
# No root, Git, network, or systemd required.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if (($# > 1)); then
  echo 'Usage: bash scripts/build-portable.sh [output.tar.gz]' >&2
  exit 2
fi
OUTPUT=${1:-"$ROOT/dist/disk-watch-portable.tar.gz"}

# Explicit allowlist: never package local credentials, state, or .git metadata.
FILES=(
  disk-watch.sh
  disk-watch.conf.example
  README.md
  LICENSE
  CHANGELOG.md
  docs/portable.md
  docs/ROADMAP.md
  docs/operations.md
  docs/smart-usb-standby.md
)
for file in "${FILES[@]}"; do
  if [[ ! -f "$ROOT/$file" ]]; then
    echo "Missing portable archive input: $file" >&2
    exit 1
  fi
done

STAGE=$(mktemp -d)
trap 'rm -rf -- "$STAGE"' EXIT
mkdir -p -- "$STAGE/disk-watch-portable/docs"
for file in "${FILES[@]}"; do
  cp -- "$ROOT/$file" "$STAGE/disk-watch-portable/$file"
done
chmod 755 -- "$STAGE/disk-watch-portable/disk-watch.sh"

mkdir -p -- "$(dirname "$OUTPUT")"
tar -czf "$OUTPUT" -C "$STAGE" disk-watch-portable
printf 'Portable archive created: %s\n' "$OUTPUT"
