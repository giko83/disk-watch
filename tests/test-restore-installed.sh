#!/usr/bin/env bash
# Offline sandbox restore tests; never use installed host paths.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -m 700 "$tmp/snapshot" "$tmp/target"
paths=(/usr/local/sbin/disk-watch.sh /usr/local/sbin/disk-watch-health.sh /usr/local/sbin/disk-watch-smart.sh /etc/systemd/system/disk-watch.service /etc/systemd/system/disk-watch.timer)
for path in "${paths[@]}"; do
  mkdir -p -- "$tmp/target$(dirname "$path")"
  printf 'old:%s\n' "$path" > "$tmp/target$path"
done
# Build a real format-2 snapshot with fixed manifest names and checksums.
rm -rf -- "$tmp/snapshot"
mkdir -m 700 "$tmp/snapshot"
printf '2\n' > "$tmp/snapshot/format.txt"
: > "$tmp/snapshot/present.txt"
: > "$tmp/snapshot/absent.txt"
: > "$tmp/snapshot/SHA256SUMS"
for path in "${paths[@]}"; do
  mkdir -p -- "$tmp/snapshot$(dirname "$path")"
  cp -p -- "$tmp/target$path" "$tmp/snapshot$path"
  printf '%s\n' "$path" >> "$tmp/snapshot/present.txt"
  (cd "$tmp/snapshot"; sha256sum -- ".$path") >> "$tmp/snapshot/SHA256SUMS"
  printf 'new\n' > "$tmp/target$path"
done
printf 'complete\n' > "$tmp/snapshot/.complete"
bash "$repo/scripts/restore-installed.sh" "$tmp/snapshot" "$tmp/target" >/dev/null
for path in "${paths[@]}"; do
  cmp -s -- "$tmp/snapshot$path" "$tmp/target$path" || exit 1
done
printf 'secret\n' > "$tmp/target/etc/disk-watch.conf"
printf 'cursor\n' > "$tmp/target/kernel.cursor"
printf 'corrupted\n' > "$tmp/snapshot/usr/local/sbin/disk-watch.sh"
if bash "$repo/scripts/restore-installed.sh" "$tmp/snapshot" "$tmp/target" >/dev/null 2>&1; then
  echo 'Corrupted snapshot accepted' >&2; exit 1
fi
[[ $(cat "$tmp/target/etc/disk-watch.conf") == secret && $(cat "$tmp/target/kernel.cursor") == cursor ]] || exit 1

# Repair the deliberately corrupted snapshot before testing destination safety.\nprintf 'old:%s\n' '/usr/local/sbin/disk-watch.sh' > "$tmp/snapshot/usr/local/sbin/disk-watch.sh"
bash "$repo/scripts/verify-installed-snapshot.sh" "$tmp/snapshot" >/dev/null

# Refuse a symlink destination before changing ANY allowlisted file.
printf 'sentinel\\n' > "$tmp/external"
rm -- "$tmp/target/etc/systemd/system/disk-watch.timer"
ln -s "$tmp/external" "$tmp/target/etc/systemd/system/disk-watch.timer"
printf 'unchanged\\n' > "$tmp/target/usr/local/sbin/disk-watch.sh"
if bash "$repo/scripts/restore-installed.sh" "$tmp/snapshot" "$tmp/target" >/dev/null 2>&1; then
  echo 'Symlinked destination accepted' >&2; exit 1
fi
[[ $(cat "$tmp/external") == sentinel && $(cat "$tmp/target/usr/local/sbin/disk-watch.sh") == unchanged ]] || {
  echo 'Unsafe destination check mutated files' >&2; exit 1;
}
rm -- "$tmp/target/etc/systemd/system/disk-watch.timer"
printf 'new\\n' > "$tmp/target/etc/systemd/system/disk-watch.timer"

# A snapshot marking the timer as previously absent must REMOVE a newly installed timer.
# Rebuild a complete, independently verified format-2 manifest for that case.
absent=/etc/systemd/system/disk-watch.timer
rm -- "$tmp/snapshot$absent"
grep -Fxv -- "$absent" "$tmp/snapshot/present.txt" > "$tmp/present.new"
mv -- "$tmp/present.new" "$tmp/snapshot/present.txt"
printf '%s\\n' "$absent" >> "$tmp/snapshot/absent.txt"
grep -Fv -- ".$absent" "$tmp/snapshot/SHA256SUMS" > "$tmp/sums.new"
mv -- "$tmp/sums.new" "$tmp/snapshot/SHA256SUMS"
bash "$repo/scripts/verify-installed-snapshot.sh" "$tmp/snapshot" >/dev/null
bash "$repo/scripts/restore-installed.sh" "$tmp/snapshot" "$tmp/target" >/dev/null
[[ ! -e "$tmp/target$absent" ]] || { echo 'Previously absent timer not removed' >&2; exit 1; }
[[ $(cat "$tmp/target/usr/local/sbin/disk-watch.sh") == old:/usr/local/sbin/disk-watch.sh ]] || {
  echo 'Present file not restored with absent timer' >&2; exit 1;
}
[[ $(cat "$tmp/target/etc/disk-watch.conf") == secret && $(cat "$tmp/target/kernel.cursor") == cursor ]] || {
  echo 'Config or state changed during absent-file restore' >&2; exit 1;
}
echo 'PASS: sandbox restore, corrupt snapshot refusal, unsafe destination precheck, absent-file rollback and state preservation'
