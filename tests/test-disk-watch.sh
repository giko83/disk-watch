#!/usr/bin/env bash
# Isolated smoke tests: no real journal, Telegram, or systemd access.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/disk-watch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_JOURNAL_MODE:-}" in
  init)
    printf '%s\n' 'Oct 24 00:00:00 test kernel: normal startup' '-- cursor: c0'
    ;;
  error)
    printf '%s\n' 'Oct 24 00:01:00 test kernel: I/O error, dev sdb, sector 42' '-- cursor: c1'
    ;;
  clean)
    printf '%s\n' 'Oct 24 00:02:00 test kernel: no errors' '-- cursor: c2'
    ;;
  *) echo 'unexpected journal mode' >&2; exit 2;;
esac
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ ${MOCK_CURL_FAIL:-0} == 1 ]]; then exit 22; fi
printf 'call\n' >> "$MOCK_CURL_LOG"
printf '%s' "$*" > "$MOCK_CURL_BODY"
MOCK
cat > "$TMP/bin/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*

cat > "$TMP/disk-watch.conf" <<EOF_CONFIG
HOST_LABEL=test-host
TRANSPORT=telegram
TG_BOT_TOKEN=not-a-real-token
TG_CHAT_ID=not-a-real-chat
STATE_DIR='$TMP/state'
EOF_CONFIG
export DISK_WATCH_CONFIG="$TMP/disk-watch.conf"
export MOCK_CURL_LOG="$TMP/curl.log"
export MOCK_CURL_BODY="$TMP/curl.body"
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_cursor() {
  local got
  got=$(cat "$TMP/state/kernel.cursor")
  [[ $got == "$1" ]] || fail "expected cursor $1, got $got"
}

# Initializing from a journal snapshot must not notify or replay historical entries.
export MOCK_JOURNAL_MODE=init
bash "$SCRIPT" init >/dev/null
assert_cursor c0
[[ ! -e "$TMP/curl.log" ]] || fail 'init unexpectedly sent an alert'

# Failed Telegram delivery must not advance the cursor; the event must remain retryable.
export MOCK_JOURNAL_MODE=error MOCK_CURL_FAIL=1
if bash "$SCRIPT" scan >/dev/null 2>&1; then fail 'scan succeeded despite failed notification'; fi
assert_cursor c0
[[ ! -e "$TMP/curl.log" ]] || fail 'failed mock delivery recorded a success'

# A subsequent successful scan must deliver the pending error and advance the cursor.
export MOCK_CURL_FAIL=0
bash "$SCRIPT" scan >/dev/null
assert_cursor c1
[[ $(wc -l < "$TMP/curl.log") -eq 1 ]] || fail 'expected one alert'
grep -q 'I/O error, dev sdb' "$TMP/curl.body" || fail 'missing error details in alert'

# A clean journal interval should advance the cursor without notifying.
export MOCK_JOURNAL_MODE=clean
bash "$SCRIPT" scan >/dev/null
assert_cursor c2
[[ $(wc -l < "$TMP/curl.log") -eq 1 ]] || fail 'clean interval sent an alert'

# SMART notifications must include device/message and must not touch the journal cursor.
export SMARTD_DEVICE=/dev/sdz
export SMARTD_MESSAGE='SMART threshold reached (test)'
bash "$SCRIPT" smart >/dev/null
assert_cursor c2
[[ $(wc -l < "$TMP/curl.log") -eq 2 ]] || fail 'expected SMART alert after I/O alert'
grep -Fq 'SMART ALERT - test-host - /dev/sdz' "$TMP/curl.body" || fail 'missing SMART device in subject'
grep -Fq 'SMART threshold reached (test)' "$TMP/curl.body" || fail 'missing SMART description'

# A failed SMART delivery must return an error and leave journal state unchanged.
export MOCK_CURL_FAIL=1
if bash "$SCRIPT" smart >/dev/null 2>&1; then fail 'SMART alert succeeded despite failed notification'; fi
assert_cursor c2
[[ $(wc -l < "$TMP/curl.log") -eq 2 ]] || fail 'failed SMART delivery recorded a success'
unset SMARTD_DEVICE SMARTD_MESSAGE MOCK_CURL_FAIL

echo 'PASS: cursor initialization, retry, error delivery, clean scan, SMART notification and failure'
