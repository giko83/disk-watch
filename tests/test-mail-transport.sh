#!/usr/bin/env bash
# Isolated sendmail transport regressions: no real mail, journal, or systemd.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/disk-watch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_JOURNAL_MODE:-}" in
  init) printf '%s\n' 'Oct 24 00:00:00 test kernel: startup' '-- cursor: mail0' ;;
  error) printf '%s\n' 'Oct 24 00:01:00 test kernel: I/O error, dev sdb, sector 42' '-- cursor: mail1' ;;
  *) echo 'unexpected journal mode' >&2; exit 2 ;;
esac
MOCK
cat > "$TMP/bin/sendmail" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '-i -t' ]] || { echo 'unexpected sendmail arguments' >&2; exit 2; }
if [[ ${MOCK_MAIL_FAIL:-0} == 1 ]]; then exit 75; fi
cat > "$MOCK_MAIL_BODY"
printf 'sent\n' >> "$MOCK_MAIL_LOG"
MOCK
chmod +x "$TMP/bin/"*

cat > "$TMP/disk-watch.conf" <<EOF_CONFIG
HOST_LABEL=mail-test
TRANSPORT=mail
STATE_DIR='$TMP/state'
EOF_CONFIG
export DISK_WATCH_CONFIG="$TMP/disk-watch.conf"
export MOCK_MAIL_BODY="$TMP/mail.body"
export MOCK_MAIL_LOG="$TMP/mail.log"
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_cursor() {
  local actual
  actual=$(cat "$TMP/state/kernel.cursor")
  [[ "$actual" == "$1" ]] || fail "expected cursor $1, got $actual"
}
assert_sent() {
  local actual
  actual=$(wc -l < "$TMP/mail.log")
  [[ "$actual" -eq "$1" ]] || fail "expected $1 sent messages, got $actual"
}

export MOCK_JOURNAL_MODE=init
bash "$SCRIPT" init >/dev/null
assert_cursor mail0
[[ ! -e "$TMP/mail.log" ]] || fail 'init unexpectedly sent mail'

# Test command must use the local mail transport, not Telegram.
bash "$SCRIPT" test >/dev/null
assert_sent 1
grep -Fq 'To: root' "$TMP/mail.body" || fail 'missing mail recipient'
grep -Fq 'Subject: TEST DISK WATCH - mail-test' "$TMP/mail.body" || fail 'missing test subject'
grep -Fq 'Disk Watch notification test' "$TMP/mail.body" || fail 'missing test body'

# A failed sendmail invocation must keep the kernel cursor for retry.
export MOCK_JOURNAL_MODE=error MOCK_MAIL_FAIL=1
if bash "$SCRIPT" scan >/dev/null 2>&1; then fail 'scan succeeded despite sendmail failure'; fi
assert_cursor mail0
assert_sent 1

# Successful retry delivers the pending event exactly once.
export MOCK_MAIL_FAIL=0
bash "$SCRIPT" scan >/dev/null
assert_cursor mail1
assert_sent 2
grep -Fq 'Subject: DISK I/O ALERT - mail-test (1 events)' "$TMP/mail.body" || fail 'missing I/O subject'
grep -Fq 'I/O error, dev sdb' "$TMP/mail.body" || fail 'missing I/O details'

# SMART notification uses the same mail transport and leaves the cursor alone.
export SMARTD_DEVICE=/dev/sdz SMARTD_MESSAGE='SMART threshold reached (test)'
bash "$SCRIPT" smart >/dev/null
assert_cursor mail1
assert_sent 3
grep -Fq 'Subject: SMART ALERT - mail-test - /dev/sdz' "$TMP/mail.body" || fail 'missing SMART subject'
grep -Fq 'SMART threshold reached (test)' "$TMP/mail.body" || fail 'missing SMART message'

echo 'PASS: sendmail test, failed delivery retry, I/O mail and SMART mail'
