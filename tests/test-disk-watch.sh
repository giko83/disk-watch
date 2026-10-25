#!/usr/bin/env bash
# Hermetic smoke tests: all journal, Telegram and logger calls are mocked.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP="$SCRIPT_DIR/../disk-watch.sh"
ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/state"

cat > "$ROOT/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' --after-cursor='* ]]; then
  case "${FAKE_JOURNAL_MODE:-clean}" in
    clean) printf '%s\n' 'Oct 24 20:40:00 host kernel: harmless message' '-- cursor: CURSOR-NEW' ;;
    alert) printf '%s\n' 'Oct 24 20:40:00 host kernel: I/O error, dev sdb, sector 123' '-- cursor: CURSOR-NEW' ;;
    error) exit 1 ;;
    *) exit 2 ;;
  esac
else
  printf '%s\n' 'Oct 24 20:39:00 host kernel: previous message' '-- cursor: CURSOR-START'
fi
MOCK
cat > "$ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# Record only the message, never the API URL (which contains the bot token).
for arg in "$@"; do
  case "$arg" in
    text=*) printf '%s\n' "${arg#text=}" >> "$FAKE_CURL_LOG" ;;
  esac
done
if [[ "${FAKE_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
MOCK
cat > "$ROOT/bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$ROOT/bin/"*

cat > "$ROOT/disk-watch.conf" <<CONFIG
STATE_DIR='$ROOT/state'
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN='dummy-test-token'
TG_CHAT_ID='12345'
CONFIG
export DISK_WATCH_CONFIG="$ROOT/disk-watch.conf"
export FAKE_CURL_LOG="$ROOT/curl-messages.log"
export PATH="$ROOT/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_cursor() {
  local actual
  actual=$(<"$ROOT/state/kernel.cursor")
  [[ "$actual" == "$1" ]] || fail "expected cursor '$1', got '$actual'"
}
assert_messages() {
  local actual=0
  if [[ -f "$FAKE_CURL_LOG" ]]; then
    actual=$(grep -c '^\(DISK I/O ALERT\|SMART ALERT\|TEST DISK WATCH\)' "$FAKE_CURL_LOG" || true)
  fi
  [[ "$actual" -eq "$1" ]] || fail "expected $1 notifications, got $actual"
}

# Initialization seeds the cursor without sending historical errors.
"$APP" init >/dev/null
assert_cursor CURSOR-START
assert_messages 0
"$APP" init >/dev/null
assert_cursor CURSOR-START

# A clean scan advances the cursor without sending an alert.
FAKE_JOURNAL_MODE=clean "$APP" scan
assert_cursor CURSOR-NEW
assert_messages 0

# A failed Telegram delivery must not advance the cursor, so retry is possible.
printf '%s\n' CURSOR-START > "$ROOT/state/kernel.cursor"
if FAKE_JOURNAL_MODE=alert FAKE_CURL_FAIL=1 "$APP" scan; then
  fail 'scan succeeded despite failed notification'
fi
assert_cursor CURSOR-START
assert_messages 1

# Successful retry sends the alert and advances the cursor.
FAKE_JOURNAL_MODE=alert "$APP" scan
assert_cursor CURSOR-NEW
assert_messages 2

# Failed journal reads must also preserve the cursor.
if FAKE_JOURNAL_MODE=error "$APP" scan; then
  fail 'scan succeeded despite failed journal read'
fi
assert_cursor CURSOR-NEW
assert_messages 2

# SMART alerts use the same transport and include smartd context.
SMARTD_DEVICE=/dev/test SMARTD_MESSAGE='SMART mock failure' "$APP" smart
assert_messages 3
grep -q 'SMART mock failure' "$FAKE_CURL_LOG" || fail 'SMART message not forwarded'

"$APP" test >/dev/null
assert_messages 4
printf 'PASS: cursor initialization, clean scan, failed delivery, retry, journal error, SMART, test\n'
