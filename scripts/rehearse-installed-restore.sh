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
# Refuse a sandbox inside its source snapshot (including parent symlink
# aliases) before verification. The strict verifier now rejects even empty
# unlisted directories, so a nested sandbox must be diagnosed separately.
# No writes occur before either check.
snapshot_real=$(cd -- "$snapshot" && pwd -P) || fail 'cannot resolve snapshot directory'
sandbox_real=$(cd -- "$sandbox" && pwd -P) || fail 'cannot resolve sandbox directory'
[[ $sandbox_real != "$snapshot_real" && $sandbox_real != "$snapshot_real"/* ]] ||
  fail 'sandbox must be outside the snapshot directory'
# A private sandbox leaf can still be reached through a symlinked parent, or
# a symlinked leaf with a trailing slash. Reject every path component before
# writing any sandbox file. This is best-effort against concurrent path swaps.
sandbox_path_chain_safe() {
  local rest=${sandbox#/} part prefix=/
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
    [[ -z $part ]] && continue
    prefix="${prefix%/}/$part"
    [[ -d $prefix && ! -L $prefix ]] || return 1
  done
}
sandbox_path_chain_safe ||
  fail 'sandbox path contains a symlink or non-directory ancestor'
# Verify the entire source snapshot before creating any sandbox subdirectory.
bash "$script_dir/verify-installed-snapshot.sh" "$snapshot" >&2

# Once copying begins, a failure must not leave misleading partial output.
# Only paths created in this previously empty private sandbox are removed;
# never remove the sandbox itself, source snapshot, or any installed host path.
created_files=()
cleanup_failed_rehearsal() {
  local status=$?
  ((status == 0)) && return 0
  local file dir
  for file in "${created_files[@]}"; do
    rm -f -- "$file" || true
  done
  for dir in /usr/local/sbin /usr/local /usr /etc/systemd/system /etc/systemd /etc; do
    rmdir -- "$sandbox$dir" 2>/dev/null || true
  done
  echo 'Restore rehearsal failed: attempted cleanup of partial sandbox files; inspect sandbox before reuse.' >&2
}
trap cleanup_failed_rehearsal EXIT

count=0
for path in /usr/local/sbin/disk-watch.sh /usr/local/sbin/disk-watch-health.sh /usr/local/sbin/disk-watch-smart.sh \
            /etc/systemd/system/disk-watch.service /etc/systemd/system/disk-watch.timer; do
  if grep -Fxq -- "$path" "$snapshot/present.txt"; then
    mkdir -p -- "$(dirname -- "$sandbox$path")" ||
      fail "cannot create sandbox directory for $path"
    created_files+=("$sandbox$path")
    cp -p -- "$snapshot$path" "$sandbox$path" ||
      fail "cannot copy $path (sandbox may be incomplete)"
    cmp -s -- "$snapshot$path" "$sandbox$path" ||
      fail "copied contents differ for $path"
    [[ $(stat -c '%a' -- "$sandbox$path") == $(stat -c '%a' -- "$snapshot$path") ]] ||
      fail "copied permissions differ for $path"
    ((count += 1))
  fi
done
# A later copy can alter an earlier sandbox file after its immediate cmp/mode
# check. Recheck every copied destination at the end, before reporting success.
# This is a best-effort consistency check, not protection against concurrent
# path replacement; cleanup remains confined to this disposable sandbox.
for file in "${created_files[@]}"; do
  path=${file#"$sandbox"}
  [[ -f $file && ! -L $file ]] ||
    fail "sandbox file changed after copying: $path"
  cmp -s -- "$snapshot$path" "$file" ||
    fail "sandbox contents changed after copying: $path"
  [[ $(stat -c '%a' -- "$file") == $(stat -c '%a' -- "$snapshot$path") ]] ||
    fail "sandbox permissions changed after copying: $path"
done
# The snapshot was verified before copying, but a local process could change
# its manifest, hashes or payload while the rehearsal is in progress. Recheck
# the source after the last copy, before declaring success. The EXIT trap
# removes only sandbox output on failure; this is not a race-proof guarantee.
bash "$script_dir/verify-installed-snapshot.sh" "$snapshot" >&2 ||
  fail 'source snapshot changed during rehearsal'
printf 'Restore rehearsal passed: %d copied file(s) under %s. No live paths or services changed.\n' "$count" "$sandbox"
echo 'This is not a root-level rollback test. Inspect and remove the sandbox manually.'
