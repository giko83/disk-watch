#!/usr/bin/env bash
# Offline backup regression; no installed paths, systemd or root access.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/live/usr/local/sbin" "$TMP/live/etc/systemd/system" "$TMP/backups"
script="$TMP/live/usr/local/sbin/disk-watch.sh"
health="$TMP/live/usr/local/sbin/disk-watch-health.sh"
unit="$TMP/live/etc/systemd/system/disk-watch.service"
missing="$TMP/live/etc/systemd/system/disk-watch.timer"
printf 'old script\n' > "$script"
printf 'old health helper\n' > "$health"
printf 'old unit\n' > "$unit"
chmod 750 "$script" "$health"
chmod 644 "$unit"
mkdir -m 700 "$TMP/backups/backup.one"
bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.one" "$script" "$health" "$unit" "$missing" ||
  fail 'valid snapshot failed'
backup="$TMP/backups/backup.one"
[[ -f "$backup/.complete" ]] || fail 'complete marker missing'
cmp -s "$script" "$backup$script" || fail 'script contents differ'
cmp -s "$health" "$backup$health" || fail 'health helper contents differ'
cmp -s "$unit" "$backup$unit" || fail 'unit contents differ'
[[ $(stat -c %a "$backup$script") == 750 ]] || fail 'script permissions lost'
[[ $(stat -c %a "$backup$health") == 750 ]] || fail 'health helper permissions lost'
[[ $(stat -c %a "$backup$unit") == 644 ]] || fail 'unit permissions lost'
grep -Fxq "$script" "$backup/present.txt" || fail 'script not in present manifest'
grep -Fxq "$health" "$backup/present.txt" || fail 'health helper not in present manifest'
grep -Fxq 2 "$backup/format.txt" || fail 'versioned snapshot format marker missing'
grep -Fxq "$unit" "$backup/present.txt" || fail 'unit not in present manifest'
grep -Fxq "$missing" "$backup/absent.txt" || fail 'missing unit not in absent manifest'
printf 'new script\n' > "$script"
grep -Fxq 'old script' "$backup$script" || fail 'backup was overwritten after source changed'

# Completed snapshots carry portable relative hashes of every present file.
[[ -s "$backup/SHA256SUMS" ]] || fail 'snapshot checksum manifest missing'
(cd "$backup" && sha256sum --status -c SHA256SUMS) ||
  fail 'untouched snapshot checksum verification failed'
grep -Fq './' "$backup/SHA256SUMS" || fail 'checksum paths are not relative'
printf 'corrupted snapshot\n' > "$backup$script"
if (cd "$backup" && sha256sum --status -c SHA256SUMS) > "$TMP/out" 2> "$TMP/err"; then
  fail 'tampered snapshot passed checksum verification'
fi

# Reject repeated source paths before creating any manifest or snapshot file.
mkdir -m 700 "$TMP/backups/backup.duplicate"
if bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.duplicate" "$script" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'duplicate source was accepted'
fi
grep -Fq 'duplicate source' "$TMP/err" || fail 'missing duplicate-source diagnostic'
[[ -z $(find "$TMP/backups/backup.duplicate" -mindepth 1 -print -quit) ]] ||
  fail 'duplicate source created snapshot contents'

# A fresh installation has no previously installed files to hash.
mkdir -m 700 "$TMP/backups/backup.empty"
bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.empty" "$missing" ||
  fail 'empty snapshot failed'
[[ -f "$TMP/backups/backup.empty/.complete" ]] || fail 'empty snapshot not marked complete'
[[ -f "$TMP/backups/backup.empty/SHA256SUMS" && ! -s "$TMP/backups/backup.empty/SHA256SUMS" ]] ||
  fail 'empty snapshot must have an empty checksum manifest'

if bash "$ROOT/scripts/backup-installed.sh" "$backup" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'completed snapshot was reused'
fi
grep -Fq 'expected a new private backup directory' "$TMP/err" ||
  fail 'missing completed snapshot diagnostic'

