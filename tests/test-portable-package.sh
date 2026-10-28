#!/usr/bin/env bash
# Offline portable archive test: no root, Git, network, disks, or systemd.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

ARCHIVE="$TMP/portable build.tar.gz"
(cd "$TMP"; bash "$ROOT/scripts/build-portable.sh" "$ARCHIVE") >/dev/null
[[ -s "$ARCHIVE" ]] || fail 'archive missing or empty'
[[ -s "$ARCHIVE.sha256" ]] || fail 'archive checksum missing or empty'
(cd -- "$TMP" && sha256sum -c -- "portable build.tar.gz.sha256") >/dev/null ||
  fail 'checksum verification failed for unmodified archive'
grep -Fq 'portable build.tar.gz' "$ARCHIVE.sha256" ||
  fail 'checksum must use a portable basename rather than an absolute path'

# Rebuilding identical source bytes must produce the same archive even with
# different staging directories and caller umasks (no root/network required).
mkdir -p "$TMP/rebuild one" "$TMP/rebuild two"
(umask 077; bash "$ROOT/scripts/build-portable.sh" "$TMP/rebuild one/bundle.tar.gz") >/dev/null
(umask 022; bash "$ROOT/scripts/build-portable.sh" "$TMP/rebuild two/bundle.tar.gz") >/dev/null
cmp -s -- "$TMP/rebuild one/bundle.tar.gz" "$TMP/rebuild two/bundle.tar.gz" ||
  fail 'portable archive bytes differ across builds or umasks'
(cd -- "$TMP/rebuild one" && sha256sum -c bundle.tar.gz.sha256) >/dev/null ||
  fail 'reproducible archive checksum invalid'

# An exact allowlist prevents accidental inclusion of secrets or Git metadata.
tar -tzf "$ARCHIVE" | grep -v '/$' | sort > "$TMP/actual"
cat > "$TMP/expected" <<'EXPECTED'
disk-watch-portable/CHANGELOG.md
disk-watch-portable/LICENSE
disk-watch-portable/README.md
disk-watch-portable/disk-watch.conf.example
disk-watch-portable/disk-watch.sh
disk-watch-portable/docs/ROADMAP.md
disk-watch-portable/docs/operations.md
disk-watch-portable/docs/portable.md
disk-watch-portable/docs/smart-usb-standby.md
EXPECTED
if ! diff -u "$TMP/expected" "$TMP/actual"; then
  fail 'portable archive contents differ from the safe allowlist'
fi

mkdir -p "$TMP/unpacked"
tar -xzf "$ARCHIVE" -C "$TMP/unpacked"
PKG="$TMP/unpacked/disk-watch-portable"
[[ -x "$PKG/disk-watch.sh" ]] || fail 'packaged script is not executable'
bash "$PKG/disk-watch.sh" --help | grep -Fq 'check' || fail 'packaged CLI help failed'

mkdir -p "$TMP/mock bin"
cat > "$TMP/mock bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_JOURNAL_MODE:-}" in
  init) printf '%s\n' 'Oct 26 test kernel: startup' '-- cursor: p0' ;;
  error)
    [[ "$*" == *'--after-cursor=p0'* ]] || exit 2
    printf '%s\n' 'Oct 26 test kernel: I/O error, dev sdb, sector 1' '-- cursor: p1'
    ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TMP/mock bin/sendmail" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '-i -t' ]] || exit 2
cat > "$MOCK_MAIL_BODY"
MOCK
cat > "$TMP/mock bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/mock bin/"*
export PATH="$TMP/mock bin:$PATH" MOCK_MAIL_BODY="$TMP/mail.body"
cat > "$TMP/private config" <<'CONFIG'
HOST_LABEL=package-test
TRANSPORT=mail
CONFIG

export MOCK_JOURNAL_MODE=init
bash "$PKG/disk-watch.sh" --config "$TMP/private config" --state-dir "$TMP/local state" init >/dev/null
[[ $(cat "$TMP/local state/kernel.cursor") == p0 ]] || fail 'packaged init did not save cursor'
export MOCK_JOURNAL_MODE=error
bash "$PKG/disk-watch.sh" --config "$TMP/private config" --state-dir "$TMP/local state" check >/dev/null
[[ $(cat "$TMP/local state/kernel.cursor") == p1 ]] || fail 'packaged check did not advance cursor'
grep -Fq 'I/O error, dev sdb' "$TMP/mail.body" || fail 'packaged check did not alert'

