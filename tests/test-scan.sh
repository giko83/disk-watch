#!/usr/bin/env bash
# Integration tests for journal cursor handling; all external I/O is mocked.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
  *' --after-cursor=initial '*)
    printf '%s\n' '2026-10-24 kernel: I/O error, dev sda' '-- cursor: after-error'
    ;;
  *' --after-cursor=after-error '*)
    printf '%s\n' '2026-10-24 kernel: routine message' '-- cursor: after-normal'
    ;;
  *) echo "Unexpected journalctl invocation: $*" >&2; exit 2;;
esac
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'call\n' >> "$MOCK_CALLS"
if [[ "${MOCK_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
MOCK
cat > "$TMP/bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*

cat > "$TMP/config" <<CONF
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN=test-token
TG_CHAT_ID=test-chat
STATE_DIR=$TMP/state
CONF
printf 'initial\n' > "$TMP/state/kernel.cursor"
export PATH="$TMP/bin:$PATH" DISK_WATCH_CONFIG="$TMP/config" MOCK_CALLS="$TMP/calls"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_cursor() {
  local actual
  actual=$(cat "$TMP/state/kernel.cursor")
  [[ "$actual" == "$1" ]] || fail "cursor expected '$1', got '$actual'"
}
assert_calls() {
  local count
  count=$(wc -l < "$TMP/calls")
  [[ "$count" -eq "$1" ]] || fail "expected $1 notifications, got $count"
}

# Failed delivery must not consume the kernel error; next scan should retry it.
if MOCK_CURL_FAIL=1 bash "$ROOT/disk-watch.sh" scan; then
  fail 'scan succeeded despite failed Telegram delivery'
fi
assert_cursor initial
assert_calls 1

bash "$ROOT/disk-watch.sh" scan
assert_cursor after-error
assert_calls 2

# Normal kernel lines advance the cursor without generating an alert.
bash "$ROOT/disk-watch.sh" scan
assert_cursor after-normal
assert_calls 2

printf 'PASS: failed delivery preserves cursor; retry and quiet scan advance it\n'
