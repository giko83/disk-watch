#!/usr/bin/env bash
# Restore the five allowlisted installed files from a verified format-2 snapshot.
# ROOT_PREFIX is for isolated tests; / means the actual installed paths.
set -euo pipefail
umask 077
if (($# != 2)); then
  echo 'Usage: restore-installed.sh SNAPSHOT_DIR ROOT_PREFIX' >&2; exit 2
fi
snapshot=$1
root=$2
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ $root == / || ( $root == /* && $root != */ && $root != *'/../'* && $root != *'/./'* && $root != */.. && $root != */. ) ]] || {
  echo 'Restore refused: invalid root prefix' >&2; exit 2;
}
if [[ $root == / ]]; then
  (( EUID == 0 )) || { echo 'Restore refused: root required for live paths' >&2; exit 1; }
else
  [[ -d $root && ! -L $root && $(stat -c %u -- "$root") == "$EUID" && $(stat -c %a -- "$root") == 700 ]] || {
    echo 'Restore refused: private sandbox root required' >&2; exit 1;
  }
fi
# Reject symlinks in the entire destination prefix, including parents.
prefix=/
rest=${root#/}
while [[ -n $rest ]]; do
  part=${rest%%/*}
  if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
  [[ -z $part ]] && continue
  prefix="${prefix%/}/$part"
  [[ -d $prefix && ! -L $prefix ]] || { echo 'Restore refused: unsafe root ancestor' >&2; exit 1; }
done
[[ -f $snapshot/format.txt && $(cat -- "$snapshot/format.txt") == 2 ]] || {
  echo 'Restore refused: complete format-2 snapshot required' >&2; exit 1;
}
bash "$script_dir/verify-installed-snapshot.sh" "$snapshot" >&2
paths=(/usr/local/sbin/disk-watch.sh /usr/local/sbin/disk-watch-health.sh /usr/local/sbin/disk-watch-smart.sh /etc/systemd/system/disk-watch.service /etc/systemd/system/disk-watch.timer)
# Precheck all existing destination leaves and ancestors before any mutation.
for path in "${paths[@]}"; do
  target="${root%/}$path"
  parent=$(dirname -- "$target")
  while [[ $parent != / ]]; do
    [[ ! -L $parent ]] || { echo "Restore refused: symlinked parent $parent" >&2; exit 1; }
    parent=$(dirname -- "$parent")
  done
  [[ ! -L $target && ( ! -e $target || ( -f $target && $(stat -c %h -- "$target") == 1 ) ) ]] || {
    echo "Restore refused: unsafe destination $path" >&2; exit 1;
  }
done
for path in "${paths[@]}"; do
  target="${root%/}$path"
  if grep -Fxq -- "$path" "$snapshot/present.txt"; then
    mkdir -p -- "$(dirname -- "$target")"
    mode=$(stat -c %a -- "$snapshot$path")
    install -m "$mode" -- "$snapshot$path" "$target"
    cmp -s -- "$snapshot$path" "$target" || { echo "Restore failed: mismatch $path" >&2; exit 1; }
  else
    rm -f -- "$target"
  fi
done
bash "$script_dir/verify-installed-snapshot.sh" "$snapshot" >&2
echo 'Restored five allowlisted paths; configuration and state untouched. Reload systemd and verify timer separately.'
