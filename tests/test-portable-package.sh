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

# The checksum must detect corruption, not just exist.
printf 'tampered' >> "$ARCHIVE"
if (cd -- "$TMP" && sha256sum -c -- "portable build.tar.gz.sha256") > /dev/null 2>&1; then
  fail 'checksum accepted a modified archive'
fi

echo 'PASS: portable archive allowlist, checksum integrity and offline init/check smoke test'
