#!/usr/bin/env bash
# Offline backup regression; no installed paths, systemd or root access.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/live/usr/local/sbin" "$TMP/live/etc/systemd/system" "$TMP/backups"
script="$TMP/live/usr/local/sbin/disk-watch.sh"
unit="$TMP/live/etc/systemd/system/disk-watch.service"
missing="$TMP/live/etc/systemd/system/disk-watch.timer"
printf 'old script\n' > "$script"
printf 'old unit\n' > "$unit"
chmod 750 "$script"
chmod 644 "$unit"
mkdir -m 700 "$TMP/backups/backup.one"
bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.one" "$script" "$unit" "$missing" ||
  fail 'valid snapshot failed'
backup="$TMP/backups/backup.one"
[[ -f "$backup/.complete" ]] || fail 'complete marker missing'
cmp -s "$script" "$backup$script" || fail 'script contents differ'
cmp -s "$unit" "$backup$unit" || fail 'unit contents differ'
[[ $(stat -c %a "$backup$script") == 750 ]] || fail 'script permissions lost'
[[ $(stat -c %a "$backup$unit") == 644 ]] || fail 'unit permissions lost'
grep -Fxq "$script" "$backup/present.txt" || fail 'script not in present manifest'
grep -Fxq "$unit" "$backup/present.txt" || fail 'unit not in present manifest'
grep -Fxq "$missing" "$backup/absent.txt" || fail 'missing unit not in absent manifest'
printf 'new script\n' > "$script"
grep -Fxq 'old script' "$backup$script" || fail 'backup was overwritten after source changed'

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

mkdir -p "$TMP/mock-bin"
cat > "$TMP/mock-bin/cp" <<'MOCK'
#!/usr/bin/env bash
echo 'mock copy failed' >&2
exit 45
MOCK
chmod +x "$TMP/mock-bin/cp"
mkdir -m 700 "$TMP/backups/backup.failed"
if PATH="$TMP/mock-bin:$PATH" bash "$ROOT/scripts/backup-installed.sh" "$TMP/backups/backup.failed" "$script" > "$TMP/out" 2> "$TMP/err"; then
  fail 'failed copy accepted'
fi
[[ ! -e "$TMP/backups/backup.failed/.complete" ]] || fail 'failed copy marked complete'
grep -Fq 'mock copy failed' "$TMP/err" || fail 'copy failure diagnostic missing'

echo 'PASS: offline versioned backup, manifests, file modes, symlink and copy-failure rejection'
