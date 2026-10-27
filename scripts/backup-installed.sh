#!/usr/bin/env bash
# Snapshot only the installed Disk Watch files before an update.
# Called by install.sh with a new private backup directory.
set -euo pipefail
umask 077

if (($# < 2)); then
  echo 'Usage: backup-installed.sh BACKUP_DIR ABSOLUTE_FILE...' >&2
  exit 2
fi
backup_dir=$1
shift
[[ -d "$backup_dir" && ! -L "$backup_dir" && ! -e "$backup_dir/.complete" ]] || {
  echo 'Backup failed: expected a new private backup directory' >&2
  exit 1
}
# The caller supplies fixed absolute paths; never copy an arbitrary directory.
for src in "$@"; do
  [[ $src == /* && $src != *'/../'* && $src != *'/./'* ]] || {
    echo 'Backup failed: source must be an absolute normalized path' >&2
    exit 1
  }
  [[ ! -L "$src" ]] || {
    echo "Backup failed: refusing symlink $src" >&2
    exit 1
  }
  if [[ -e "$src" && ! -f "$src" ]]; then
    echo "Backup failed: not a regular file: $src" >&2
    exit 1
  fi
done

: > "$backup_dir/present.txt"
: > "$backup_dir/absent.txt"
for src in "$@"; do
  if [[ -f "$src" ]]; then
    target="$backup_dir$src"
    mkdir -p -- "$(dirname -- "$target")"
    cp -p -- "$src" "$target"
    printf '%s\n' "$src" >> "$backup_dir/present.txt"
  else
    printf '%s\n' "$src" >> "$backup_dir/absent.txt"
  fi
done
# This marker is written last. An incomplete snapshot must never be restored.
printf 'complete\n' > "$backup_dir/.complete"
