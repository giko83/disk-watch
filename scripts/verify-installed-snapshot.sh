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

for name in .complete present.txt absent.txt SHA256SUMS; do
  [[ -f $snapshot/$name && ! -L $snapshot/$name ]] || fail "missing or unsafe $name"
done
[[ $(cat -- "$snapshot/.complete") == complete ]] || fail 'invalid completion marker'

# Only the four fixed installed paths are ever eligible for recovery. Never
# trust a manifest to supply arbitrary paths to a future restore operation.
paths=(
  /usr/local/sbin/disk-watch.sh
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
    expected=$(cd -- "$snapshot" && sha256sum -- ".$path") || fail "cannot hash $path"
    matches=$(grep -Fxc -- "$expected" "$snapshot/SHA256SUMS" || true)
    [[ $matches == 1 ]] || fail "checksum mismatch or missing checksum for $path"
  else
    [[ ! -e $snapshot$path && ! -L $snapshot$path ]] || fail "unexpected copied file listed absent: $path"
  fi
done

hash_count=$(wc -l < "$snapshot/SHA256SUMS") || fail 'cannot read checksums'
[[ $hash_count -eq $present_count ]] || fail 'extra or missing checksum records'
# Reject any unlisted non-directory entry, including hidden files, symlinks
# and special files. Manifests and hashes describe only the fixed allowlist;
# unexpected payloads must not be mistaken for verified recovery material.
# GNU find's -exec ... + propagates failures without creating temporary files.
find "$snapshot" -mindepth 1 ! -type d -exec bash -c '
  root=$1
  shift
  for entry in "$@"; do
    rel=${entry#"$root"/}
    case $rel in
      .complete|present.txt|absent.txt|SHA256SUMS|\
      usr/local/sbin/disk-watch.sh|usr/local/sbin/disk-watch-smart.sh|\
      etc/systemd/system/disk-watch.service|etc/systemd/system/disk-watch.timer) ;;
      *) printf "Snapshot verification failed: unlisted snapshot entry: %s\n" "$rel" >&2; exit 1 ;;
    esac
  done
' _ "$snapshot" {} + || fail 'unlisted or unreadable snapshot content'

echo "Snapshot verified (read-only): $present_count present, $((4 - present_count)) absent. No files restored."
