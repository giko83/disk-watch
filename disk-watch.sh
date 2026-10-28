#!/usr/bin/env bash
set -euo pipefail

# Read-only disk reports bypass the notification config and the journal.
# The health helper only calls smartctl after explicit --refresh --wake-ok.
case "${1:-}" in
  status|disks|health|history|report)
    exec bash "$(dirname "${BASH_SOURCE[0]}")/disk-watch-health.sh" "$@" ;;
esac

# Parse portable CLI options before reading configuration or touching state.
usage() {
  cat <<'USAGE'
Usage: disk-watch.sh [--config FILE] [--state-dir DIR] [init|check|scan|test|smart]
       disk-watch.sh status|disks|health|history|report [options] (see docs/health.md)

  check     Scan new kernel messages once (alias of scan; suitable for cron).
  init      Seed the journal cursor without replaying older messages.
  scan      Scan new kernel messages (also the default command).
  test      Send a notification test.
  smart     Forward a smartd notification.

  --config FILE     Use a trusted Bash configuration file (default /etc/disk-watch.conf).
  --state-dir DIR   Keep cursor and lock files in DIR (default /var/lib/disk-watch).
  --help            Show this help without loading configuration.

Environment: DISK_WATCH_CONFIG, DISK_WATCH_STATE_DIR are also supported.
CLI options take precedence over environment and configuration settings.
USAGE
}

cli_config=''
cli_state_dir=''
command_name=''
while (($# > 0)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --config|--state-dir)
      option=$1
      if (($# < 2)) || [[ -z ${2:-} || ${2:-} == --* ]]; then
        echo "Missing value for $option" >&2; exit 2
      fi
      if [[ $option == --config ]]; then cli_config=$2; else cli_state_dir=$2; fi
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n $command_name ]]; then
        echo "Unexpected argument: $1" >&2; usage >&2; exit 2
      fi
      command_name=$1
      shift
      ;;
  esac
done
command_name=${command_name:-scan}
case "$command_name" in
  init|scan|check|test|smart) ;;
  *) echo "Unknown command: $command_name" >&2; usage >&2; exit 2 ;;
esac

CONFIG=${cli_config:-${DISK_WATCH_CONFIG:-/etc/disk-watch.conf}}
if [[ ! -r "$CONFIG" ]]; then echo "Missing config: $CONFIG" >&2; exit 1; fi
# shellcheck source=/dev/null
source "$CONFIG"
HOST_LABEL=${HOST_LABEL:-$(hostname -s)}
TRANSPORT=${TRANSPORT:-mail}
STATE_DIR=${cli_state_dir:-${DISK_WATCH_STATE_DIR:-${STATE_DIR:-/var/lib/disk-watch}}}
PATTERN=${PATTERN:-'I/O error|medium error|uncorrectable|unrecovered|critical medium|Buffer I/O error|failed command|blk_update_request|nvme.*(error|timeout)|ata[0-9].*(error|exception|failed)'}
# Notification-only commands must not require writable persistent state.
# Journal commands keep the existing private cursor/lock behavior.
if [[ $command_name == init || $command_name == scan || $command_name == check ]]; then
  # Do not chmod an existing caller-chosen directory (portable mode).
  umask 077
  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p -- "$STATE_DIR"
    chmod 700 -- "$STATE_DIR"
  fi
  CURSOR_FILE="$STATE_DIR/kernel.cursor"
fi

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
      # A URL argument would expose the bot token via the process command line.
      # Validate before embedding it in curl's stdin configuration.
      [[ $TG_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo 'Invalid Telegram bot token format' >&2; return 1; }
      printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_BOT_TOKEN" |
        curl --silent --show-error --fail --retry 2 --retry-delay 2 --connect-timeout 5 --max-time 20 \
          --config - -X POST \
          --data-urlencode "chat_id=$TG_CHAT_ID" \
          --data-urlencode "text=$subject

$body" >/dev/null
      ;;
    *) echo "Unknown TRANSPORT: $TRANSPORT" >&2; return 1;;
  esac
}

require_journal() {
  command -v journalctl >/dev/null 2>&1 || {
    echo 'journalctl is missing; kernel monitoring needs an accessible systemd journal.' >&2
    return 1
  }
}

case "$command_name" in
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
    require_journal
    latest=$(journalctl -k -n 1 --show-cursor --no-pager -o short-iso) || {
      echo 'Cannot read kernel journal; check journald availability and journal permissions.' >&2
      exit 1
    }
    cursor=$(printf '%s\n' "$latest" | sed -n 's/^-- cursor: //p' | tail -n 1)
    [[ -n "$cursor" ]] || { echo 'Cannot initialize journal cursor' >&2; exit 1; }
    printf '%s\n' "$cursor" > "$CURSOR_FILE"
    chmod 600 "$CURSOR_FILE"
    echo 'Initialized; historic kernel events excluded.'
    ;;
  scan|check)
    [[ -s "$CURSOR_FILE" ]] || { echo 'Run init first' >&2; exit 1; }
    require_journal
    exec 9>"$STATE_DIR/scan.lock"
    flock -n 9 || exit 0
    previous=$(<"$CURSOR_FILE")
    data=$(journalctl -k --after-cursor="$previous" --show-cursor --no-pager -o short-iso) || {
      echo 'Cannot read kernel journal; check journald availability, permissions or cursor validity.' >&2
      exit 1
    }
    cursor=$(printf '%s\n' "$data" | sed -n 's/^-- cursor: //p' | tail -n 1)
    [[ -n "$cursor" ]] || exit 0
    matches=$(printf '%s\n' "$data" | grep -Ei "$PATTERN" || true)
    if [[ -n "$matches" ]]; then
      count=$(printf '%s\n' "$matches" | wc -l)
      sample=$(printf '%s\n' "$matches" | tail -n 8 | cut -c1-220)
      notify "DISK I/O ALERT - $HOST_LABEL ($count events)" "New kernel disk/storage errors on $HOST_LABEL:

$sample

Inspect: journalctl -k"
      # Logging is best-effort; an already-delivered alert must not be retried.
      logger -t disk-watch "Sent alert for $count kernel events" || true
    fi
    printf '%s\n' "$cursor" > "$CURSOR_FILE.tmp"
    chmod 600 "$CURSOR_FILE.tmp"
    mv -f "$CURSOR_FILE.tmp" "$CURSOR_FILE"
    ;;
  *) echo "Unsupported command: $command_name" >&2; exit 2;;
esac
