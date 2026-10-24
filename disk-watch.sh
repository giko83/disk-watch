#!/usr/bin/env bash
set -euo pipefail

CONFIG=${DISK_WATCH_CONFIG:-/etc/disk-watch.conf}
if [[ ! -r "$CONFIG" ]]; then echo "Missing config: $CONFIG" >&2; exit 1; fi
# shellcheck source=/dev/null
source "$CONFIG"
HOST_LABEL=${HOST_LABEL:-$(hostname -s)}
TRANSPORT=${TRANSPORT:-mail}
STATE_DIR=${STATE_DIR:-/var/lib/disk-watch}
PATTERN=${PATTERN:-'I/O error|medium error|uncorrectable|unrecovered|critical medium|Buffer I/O error|failed command|blk_update_request|nvme.*(error|timeout)|ata[0-9].*(error|exception|failed)'}
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
CURSOR_FILE="$STATE_DIR/kernel.cursor"

notify() {
  local subject=$1 body=$2
  case "$TRANSPORT" in
    mail)
      command -v sendmail >/dev/null || { echo 'sendmail missing' >&2; return 1; }
      printf 'To: root\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$subject" "$body" | sendmail -i -t
      ;;
    telegram)
      [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || { echo 'Telegram credentials missing' >&2; return 1; }
      command -v curl >/dev/null || { echo 'curl missing' >&2; return 1; }
      curl --silent --show-error --fail --retry 2 --retry-delay 2 --connect-timeout 5 --max-time 20 \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$subject

$body" >/dev/null
      ;;
    *) echo "Unknown TRANSPORT: $TRANSPORT" >&2; return 1;;
  esac
}

case "${1:-scan}" in
  test)
    notify "TEST DISK WATCH - $HOST_LABEL" "Disk Watch notification test from $HOST_LABEL."
    echo 'Notification submitted; verify receipt.'
    ;;
  smart)
    subject="SMART ALERT - $HOST_LABEL - ${SMARTD_DEVICE:-unknown}"
    body="${SMARTD_MESSAGE:-${SMARTD_FAILTYPE:-SMART warning}}"
    notify "$subject" "$body"
    ;;
  init)
    if [[ -s "$CURSOR_FILE" ]]; then echo 'Cursor already exists; no reset.'; exit 0; fi
    latest=$(journalctl -k -n 1 --show-cursor --no-pager -o short-iso)
    cursor=$(printf '%s\n' "$latest" | sed -n 's/^-- cursor: //p' | tail -n 1)
    [[ -n "$cursor" ]] || { echo 'Cannot initialize journal cursor' >&2; exit 1; }
    printf '%s\n' "$cursor" > "$CURSOR_FILE"
    chmod 600 "$CURSOR_FILE"
    echo 'Initialized; historic kernel events excluded.'
    ;;
  scan)
    [[ -s "$CURSOR_FILE" ]] || { echo 'Run init first' >&2; exit 1; }
    exec 9>"$STATE_DIR/scan.lock"
    flock -n 9 || exit 0
    previous=$(<"$CURSOR_FILE")
    data=$(journalctl -k --after-cursor="$previous" --show-cursor --no-pager -o short-iso)
    cursor=$(printf '%s\n' "$data" | sed -n 's/^-- cursor: //p' | tail -n 1)
    [[ -n "$cursor" ]] || exit 0
    matches=$(printf '%s\n' "$data" | grep -Ei "$PATTERN" || true)
    if [[ -n "$matches" ]]; then
      count=$(printf '%s\n' "$matches" | wc -l)
      sample=$(printf '%s\n' "$matches" | tail -n 8 | cut -c1-220)
      notify "DISK I/O ALERT - $HOST_LABEL ($count events)" "New kernel disk/storage errors on $HOST_LABEL:

$sample

Inspect: journalctl -k"
      logger -t disk-watch "Sent alert for $count kernel events"
    fi
    printf '%s\n' "$cursor" > "$CURSOR_FILE.tmp"
    chmod 600 "$CURSOR_FILE.tmp"
    mv -f "$CURSOR_FILE.tmp" "$CURSOR_FILE"
    ;;
  *) echo "Usage: $0 [init|scan|test|smart]" >&2; exit 2;;
esac
