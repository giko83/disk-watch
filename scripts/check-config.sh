#!/usr/bin/env bash
# Verify root-owned configuration metadata without reading its secrets.
set -euo pipefail
if (($# != 1)); then
  echo 'Usage: check-config.sh CONFIG_PATH' >&2
  exit 2
fi
config=$1
if [[ ! -f "$config" || -L "$config" ]]; then
  echo "Config check failed: expected a regular, non-symlink file: $config" >&2
  exit 1
fi
owner=$(stat -c '%u' -- "$config") || { echo 'Config check failed: cannot read file owner' >&2; exit 1; }
mode=$(stat -c '%a' -- "$config") || { echo 'Config check failed: cannot read file mode' >&2; exit 1; }
if [[ ! $owner =~ ^[0-9]+$ || $owner != 0 ]]; then
  echo 'Config check failed: config must be owned by root (UID 0)' >&2
  exit 1
fi
if [[ ! $mode =~ ^[0-7]{3,4}$ ]]; then
  echo 'Config check failed: invalid file mode' >&2
  exit 1
fi
permissions=$((8#$mode))
if (( (permissions & 077) != 0 )); then
  echo 'Config check failed: config must not be accessible to group or others (chmod 600 or 400)' >&2
  exit 1
fi
