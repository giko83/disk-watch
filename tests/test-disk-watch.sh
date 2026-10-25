#!/usr/bin/env bash
# Dependency-free smoke tests. Mocks journalctl/curl; never reads the real journal,
# contacts Telegram, or writes to /etc or /var/lib.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/disk-watch.sh"
[[ -r "$SCRIPT" ]] || { echo "Missing $SCRIPT" >&2; exit 1; }
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/bin"

cat > "$WORKDIR/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' -n 1 '*) printf '%s\n' '-- cursor: c0' ;;
  *' --after-cursor=c0 '*)
    case "$TEST_SCENARIO" in
      clean) printf '%s\n' 'Oct 24 host kernel: USB device connected' ;;
      error) printf '%s\n' 'Oct 24 host kernel: I/O error, dev sdb, sector 42' ;;
      *) echo 'Unknown test scenario' >&2; exit 1 ;;
    esac
    printf '%s\n' '-- cursor: c1'
    ;;
  *' --after-cursor=c1 '*) printf '%s\n' '-- cursor: c1' ;;
  *) echo "Unexpected journalctl arguments: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$WORKDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
printf 'sent\n' >> "$TEST_CURL_LOG"
MOCK
cat > "$WORKDIR/bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$WORKDIR/bin/"*
export PATH="$WORKDIR/bin:$PATH"
export DISK_WATCH_CONFIG="$WORKDIR/disk-watch.conf"
export TEST_CURL_LOG="$WORKDIR/curl.log"
cat > "$DISK_WATCH_CONFIG" <<'CONFIG'
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN=dummy-token
TG_CHAT_ID=dummy-chat
CONFIG

assert_cursor() {
  local expected=$1
  local actual
  actual=$(<"$STATE_DIR/kernel.cursor")
  [[ "$actual" == "$expected" ]] || {
    echo "Expected cursor $expected, got $actual" >&2
    exit 1
  }
}
assert_sends() {
  local expected=$1 actual=0
  if [[ -f "$TEST_CURL_LOG" ]]; then
    actual=$(wc -l < "$TEST_CURL_LOG")
  fi
  [[ "$actual" -eq "$expected" ]] || {
    echo "Expected $expected notifications, got $actual" >&2
    exit 1
  }
}
reset_case() {
  export STATE_DIR="$WORKDIR/state-$1"
  rm -f "$TEST_CURL_LOG"
}

# Initialization starts from the newest journal cursor and is idempotent.
reset_case init
export TEST_SCENARIO=clean
bash "$SCRIPT" init >/dev/null
assert_cursor c0
bash "$SCRIPT" init >/dev/null
assert_cursor c0

# Normal non-error kernel messages advance the cursor without notifications.
reset_case clean
bash "$SCRIPT" init >/dev/null
bash "$SCRIPT" scan
assert_cursor c1
assert_sends 0

# An I/O error is reported exactly once; the next scan sees no new errors.
reset_case error
export TEST_SCENARIO=error
bash "$SCRIPT" init >/dev/null
bash "$SCRIPT" scan
assert_cursor c1
assert_sends 1
bash "$SCRIPT" scan
assert_cursor c1
assert_sends 1

# Delivery failure must not advance the cursor; a retry can report the error.
reset_case retry
bash "$SCRIPT" init >/dev/null
export MOCK_CURL_FAIL=1
if bash "$SCRIPT" scan >/dev/null 2>&1; then
  echo 'Expected failed delivery to make scan fail' >&2
  exit 1
fi
assert_cursor c0
assert_sends 0
unset MOCK_CURL_FAIL
bash "$SCRIPT" scan
assert_cursor c1
assert_sends 1

printf '%s\n' 'PASS: initialization, clean scan, single alert, retry after delivery failure'
