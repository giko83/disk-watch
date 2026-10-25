#!/usr/bin/env bash
# Isolated integration test: no disk access, Telegram traffic or systemd changes.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
export MOCK_ROOT="$TMP_DIR"

cat > "$TMP_DIR/bin/journalctl" <<'MOCK_JOURNAL'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" -n 1 "*)
    printf '%s\n' 'Oct 25 00:00:00 test kernel: initial event' '-- cursor: cursor-init'
    ;;
  *" --after-cursor=cursor-init "*)
    printf '%s\n' 'Oct 25 00:01:00 test kernel: I/O error, dev sdb, sector 123' '-- cursor: cursor-next'
    ;;
  *" --after-cursor=cursor-next "*)
    printf '%s\n' '-- cursor: cursor-next'
    ;;
  *)
    printf 'Unexpected journalctl invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
MOCK_JOURNAL

cat > "$TMP_DIR/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'called' >> "$MOCK_ROOT/notifications"
if [[ ${MOCK_FAIL_DELIVERY:-0} == 1 ]]; then
  exit 22
fi
MOCK_CURL

cat > "$TMP_DIR/bin/logger" <<'MOCK_LOGGER'
#!/usr/bin/env bash
exit 0
MOCK_LOGGER
chmod +x "$TMP_DIR/bin/journalctl" "$TMP_DIR/bin/curl" "$TMP_DIR/bin/logger"
export PATH="$TMP_DIR/bin:$PATH"

cat > "$TMP_DIR/disk-watch.conf" <<CONFIG
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN=FAKE_TEST_TOKEN
TG_CHAT_ID=FAKE_TEST_CHAT
STATE_DIR='$TMP_DIR/state'
CONFIG
export DISK_WATCH_CONFIG="$TMP_DIR/disk-watch.conf"

assert_cursor() {
  local actual
  actual=$(<"$TMP_DIR/state/kernel.cursor")
  [[ "$actual" == "$1" ]] || { printf 'Cursor: expected %s, got %s\n' "$1" "$actual" >&2; exit 1; }
}
assert_notifications() {
  local count=0
  if [[ -f "$TMP_DIR/notifications" ]]; then
    count=$(wc -l < "$TMP_DIR/notifications")
  fi
  [[ "$count" -eq "$1" ]] || { printf 'Notifications: expected %s, got %s\n' "$1" "$count" >&2; exit 1; }
}

"$ROOT_DIR/disk-watch.sh" init
assert_cursor cursor-init
assert_notifications 0

# Delivery failure must NOT consume the kernel journal cursor.
if MOCK_FAIL_DELIVERY=1 "$ROOT_DIR/disk-watch.sh" scan >"$TMP_DIR/failed.log" 2>&1; then
  echo 'scan unexpectedly succeeded after a failed notification' >&2
  exit 1
fi
assert_cursor cursor-init
assert_notifications 1

# Retrying after a failure must deliver the same error and then advance.
"$ROOT_DIR/disk-watch.sh" scan
assert_cursor cursor-next
assert_notifications 2

# Re-running with no new events must not send a duplicate alert.
"$ROOT_DIR/disk-watch.sh" scan
assert_cursor cursor-next
assert_notifications 2

# smartd callback uses the same transport, with no real Telegram request.
SMARTD_DEVICE=/dev/mock SMARTD_MESSAGE='test SMART alert' "$ROOT_DIR/disk-watch.sh" smart
assert_notifications 3

echo 'PASS: cursor initialization, retry, deduplication, SMART forwarding'
