#!/usr/bin/env bash
# Read-only verification of a pre-install snapshot before any manual restore.
# No host paths, services, configuration or state are modified.
set -euo pipefail

if (($# != 1)); then
  echo 'Usage: verify-installed-snapshot.sh SNAPSHOT_DIR' >&2
  exit 2
fi
snapshot=$1
fail() { echo "Snapshot verification failed: $*" >&2; exit 1; }

[[ -d $snapshot && ! -L $snapshot ]] || fail 'snapshot is not a regular directory'
owner=$(stat -c '%u' -- "$snapshot") || fail 'cannot read snapshot owner'
mode=$(stat -c '%a' -- "$snapshot") || fail 'cannot read snapshot mode'
[[ $owner == "$EUID" && $mode == 700 ]] || fail 'snapshot must be owned by the invoking user and mode 700'

# Every verified file must have its own inode. A hard link to a file outside
# this private snapshot permits external modification after verification and
# defeats the assumption that the saved recovery material is isolated.
# Backup creation uses cp -p (not cp -l), so normal snapshots have one link.
single_link() {
  local target=$1 links
  links=$(stat -c '%h' -- "$target") || fail "cannot inspect snapshot link count: $target"
  [[ $links == 1 ]] || fail "hardlinked snapshot entry: $target"
}

for name in .complete present.txt absent.txt SHA256SUMS; do
  [[ -f $snapshot/$name && ! -L $snapshot/$name ]] || fail "missing or unsafe $name"
  single_link "$snapshot/$name"
done
[[ $(cat -- "$snapshot/.complete") == complete ]] || fail 'invalid completion marker'

# Older verified snapshots cover four paths; format 2 requires all five.
# Never silently interpret an incomplete format-2 manifest as legacy.
format=1
if [[ -e $snapshot/format.txt || -L $snapshot/format.txt ]]; then
  [[ -f $snapshot/format.txt && ! -L $snapshot/format.txt ]] || fail 'unsafe snapshot format marker'
  single_link "$snapshot/format.txt"
  [[ $(cat -- "$snapshot/format.txt") == 2 ]] || fail 'unsupported snapshot format'
  format=2
fi

# Only the fixed installed paths are ever eligible for recovery (five in
# format 2, four in checksum-bearing legacy snapshots). Never
# trust a manifest to supply arbitrary paths to a future restore operation.
paths=(
  /usr/local/sbin/disk-watch.sh
  /usr/local/sbin/disk-watch-health.sh
  /usr/local/sbin/disk-watch-smart.sh
  /etc/systemd/system/disk-watch.service
  /etc/systemd/system/disk-watch.timer
)
for manifest in present.txt absent.txt; do
  while IFS= read -r entry || [[ -n $entry ]]; do
    allowed=false
    for path in "${paths[@]}"; do
      [[ $entry == "$path" ]] && allowed=true
    done
    [[ $allowed == true ]] || fail "unknown or invalid path in $manifest"
  done < "$snapshot/$manifest"
done

present_count=0
for path in "${paths[@]}"; do
  in_present=$(grep -Fxc -- "$path" "$snapshot/present.txt" || true)
  in_absent=$(grep -Fxc -- "$path" "$snapshot/absent.txt" || true)
  if [[ $format == 1 && $path == /usr/local/sbin/disk-watch-health.sh ]]; then
    ((in_present + in_absent == 0)) || fail 'legacy snapshot must not claim the health helper'
    [[ ! -e $snapshot$path && ! -L $snapshot$path ]] || fail 'unmanifested health helper in legacy snapshot'
    continue
  fi
  ((in_present + in_absent == 1)) || fail "duplicate or missing manifest entry for $path"

  # Do not follow a symlink in any component of a copied path.
  if [[ $path == /usr/* ]]; then
    components=(/usr /usr/local /usr/local/sbin)
  else
    components=(/etc /etc/systemd /etc/systemd/system)
  fi
  for component in "${components[@]}"; do
    [[ ! -L $snapshot$component ]] || fail "symlink directory in snapshot: $component"
  done

  if ((in_present == 1)); then
    ((present_count += 1))
    [[ -f $snapshot$path && ! -L $snapshot$path ]] || fail "missing or unsafe copied file: $path"
    single_link "$snapshot$path"
    expected=$(cd -- "$snapshot" && sha256sum -- ".$path") || fail "cannot hash $path"
    matches=$(grep -Fxc -- "$expected" "$snapshot/SHA256SUMS" || true)
    [[ $matches == 1 ]] || fail "checksum mismatch or missing checksum for $path"
  else
    [[ ! -e $snapshot$path && ! -L $snapshot$path ]] || fail "unexpected copied file listed absent: $path"
  fi
done

hash_count=$(wc -l < "$snapshot/SHA256SUMS") || fail 'cannot read checksums'
[[ $hash_count -eq $present_count ]] || fail 'extra or missing checksum records'

# Allowlisted ancestors are directories, not arbitrary entries with an
# allowlisted name. An all-absent snapshot needs no payload directories, so
# a regular file or FIFO at e.g. usr/ or etc/systemd/ previously slipped
# through the name-only find allowlist. Never follow a symlinked ancestor.
for ancestor in usr usr/local usr/local/sbin etc etc/systemd etc/systemd/system; do
  entry="$snapshot/$ancestor"
  if [[ -e $entry || -L $entry ]]; then
    [[ -d $entry && ! -L $entry ]] ||
      fail "unsafe recovery directory: $ancestor (expected a real directory)"
  fi
done
# Reject every unlisted entry, including *empty directories*. Previously,
# an extra empty directory could pass verification because find skipped all
# directories. Only ancestors of the five fixed recovery paths are allowed.
# GNU find's -exec ... + propagates failures without temporary files.
find "$snapshot" -mindepth 1 -exec bash -c '
  root=$1
  shift
  for entry in "$@"; do
    rel=${entry#"$root"/}
    case $rel in
      usr|usr/local|usr/local/sbin|etc|etc/systemd|etc/systemd/system|\
      .complete|present.txt|absent.txt|SHA256SUMS|format.txt|\
      usr/local/sbin/disk-watch.sh|usr/local/sbin/disk-watch-health.sh|usr/local/sbin/disk-watch-smart.sh|\
      etc/systemd/system/disk-watch.service|etc/systemd/system/disk-watch.timer) ;;
      *) printf "Snapshot verification failed: unlisted snapshot entry: %s\n" "$rel" >&2; exit 1 ;;
    esac
  done
' _ "$snapshot" {} + || fail 'unlisted or unreadable snapshot content'

if [[ $format == 1 ]]; then
  echo 'Legacy four-path snapshot: disk-watch-health.sh was NOT captured; recover it separately.' >&2
fi
echo "Snapshot verified (read-only, format $format): $present_count present, $(((format == 1 ? 4 : 5) - present_count)) absent. No files restored."