# A manually supplied snapshot directory must not be world-readable or
# prepopulated (including hidden entries). Neither rejection may write files.
mkdir -m 755 "$TMP/backups/backup.public"
if bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.public" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'public snapshot directory accepted'
fi
grep -Fq 'mode 700' "$TMP/err" || fail 'missing private-directory diagnostic'
[[ ! -e "$TMP/backups/backup.public/.complete" ]] || fail 'public snapshot marked complete'

mkdir -m 700 "$TMP/backups/backup.notempty"
printf 'keep me\\n' > "$TMP/backups/backup.notempty/.hidden"
if bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.notempty" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'prepopulated snapshot directory accepted'
fi
grep -Fq 'must be empty' "$TMP/err" || fail 'missing non-empty-directory diagnostic'
grep -Fq 'keep me' "$TMP/backups/backup.notempty/.hidden" || fail 'preexisting file was overwritten'
[[ ! -e "$TMP/backups/backup.notempty/.complete" ]] || fail 'non-empty snapshot marked complete'

ln -s "$script" "$TMP/live/linked"
mkdir -m 700 "$TMP/backups/backup.symlink"
if bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.symlink" "$TMP/live/linked" > "$TMP/out" 2> "$TMP/err"; then
  fail 'symlink source accepted'
fi
[[ ! -e "$TMP/backups/backup.symlink/.complete" ]] || fail 'symlink snapshot marked complete'

# A regular file reached through a symlinked parent must also be refused
# before creating manifests. Test a nested descendant, not just a leaf link.
mkdir -p "$TMP/live/actual-parent/nested"
printf '%s' 'private source' > "$TMP/live/actual-parent/nested/file"
ln -s "$TMP/live/actual-parent" "$TMP/live/alias-parent"
mkdir -m 700 "$TMP/backups/backup.parent-link"
if bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.parent-link" \
  "$TMP/live/alias-parent/nested/file" > "$TMP/out" 2> "$TMP/err"; then
  fail 'source with symlinked parent accepted'
fi
grep -Fq 'refusing symlinked source parent' "$TMP/err" || \
  fail 'missing symlinked parent diagnostic'
[[ -z $(find "$TMP/backups/backup.parent-link" -mindepth 1 -print -quit) ]] || \
  fail 'symlinked parent created snapshot contents'
grep -Fxq 'private source' "$TMP/live/actual-parent/nested/file" || \
  fail 'source changed after symlinked parent rejection'

mkdir -p "$TMP/mock-bin"
cat > "$TMP/mock-bin/cp" <<'MOCK'
#!/usr/bin/env bash
echo 'mock copy failed' >&2
exit 45
MOCK
chmod +x "$TMP/mock-bin/cp"
mkdir -m 700 "$TMP/backups/backup.failed"
# Verify failure-injection executables really run (a noexec /tmp could
# silently fall through PATH to the real cp, invalidating the regression).
if PATH="$TMP/mock-bin:$PATH" cp --version > "$TMP/out" 2> "$TMP/err"; then
  fail 'copy failure mock was bypassed'
fi
grep -Fq 'mock copy failed' "$TMP/err" || fail 'copy failure mock could not execute'
if PATH="$TMP/mock-bin:$PATH" bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.failed" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'failed copy accepted'
fi
[[ ! -e "$TMP/backups/backup.failed/.complete" ]] || fail 'failed copy marked complete'
grep -Fq 'mock copy failed' "$TMP/err" || fail 'copy failure diagnostic missing'

# A checksum generation failure must not produce a completed snapshot.
rm -- "$TMP/mock-bin/cp"
cat > "$TMP/mock-bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
echo 'mock hash failed' >&2
exit 46
MOCK
chmod +x "$TMP/mock-bin/sha256sum"
mkdir -m 700 "$TMP/backups/backup.hashfail"
if PATH="$TMP/mock-bin:$PATH" bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.hashfail" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'failed checksum generation accepted'
fi
[[ ! -e "$TMP/backups/backup.hashfail/.complete" ]] || fail 'failed checksum marked snapshot complete'
grep -Fq 'mock hash failed' "$TMP/err" || fail 'missing checksum failure diagnostic'

echo 'PASS: offline snapshot backup, relative hashes, tamper detection, empty snapshot and failure safety'
