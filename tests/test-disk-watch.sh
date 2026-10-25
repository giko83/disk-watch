#!/usr/bin/env bash
# Isolated smoke tests: all journal/Telegram calls are mocked; no real disks or network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' --after-cursor='*)
    printf '%s\n' 'Oct 24 20:00:00 test kernel: I/O error, dev sdb, sector 42' '-- cursor: cursor-next'
    ;;
  *' -n 1 '*)
    printf '%s\n' 'Oct 24 19:59:00 test kernel: previous entry' '-- cursor: cursor-initial'
    ;;
  *) echo "Unexpected journalctl args: $*" >&2; exit 2 ;;
esac
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${MOCK_CURL_FAIL:-0} == 1 ]]; then exit 22; fi
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
MOCK
cat > "$TMP/bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*

cat > "$TMP/disk-watch.conf" <<CONF
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN='dummy-test-token'
TG_CHAT_ID='dummy-test-chat'
STATE_DIR='$TMP/state'
CONF
export PATH="$TMP/bin:$PATH"
export DISK_WATCH_CONFIG="$TMP/disk-watch.conf"
export MOCK_CURL_LOG="$TMP/notifications.log"

assert_cursor() {
  local expected=$1 actual
  actual=$(cat "$TMP/state/kernel.cursor")
  [[ "$actual" == "$expected" ]] || {
    echo "Expected cursor '$expected', got '$actual'" >&2
    exit 1
  }
}

# Init must not replay historical messages and must not overwrite an existing cursor.
bash "$ROOT/disk-watch.sh" init >/dev/null
assert_cursor cursor-initial
bash "$ROOT/disk-watch.sh" init >/dev/null
assert_cursor cursor-initial
[[ ! -e "$MOCK_CURL_LOG" ]] || { echo 'Init unexpectedly notified' >&2; exit 1; }

# If Telegram delivery fails, preserve cursor so the event can be retried.
export MOCK_CURL_FAIL=1
if bash "$ROOT/disk-watch.sh" scan >/dev/null 2>&1; then
  echo 'Expected scan to fail on notification failure' >&2
  exit 1
fi
assert_cursor cursor-initial
[[ ! -e "$MOCK_CURL_LOG" ]] || { echo 'Failed notification was recorded' >&2; exit 1; }

# Successful retry must notify and then advance the cursor.
export MOCK_CURL_FAIL=0
bash "$ROOT/disk-watch.sh" scan >/dev/null
assert_cursor cursor-next
grep -q 'DISK I/O ALERT - test-host' "$MOCK_CURL_LOG"
grep -q 'I/O error, dev sdb' "$MOCK_CURL_LOG"

# SMART helper invocation must include smartd-provided details.
SMARTD_DEVICE=/dev/sda SMARTD_MESSAGE='SMART failure test' \
  bash "$ROOT/disk-watch.sh" smart >/dev/null
grep -q 'SMART ALERT - test-host - /dev/sda' "$MOCK_CURL_LOG"
grep -q 'SMART failure test' "$MOCK_CURL_LOG"

echo 'PASS: init preserves cursor, failed alert retries, scan and SMART notifications work'
