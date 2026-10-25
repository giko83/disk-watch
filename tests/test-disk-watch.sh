#!/usr/bin/env bash
# Offline regression test: no real journal access, mail delivery, or root privileges.
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$PROJECT_ROOT/disk-watch.sh"
bash -n "$SCRIPT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mockbin" "$TMP/state"

cat > "$TMP/mockbin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
  *' --after-cursor=CURSOR0 '*)
    printf '%s\n' '2026-10-25 test kernel: I/O error, dev sdb, sector 42' '-- cursor: CURSOR1'
    ;;
  *' --after-cursor=CURSOR1 '*)
    printf '%s\n' '-- cursor: CURSOR1'
    ;;
  *' -n 1 '*)
    printf '%s\n' '2026-10-25 test kernel: previous event' '-- cursor: CURSOR0'
    ;;
  *) echo "Unexpected journalctl arguments: $*" >&2; exit 2 ;;
esac
MOCK
cat > "$TMP/mockbin/sendmail" <<'MOCK'
#!/usr/bin/env bash
if [[ ${FAIL_SENDMAIL:-0} == 1 ]]; then exit 75; fi
cat > "$TEST_MAIL_FILE"
printf 'sent\n' >> "$TEST_SEND_COUNT"
MOCK
cat > "$TMP/mockbin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/mockbin/"*

printf 'HOST_LABEL=test-node\nTRANSPORT=mail\nSTATE_DIR=%q\nPATTERN=%q\n' \
  "$TMP/state" 'I/O error' > "$TMP/config"
export DISK_WATCH_CONFIG="$TMP/config"
export TEST_MAIL_FILE="$TMP/mail"
export TEST_SEND_COUNT="$TMP/sends"
export PATH="$TMP/mockbin:$PATH"

assert_cursor() {
  local got
  got=$(<"$TMP/state/kernel.cursor")
  [[ "$got" == "$1" ]] || { echo "Expected cursor '$1', got '$got'" >&2; exit 1; }
}

bash "$SCRIPT" init >/dev/null
assert_cursor CURSOR0

# Failed delivery must leave the cursor unchanged so the alert is retried.
if FAIL_SENDMAIL=1 bash "$SCRIPT" scan >/dev/null 2>&1; then
  echo 'scan unexpectedly succeeded when sendmail failed' >&2
  exit 1
fi
assert_cursor CURSOR0

# Successful retry delivers the alert and advances the cursor exactly once.
bash "$SCRIPT" scan >/dev/null
assert_cursor CURSOR1
[[ $(wc -l < "$TMP/sends") -eq 1 ]]
grep -q 'I/O error, dev sdb, sector 42' "$TMP/mail"
grep -q 'DISK I/O ALERT - test-node (1 events)' "$TMP/mail"

# A second scan with no new events must not send another notification.
bash "$SCRIPT" scan >/dev/null
assert_cursor CURSOR1
[[ $(wc -l < "$TMP/sends") -eq 1 ]]

# Re-running init must not discard an existing cursor.
bash "$SCRIPT" init >/dev/null
assert_cursor CURSOR1

echo 'PASS: cursor initialization, retry on failure, delivery, deduplication'