# Refuse allowlisted symlinks: cp would otherwise follow them and silently
# include private bytes outside the source tree. Exercise an isolated fixture.
FIXTURE="$TMP/symlink source"
mkdir -p "$FIXTURE/scripts"
cp -a -- "$PKG/." "$FIXTURE/"
cp -- "$ROOT/scripts/build-portable.sh" "$FIXTURE/scripts/build-portable.sh"
printf 'PRIVATE_TEST_MARKER\\n' > "$TMP/outside-private-file"
rm -- "$FIXTURE/README.md"
ln -s -- "$TMP/outside-private-file" "$FIXTURE/README.md"
if bash "$FIXTURE/scripts/build-portable.sh" "$TMP/forbidden.tar.gz" > "$TMP/symlink.log" 2>&1; then
  fail 'builder accepted a symlinked allowlisted file'
fi
grep -Fq 'Refusing symlink in portable archive input: README.md' "$TMP/symlink.log" ||
  fail 'missing symlinked file diagnostic'
[[ ! -e "$TMP/forbidden.tar.gz" && ! -e "$TMP/forbidden.tar.gz.sha256" ]] ||
  fail 'builder created an archive after rejecting a symlinked file'

rm -- "$FIXTURE/README.md"
cp -- "$PKG/README.md" "$FIXTURE/README.md"
mv -- "$FIXTURE/docs" "$TMP/outside-docs"
ln -s -- "$TMP/outside-docs" "$FIXTURE/docs"
if bash "$FIXTURE/scripts/build-portable.sh" "$TMP/forbidden-docs.tar.gz" > "$TMP/docs-symlink.log" 2>&1; then
  fail 'builder accepted a symlinked docs directory'
fi
grep -Fq 'Refusing symlink in portable archive input: docs/' "$TMP/docs-symlink.log" ||
  fail 'missing symlinked docs directory diagnostic'
[[ ! -e "$TMP/forbidden-docs.tar.gz" && ! -e "$TMP/forbidden-docs.tar.gz.sha256" ]] ||
  fail 'builder created an archive after rejecting symlinked docs'

# Refuse symlinked archive and checksum output paths without overwriting the
# referenced files. This runs entirely offline in a private temporary folder.
printf 'KEEP_ARCHIVE_TARGET\n' > "$TMP/archive-target"
ln -s -- "$TMP/archive-target" "$TMP/linked-output.tar.gz"
if bash "$ROOT/scripts/build-portable.sh" "$TMP/linked-output.tar.gz" > "$TMP/output-symlink.log" 2>&1; then
  fail 'builder accepted a symlinked archive output'
fi
grep -Fq 'Refusing symlink in portable archive output:' "$TMP/output-symlink.log" ||
  fail 'missing archive output symlink diagnostic'
[[ $(cat "$TMP/archive-target") == KEEP_ARCHIVE_TARGET ]] ||
  fail 'builder overwrote the archive symlink target'
[[ ! -e "$TMP/linked-output.tar.gz.sha256" ]] ||
  fail 'builder created a checksum for a rejected archive output'

printf 'KEEP_CHECKSUM_TARGET\n' > "$TMP/checksum-target"
ln -s -- "$TMP/checksum-target" "$TMP/linked-checksum.tar.gz.sha256"
if bash "$ROOT/scripts/build-portable.sh" "$TMP/linked-checksum.tar.gz" > "$TMP/checksum-symlink.log" 2>&1; then
  fail 'builder accepted a symlinked checksum output'
fi
grep -Fq 'Refusing symlink in portable archive output:' "$TMP/checksum-symlink.log" ||
  fail 'missing checksum output symlink diagnostic'
[[ $(cat "$TMP/checksum-target") == KEEP_CHECKSUM_TARGET ]] ||
  fail 'builder overwrote the checksum symlink target'
[[ ! -e "$TMP/linked-checksum.tar.gz" ]] ||
  fail 'builder created an archive with a rejected checksum output'

# The checksum must detect corruption, not just exist.
printf 'tampered' >> "$ARCHIVE"
if (cd -- "$TMP" && sha256sum -c -- "portable build.tar.gz.sha256") > /dev/null 2>&1; then
  fail 'checksum accepted a modified archive'
fi

echo 'PASS: reproducible portable archive, allowlist, checksum integrity and offline init/check smoke test'
