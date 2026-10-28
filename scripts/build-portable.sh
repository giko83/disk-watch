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

# A pre-existing output symlink could redirect archive/checksum writes to an
# unrelated file. Fail closed before staging or writing either artifact.
# Use a trusted output directory: this is not an atomic race-proof guard.
for target in "$OUTPUT" "$OUTPUT.sha256"; do
  if [[ -L "$target" ]]; then
    echo "Refusing symlink in portable archive output: $target" >&2
    exit 1
  fi
done

# Explicit allowlist: never package local credentials, state, or .git metadata.
FILES=(
  disk-watch.sh
  disk-watch-health.sh
  disk-watch.conf.example
  README.md
  LICENSE
  CHANGELOG.md
  docs/portable.md
  docs/health.md
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

# Existing output targets must be ordinary files, never pipes, devices or
# directories. Also refuse hard links to packaged sources or this builder:
# truncating an archive or checksum must not destroy its own input.
# This is a preflight guard, not protection against concurrent path races.
for target in "$OUTPUT" "$OUTPUT.sha256"; do
  if [[ -e "$target" && ! -f "$target" ]]; then
    echo "Refusing non-regular portable archive output: $target" >&2
    exit 1
  fi
  if [[ -e "$target" ]]; then
    for source in "${FILES[@]}" scripts/build-portable.sh; do
      if [[ "$target" -ef "$ROOT/$source" ]]; then
        echo "Refusing portable archive output alias of source: $target ($source)" >&2
        exit 1
      fi
    done
  fi
done

STAGE=$(mktemp -d)
OUTPUT_STAGE=''
cleanup() {
  rm -rf -- "$STAGE"
  if [[ -n "$OUTPUT_STAGE" ]]; then
    rm -rf -- "$OUTPUT_STAGE"
  fi
}
trap cleanup EXIT
mkdir -p -- "$STAGE/disk-watch-portable/docs"
for file in "${FILES[@]}"; do
  cp -- "$ROOT/$file" "$STAGE/disk-watch-portable/$file"
  # Normalize copied file modes: a source checkout's umask must not change
  # the archive bytes or unexpectedly expose executable documentation.
  chmod 644 -- "$STAGE/disk-watch-portable/$file"
done
chmod 755 -- "$STAGE/disk-watch-portable" "$STAGE/disk-watch-portable/docs" \
  "$STAGE/disk-watch-portable/disk-watch.sh" "$STAGE/disk-watch-portable/disk-watch-health.sh"

# Checksums are a build-time convenience, not a new runtime requirement.
# Fail before packaging if the host cannot generate a checksum.
command -v sha256sum >/dev/null 2>&1 || {
  echo 'Missing build tool: sha256sum' >&2
  exit 1
}
OUTPUT_DIR=$(dirname -- "$OUTPUT")
OUTPUT_FILE=$(basename -- "$OUTPUT")
mkdir -p -- "$OUTPUT_DIR"
# Stage both artifacts beside the destination. Failed tar/gzip/hash generation
# must not truncate a previously valid archive or checksum. Each final rename
# is atomic on the same filesystem, but the archive/checksum pair is NOT atomic.
OUTPUT_STAGE=$(mktemp -d -- "$OUTPUT_DIR/.disk-watch-build.XXXXXXXX")
# Stable ordering, timestamp, ownership, permissions and gzip header make
# repeated builds of identical source bytes reproducible across directories
# and umasks. GNU tar and gzip are build-only tools, not runtime dependencies.
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 \
  --numeric-owner -cf - -C "$STAGE" disk-watch-portable | gzip -n > "$OUTPUT_STAGE/$OUTPUT_FILE"
# Write only the basename so the archive and sidecar remain verifiable
# after moving both files together to a different directory.
(cd -- "$OUTPUT_STAGE" && sha256sum -- "$OUTPUT_FILE" > "$OUTPUT_FILE.sha256")
# Do not publish a bundle if a broken checksum tool exits successfully but
# produces no digest, or if the staged digest does not verify the staged bytes.
# A failure leaves any existing published archive and checksum untouched.
if [[ ! -s "$OUTPUT_STAGE/$OUTPUT_FILE.sha256" ]] ||
   ! (cd -- "$OUTPUT_STAGE" && sha256sum -c -- "$OUTPUT_FILE.sha256" >/dev/null); then
  echo 'Portable archive checksum creation or verification failed' >&2
  exit 1
fi
mv -f -- "$OUTPUT_STAGE/$OUTPUT_FILE" "$OUTPUT"
mv -f -- "$OUTPUT_STAGE/$OUTPUT_FILE.sha256" "$OUTPUT.sha256"
printf 'Portable archive created: %s\nSHA-256 checksum: %s.sha256\n' "$OUTPUT" "$OUTPUT"
