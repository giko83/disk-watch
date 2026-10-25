#!/usr/bin/env bash
# Hermetic regression tests: no root, disk access, network, or systemd required.
set -euo pipefail

SCRIPT=${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/disk-watch.sh"}
[[ -f "$SCRIPT" ]] || { echo "Missing script: $SCRIPT" >&2; exit 1; }
SCRIPT=$(realpath "$SCRIPT")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state"
export TEST_WORK="$WORK"
export DISK_WATCH_CONFIG="$WORK/config"
export PATH="$WORK/bin:$PATH"
cat > "$DISK_WATCH_CONFIG" <<EOF_CONFIG
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN='fake-test-token'
TG_CHAT_ID='fake-chat-id'
STATE_DIR='$WORK/state'
EOF_CONFIG

cat > "$WORK/bin/journalctl" <<'EOF_JOURNAL'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' -n 1 '* ]]; then
  printf '%s\n' '2026-01-01 test-host kernel: boot' '-- cursor: CURSOR-START'
  exit 0
fi
[[ " $* " == *' --after-cursor='* ]] || { echo 'Unexpected journalctl invocation' >&2; exit 1; }
printf '%s\n' "$*" >> "$TEST_WORK/journal-args"
case "${TEST_JOURNAL_MODE:-clean}" in
  clean)
    printf '%s\n' '2026-01-01 test-host kernel: ordinary message' '-- cursor: CURSOR-CLEAN'
    ;;
  error)
    printf '%s\n' '2026-01-01 test-host kernel: I/O error, dev sdb, sector 42' '-- cursor: CURSOR-ERROR'
    ;;
  empty)
    :
    ;;
  *) exit 2 ;;
esac
EOF_JOURNAL
cat > "$WORK/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    text=*) printf '%s\n' "${arg#text=}" >> "$TEST_WORK/notifications" ;;
  esac
done
if [[ "${TEST_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
EOF_CURL
cat > "$WORK/bin/logger" <<'EOF_LOGGER'
#!/usr/bin/env bash
exit 0
EOF_LOGGER
chmod +x "$WORK/bin/"*

assert_eq() {
  local expected=$1 actual=$2 label=$3
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}
assert_contains() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: missing '$1' in $2" >&2; exit 1; }
}

# 1. Initialization records the newest cursor and never resets it.
bash "$SCRIPT" init >/dev/null
assert_eq CURSOR-START "$(<"$WORK/state/kernel.cursor")" 'initial cursor'
bash "$SCRIPT" init >/dev/null
assert_eq CURSOR-START "$(<"$WORK/state/kernel.cursor")" 'init idempotence'

# 2. Normal journal messages advance the cursor without notifying.
TEST_JOURNAL_MODE=clean bash "$SCRIPT" scan
assert_eq CURSOR-CLEAN "$(<"$WORK/state/kernel.cursor")" 'clean scan cursor'
[[ ! -e "$WORK/notifications" ]] || { echo 'FAIL: clean scan notified' >&2; exit 1; }

# 3. A delivery failure must not advance the cursor; retry should alert.
if TEST_JOURNAL_MODE=error TEST_CURL_FAIL=1 bash "$SCRIPT" scan >/dev/null 2>&1; then
  echo 'FAIL: failed notification returned success' >&2; exit 1
fi
assert_eq CURSOR-CLEAN "$(<"$WORK/state/kernel.cursor")" 'failed delivery cursor'
TEST_JOURNAL_MODE=error bash "$SCRIPT" scan
assert_eq CURSOR-ERROR "$(<"$WORK/state/kernel.cursor")" 'successful delivery cursor'
assert_contains 'DISK I/O ALERT - test-host (1 events)' "$WORK/notifications"
assert_contains 'I/O error, dev sdb, sector 42' "$WORK/notifications"
assert_contains '--after-cursor=CURSOR-CLEAN' "$WORK/journal-args"

# 4. SMART notification includes device and smartd message.
SMARTD_DEVICE=/dev/sdb SMARTD_MESSAGE='SMART prefailure attribute' bash "$SCRIPT" smart
assert_contains 'SMART ALERT - test-host - /dev/sdb' "$WORK/notifications"
assert_contains 'SMART prefailure attribute' "$WORK/notifications"

# 5. Empty journal result does not overwrite a valid cursor.
TEST_JOURNAL_MODE=empty bash "$SCRIPT" scan
assert_eq CURSOR-ERROR "$(<"$WORK/state/kernel.cursor")" 'empty scan cursor'

printf '%s\n' 'PASS: init, clean scan, failed-delivery retry, SMART alert, empty journal'
