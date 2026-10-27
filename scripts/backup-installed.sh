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
# A snapshot must be newly created, owned by the invoking user (root during
# installation), private, and empty. Otherwise existing paths inside it could
# redirect copies or make the manifest describe a contaminated snapshot.
dir_owner=$(stat -c '%u' -- "$backup_dir") || {
  echo 'Backup failed: cannot read snapshot directory owner' >&2
  exit 1
}
dir_mode=$(stat -c '%a' -- "$backup_dir") || {
  echo 'Backup failed: cannot read snapshot directory permissions' >&2
  exit 1
}
if [[ $dir_owner != "$EUID" || $dir_mode != 700 ]]; then
  echo 'Backup failed: snapshot directory must be owned by the invoking user with mode 700' >&2
  exit 1
fi
shopt -s nullglob dotglob
existing=("$backup_dir"/*)
if (("${#existing[@]}" != 0)); then
  echo 'Backup failed: snapshot directory must be empty' >&2
  exit 1
fi

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
