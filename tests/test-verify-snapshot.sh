#!/usr/bin/env bash
# Offline, unprivileged snapshot verification regression tests.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
verify() { bash "$ROOT/scripts/verify-installed-snapshot.sh" "$1"; }
reject() {
  if verify "$1" > "$TMP/out" 2> "$TMP/err"; then fail "$2 was accepted"; fi
  grep -Fq 'Snapshot verification failed:' "$TMP/err" || fail "no diagnostic for $2"
}

mkdir -p "$TMP/backups"
script=/usr/local/sbin/disk-watch.sh
unit=/etc/systemd/system/disk-watch.service
missing=/etc/systemd/system/disk-watch.timer
make_snapshot() {
  local name=$1 dir="$TMP/backups/$1"
  mkdir -m 700 "$dir"
  mkdir -p "$dir/usr/local/sbin" "$dir/etc/systemd/system"
  printf 'previous monitor\n' > "$dir$script"
  printf 'previous unit\n' > "$dir$unit"
  printf '%s\n' "$script" "$unit" > "$dir/present.txt"
  printf '%s\n' /usr/local/sbin/disk-watch-smart.sh "$missing" > "$dir/absent.txt"
  (cd "$dir" && sha256sum ".$script" ".$unit" > SHA256SUMS)
  printf 'complete\n' > "$dir/.complete"
}
make_snapshot valid
verify "$TMP/backups/valid" > "$TMP/out" || fail 'valid snapshot rejected'
grep -Fq '2 present, 2 absent' "$TMP/out" || fail 'wrong summary'

make_snapshot tampered
printf 'bad\n' > "$TMP/backups/tampered$script"
reject "$TMP/backups/tampered" 'tampered file'

make_snapshot extra
printf '%s\n' '/etc/passwd' >> "$TMP/backups/extra/present.txt"
reject "$TMP/backups/extra" 'unallowlisted manifest entry'

make_snapshot duplicate
printf '%s\n' "$script" >> "$TMP/backups/duplicate/present.txt"
reject "$TMP/backups/duplicate" 'duplicate manifest entry'

make_snapshot hash-extra
printf 'garbage\n' >> "$TMP/backups/hash-extra/SHA256SUMS"
reject "$TMP/backups/hash-extra" 'extra checksum entry'

make_snapshot absent
printf 'should not exist\n' > "$TMP/backups/absent$missing"
reject "$TMP/backups/absent" 'copied file declared absent'

make_snapshot incomplete
rm -- "$TMP/backups/incomplete/.complete"
reject "$TMP/backups/incomplete" 'incomplete snapshot'

make_snapshot legacy
rm -- "$TMP/backups/legacy/SHA256SUMS"
reject "$TMP/backups/legacy" 'legacy snapshot without hashes'

make_snapshot public
chmod 755 "$TMP/backups/public"
reject "$TMP/backups/public" 'public snapshot'

make_snapshot marker
printf 'incomplete\n' > "$TMP/backups/marker/.complete"
reject "$TMP/backups/marker" 'invalid completion marker'

make_snapshot symlink-dir
mv "$TMP/backups/symlink-dir/usr/local/sbin" "$TMP/backups/symlink-dir/sbin-original"
ln -s "$TMP/backups/symlink-dir/sbin-original" "$TMP/backups/symlink-dir/usr/local/sbin"
reject "$TMP/backups/symlink-dir" 'symlink intermediate directory'

make_snapshot symlink
rm -- "$TMP/backups/symlink$script"
ln -s "$script" "$TMP/backups/symlink$script"
reject "$TMP/backups/symlink" 'symlink copied file'

# A new installation has no previously installed files and an empty checksum.
mkdir -m 700 "$TMP/backups/empty"
printf '%s\n' /usr/local/sbin/disk-watch.sh /usr/local/sbin/disk-watch-smart.sh \
  /etc/systemd/system/disk-watch.service /etc/systemd/system/disk-watch.timer \
  > "$TMP/backups/empty/absent.txt"
: > "$TMP/backups/empty/present.txt"
: > "$TMP/backups/empty/SHA256SUMS"
printf 'complete\n' > "$TMP/backups/empty/.complete"
verify "$TMP/backups/empty" > "$TMP/out" || fail 'valid empty snapshot rejected'
grep -Fq '0 present, 4 absent' "$TMP/out" || fail 'wrong empty summary'

echo 'PASS: offline read-only snapshot verification and malformed/tampered/legacy rejection'
