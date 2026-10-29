#!/usr/bin/env bash
# Read-only recovery plan for an already verified pre-install snapshot.
# This script never copies, removes, or restarts anything.
set -euo pipefail

if (($# != 1)); then
  echo 'Usage: plan-installed-restore.sh SNAPSHOT_DIR' >&2
  exit 2
fi
snapshot=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Fail closed: do not offer any recovery steps for incomplete, untrusted,
# legacy, malformed, or checksum-damaged snapshots.
bash "$script_dir/verify-installed-snapshot.sh" "$snapshot" >&2

paths=(
  /usr/local/sbin/disk-watch.sh
  /usr/local/sbin/disk-watch-health.sh
  /usr/local/sbin/disk-watch-smart.sh
  /etc/systemd/system/disk-watch.service
  /etc/systemd/system/disk-watch.timer
)
printf 'Read-only recovery plan for verified snapshot: %s\n' "$snapshot"
for path in "${paths[@]}"; do
  if [[ $path == /usr/local/sbin/disk-watch-health.sh && ! -f $snapshot/format.txt ]]; then
    printf 'NOT CAPTURED (legacy snapshot): %s (recover separately)\n' "$path"
    continue
  fi
  if grep -Fxq -- "$path" "$snapshot/present.txt"; then
    mode=$(stat -c '%a' -- "$snapshot$path")
    printf 'RESTORE: %s (saved file mode %s)\n' "$path" "$mode"
  else
    printf 'REVIEW ABSENT: %s (do not delete automatically)\n' "$path"
  fi
done
echo 'No files, services, configuration, or state were changed.'
echo 'Review docs/operations.md before any manual restore; no rollback was performed.'
