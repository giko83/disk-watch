#!/usr/bin/env bash
# Offline smoke tests: no root privileges, disks, network, or Telegram credentials.
set -euo pipefail

SCRIPT=${1:-"$(cd "$(dirname "$0")/.." && pwd)/disk-watch.sh"}
[[ -f "$SCRIPT" ]] || { echo "Missing script: $SCRIPT" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_JOURNAL_ARGS"
if [[ " $* " == *' -n 1 '* ]]; then
  printf '%s\n' 'Oct 01 kernel: initial event' '-- cursor: cursor-0'
else
  printf '%s\n' "$MOCK_JOURNAL_LINE" "-- cursor: $MOCK_NEXT_CURSOR"
fi
MOCK
cat > "$TMP/bin/sendmail" <<'MOCK'
#!/usr/bin/env bash
cat > "$MOCK_MAIL_FILE"
[[ ${MOCK_SENDMAIL_FAIL:-0} != 1 ]]
MOCK
cat > "$TMP/bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*

printf 'HOST_LABEL=test-host\nTRANSPORT=mail\nSTATE_DIR=%q\n' "$TMP/state" > "$TMP/config"
export DISK_WATCH_CONFIG="$TMP/config"
export MOCK_JOURNAL_ARGS="$TMP/journal-args"
export MOCK_MAIL_FILE="$TMP/mail"
export MOCK_JOURNAL_LINE='Oct 01 kernel: normal message'
export MOCK_NEXT_CURSOR=cursor-1
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_cursor() {
  [[ $(<"$TMP/state/kernel.cursor") == "$1" ]] || fail "expected cursor $1"
}

# Initialization must not notify, and repeated init must preserve the cursor.
bash "$SCRIPT" init >/dev/null
assert_cursor cursor-0
[[ ! -e "$TMP/mail" ]] || fail 'init unexpectedly sent mail'
bash "$SCRIPT" init >/dev/null
assert_cursor cursor-0

# Clean scan advances cursor but does not notify.
bash "$SCRIPT" scan
assert_cursor cursor-1
[[ ! -e "$TMP/mail" ]] || fail 'clean scan unexpectedly sent mail'
grep -Fq -- '--after-cursor=cursor-0' "$TMP/journal-args" || fail 'scan did not use saved cursor'

# Storage error produces one alert and advances cursor only after delivery.
export MOCK_JOURNAL_LINE='Oct 01 kernel: I/O error, dev sda, sector 42'
export MOCK_NEXT_CURSOR=cursor-2
bash "$SCRIPT" scan
assert_cursor cursor-2
grep -Fq 'DISK I/O ALERT - test-host (1 events)' "$TMP/mail" || fail 'missing alert subject'
grep -Fq 'I/O error, dev sda' "$TMP/mail" || fail 'missing disk error'

# Failed delivery must retain the cursor for retry.
export MOCK_NEXT_CURSOR=cursor-3 MOCK_SENDMAIL_FAIL=1
if bash "$SCRIPT" scan; then fail 'failed mail delivery returned success'; fi
assert_cursor cursor-2
export MOCK_SENDMAIL_FAIL=0
bash "$SCRIPT" scan
assert_cursor cursor-3

# SMART notification is routed through the same transport.
export SMARTD_DEVICE=/dev/sda SMARTD_MESSAGE='SMART test warning'
bash "$SCRIPT" smart
grep -Fq 'SMART ALERT - test-host - /dev/sda' "$TMP/mail" || fail 'missing SMART subject'
grep -Fq 'SMART test warning' "$TMP/mail" || fail 'missing SMART message'

echo 'PASS: init, clean scan, disk alert, retry, SMART alert'
