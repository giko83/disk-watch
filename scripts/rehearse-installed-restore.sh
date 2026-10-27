#!/usr/bin/env bash
# Rehearse restoration into an empty private sandbox, never installed host paths.
# No systemctl, deletion, config, state, Git, or live device access.
set -euo pipefail

if (($# != 2)); then
  echo 'Usage: rehearse-installed-restore.sh SNAPSHOT_DIR EMPTY_SANDBOX_DIR' >&2
  exit 2
fi
snapshot=$1
sandbox=$2
fail() { echo "Restore rehearsal failed: $*" >&2; exit 1; }

# Require an explicit, private, empty absolute directory. All restored paths
# are prefixed with this sandbox; none can address the real installed files.
[[ $sandbox == /* && $sandbox != / && $sandbox != */../* && $sandbox != */./* &&
   $sandbox != */.. && $sandbox != */. && -d $sandbox && ! -L $sandbox ]] ||
  fail 'sandbox must be an existing non-symlink absolute directory without traversal'
owner=$(stat -c '%u' -- "$sandbox") || fail 'cannot read sandbox owner'
mode=$(stat -c '%a' -- "$sandbox") || fail 'cannot read sandbox permissions'
[[ $owner == "$EUID" && $mode == 700 ]] ||
  fail 'sandbox must be owned by the invoking user and mode 700'
[[ -z $(find "$sandbox" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
  fail 'sandbox must be empty'

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
# Verify the entire snapshot before creating even a sandbox subdirectory.
bash "$script_dir/verify-installed-snapshot.sh" "$snapshot" >&2

# Refuse a sandbox inside its source snapshot, including aliases through
# symlinked parent directories. Never write rehearsal output into a backup.
snapshot_real=$(cd -- "$snapshot" && pwd -P) || fail 'cannot resolve snapshot directory'
sandbox_real=$(cd -- "$sandbox" && pwd -P) || fail 'cannot resolve sandbox directory'
[[ $sandbox_real != "$snapshot_real" && $sandbox_real != "$snapshot_real"/* ]] ||
  fail 'sandbox must be outside the snapshot directory'

count=0
for path in /usr/local/sbin/disk-watch.sh /usr/local/sbin/disk-watch-smart.sh \
            /etc/systemd/system/disk-watch.service /etc/systemd/system/disk-watch.timer; do
  if grep -Fxq -- "$path" "$snapshot/present.txt"; then
    mkdir -p -- "$(dirname -- "$sandbox$path")" ||
      fail "cannot create sandbox directory for $path"
    cp -p -- "$snapshot$path" "$sandbox$path" ||
      fail "cannot copy $path (sandbox may be incomplete)"
    cmp -s -- "$snapshot$path" "$sandbox$path" ||
      fail "copied contents differ for $path"
    [[ $(stat -c '%a' -- "$sandbox$path") == $(stat -c '%a' -- "$snapshot$path") ]] ||
      fail "copied permissions differ for $path"
    ((count += 1))
  fi
done
printf 'Restore rehearsal passed: %d copied file(s) under %s. No live paths or services changed.\n' "$count" "$sandbox"
echo 'This is not a root-level rollback test. Inspect and remove the sandbox manually.'
