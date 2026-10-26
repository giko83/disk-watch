#!/usr/bin/env bash
# Portable one-shot CLI tests; no root, real disks, journald, mail or systemd.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/disk-watch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mock bin"

cat > "$TMP/mock bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "${MOCK_JOURNAL_MODE:-}" in
  init) printf '%s\n' 'Oct 26 10:00:00 test kernel: startup' '-- cursor: portable0' ;;
  error)
    [[ "$*" == *'--after-cursor=portable0'* ]] || exit 2
    printf '%s\n' 'Oct 26 10:01:00 test kernel: I/O error, dev sdb, sector 1' '-- cursor: portable1'
    ;;
  fail) echo 'journal unavailable (mock)' >&2; exit 42 ;;
  *) echo 'unexpected journal mode' >&2; exit 2 ;;
esac
MOCK
cat > "$TMP/mock bin/sendmail" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '-i -t' ]] || exit 2
cat > "$MOCK_MAIL_BODY"
MOCK
cat > "$TMP/mock bin/logger" <<'MOCK'
#!/usr/bin/env bash
# Never contact host syslog during offline regression tests.
exit 0
MOCK
chmod +x "$TMP/mock bin/"*
export PATH="$TMP/mock bin:$PATH"
export MOCK_MAIL_BODY="$TMP/mail.body"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --help must work even without a config file, state directory or root access.
DISK_WATCH_CONFIG="$TMP/nonexistent.conf" bash "$SCRIPT" --help > "$TMP/help"
grep -Fq 'check' "$TMP/help" || fail 'help missing check command'
[[ ! -e "$TMP/cli state" ]] || fail 'help created state'

cat > "$TMP/config with spaces.conf" <<EOF_CONFIG
HOST_LABEL=portable-host
TRANSPORT=mail
STATE_DIR='$TMP/config state'
EOF_CONFIG
export DISK_WATCH_CONFIG="$TMP/invalid-env.conf"
export DISK_WATCH_STATE_DIR="$TMP/env state"

# CLI values override environment and sourced configuration; paths may contain spaces.
export MOCK_JOURNAL_MODE=init
bash "$SCRIPT" --config "$TMP/config with spaces.conf" init --state-dir "$TMP/cli state" > /dev/null
[[ $(cat "$TMP/cli state/kernel.cursor") == portable0 ]] || fail 'CLI state directory ignored'
[[ ! -e "$TMP/config state" ]] || fail 'config state unexpectedly used'
[[ ! -e "$TMP/env state" ]] || fail 'environment state unexpectedly used'

# check is a one-shot alias of scan; notification goes through the configured transport.
export MOCK_JOURNAL_MODE=error
bash "$SCRIPT" check --config "$TMP/config with spaces.conf" --state-dir "$TMP/cli state" > /dev/null
[[ $(cat "$TMP/cli state/kernel.cursor") == portable1 ]] || fail 'check did not advance cursor'
grep -Fq 'DISK I/O ALERT - portable-host' "$TMP/mail.body" || fail 'portable check did not alert'

# Existing directories must not have their permissions rewritten by the CLI.
mkdir -p "$TMP/existing dir"
chmod 755 "$TMP/existing dir"
export MOCK_JOURNAL_MODE=init
bash "$SCRIPT" --config "$TMP/config with spaces.conf" --state-dir "$TMP/existing dir" init > /dev/null
[[ $(stat -c '%a' "$TMP/existing dir") == 755 ]] || fail 'existing state directory permissions changed'
[[ $(stat -c '%a' "$TMP/existing dir/kernel.cursor") == 600 ]] || fail 'cursor permissions are not private'

# Environment paths also work when no CLI override is supplied.
export DISK_WATCH_CONFIG="$TMP/config with spaces.conf" MOCK_JOURNAL_MODE=init
bash "$SCRIPT" init > /dev/null
[[ $(cat "$TMP/env state/kernel.cursor") == portable0 ]] || fail 'environment state directory ignored'

# A failed journal read must give a useful error and preserve cursor.
export MOCK_JOURNAL_MODE=fail
if bash "$SCRIPT" check > "$TMP/out" 2> "$TMP/err"; then fail 'check succeeded after journal failure'; fi
grep -Fq 'Cannot read kernel journal' "$TMP/err" || fail 'missing journal failure diagnostic'
[[ $(cat "$TMP/env state/kernel.cursor") == portable0 ]] || fail 'journal failure advanced cursor'

# Invalid options and missing config must fail with useful diagnostics.
if bash "$SCRIPT" --config "$TMP/missing.conf" check > "$TMP/out" 2> "$TMP/err"; then fail 'missing config accepted'; fi
grep -Fq 'Missing config' "$TMP/err" || fail 'missing config diagnostic absent'
if bash "$SCRIPT" --state-dir > "$TMP/out" 2> "$TMP/err"; then fail 'missing option value accepted'; fi
grep -Fq 'Missing value for --state-dir' "$TMP/err" || fail 'missing value diagnostic absent'
if bash "$SCRIPT" bogus > "$TMP/out" 2> "$TMP/err"; then fail 'unknown command accepted'; fi
grep -Fq 'Unknown command' "$TMP/err" || fail 'unknown command diagnostic absent'

echo 'PASS: portable CLI, path overrides with spaces, one-shot check, journal errors, help and validation'
