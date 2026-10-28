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
# A symlinked source could silently dereference a private file outside the
# checkout into this otherwise allowlisted public archive. Refuse both file
# symlinks and a symlinked docs parent before creating any output.
if [[ -L "$ROOT/docs" ]]; then
  echo 'Refusing symlink in portable archive input: docs/' >&2
  exit 1
fi
for file in "${FILES[@]}"; do
  if [[ -L "$ROOT/$file" ]]; then
    echo "Refusing symlink in portable archive input: $file" >&2
    exit 1
  fi
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
  # Normalize copied file modes: a source checkout's umask must not change
  # the archive bytes or unexpectedly expose executable documentation.
  chmod 644 -- "$STAGE/disk-watch-portable/$file"
done
chmod 755 -- "$STAGE/disk-watch-portable" "$STAGE/disk-watch-portable/docs" \
  "$STAGE/disk-watch-portable/disk-watch.sh"

# Checksums are a build-time convenience, not a new runtime requirement.
# Fail before packaging if the host cannot generate a checksum.
command -v sha256sum >/dev/null 2>&1 || {
  echo 'Missing build tool: sha256sum' >&2
  exit 1
}
OUTPUT_DIR=$(dirname -- "$OUTPUT")
OUTPUT_FILE=$(basename -- "$OUTPUT")
mkdir -p -- "$OUTPUT_DIR"
# Stable ordering, timestamp, ownership, permissions and gzip header make
# repeated builds of identical source bytes reproducible across directories
# and umasks. GNU tar and gzip are build-only tools, not runtime dependencies.
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 \
  --numeric-owner -cf - -C "$STAGE" disk-watch-portable | gzip -n > "$OUTPUT"
# Write only the basename so the archive and sidecar remain verifiable
# after moving both files together to a different directory.
(cd -- "$OUTPUT_DIR" && sha256sum -- "$OUTPUT_FILE" > "$OUTPUT_FILE.sha256")
printf 'Portable archive created: %s\nSHA-256 checksum: %s.sha256\n' "$OUTPUT" "$OUTPUT"
