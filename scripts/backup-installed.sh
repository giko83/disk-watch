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
  # A regular leaf can still be reached through a symlinked parent. Do not
  # follow such aliases when capturing the previously installed files.
  parent=$(dirname -- "$src")
  while [[ $parent != / ]]; do
    if [[ -L $parent ]]; then
      echo "Backup failed: refusing symlinked source parent: $parent" >&2
      exit 1
    fi
    parent=$(dirname -- "$parent")
  done
  if [[ -e "$src" && ! -f "$src" ]]; then
    echo "Backup failed: not a regular file: $src" >&2
    exit 1
  fi
  # Installed scripts/units should be independent files. A hardlinked source
  # can alias unrelated data and must not silently enter a recovery snapshot.
  # GNU stat is already required by the installer and snapshot verifier.
  if [[ -f "$src" ]]; then
    links=$(stat -c %h -- "$src") || {
      echo "Backup failed: cannot inspect source link count: $src" >&2
      exit 1
    }
    [[ $links == 1 ]] || {
      echo "Backup failed: refusing hardlinked source: $src" >&2
      exit 1
    }
  fi
  # Duplicate inputs would produce repeated manifest records. Such a
  # snapshot could be marked complete but would fail strict verification.
  occurrences=0
  for other in "$@"; do
    if [[ $src == "$other" ]]; then
      ((occurrences += 1))
    fi
  done
  if ((occurrences != 1)); then
    echo "Backup failed: duplicate source: $src" >&2
    exit 1
  fi
done

# Format 2 snapshots include the installed SMART health helper as a fifth
# recovery path. A format marker prevents a truncated new manifest from being
# mistaken for an older four-path snapshot.
printf '2\n' > "$backup_dir/format.txt"
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
# Record relative checksums so a completed snapshot can be checked after it
# is moved. A checksum detects accidental damage, not malicious modification
# by an account able to rewrite both the snapshot and its manifest.
(
  cd -- "$backup_dir"
  : > SHA256SUMS
  while IFS= read -r src; do
    sha256sum -- ".${src}" >> SHA256SUMS
  done < present.txt
  # An initial install can have no previous files. An empty checksum manifest
  # is valid in that case, but sha256sum -c rejects an empty input.
  if [[ -s present.txt ]]; then
    sha256sum --status -c SHA256SUMS
  fi
)
# This marker is written last. An incomplete snapshot must never be restored.
printf 'complete\n' > "$backup_dir/.complete"
