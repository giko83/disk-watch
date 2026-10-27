#!/usr/bin/env bash
# Run as root from a local Git checkout. Existing configs and journal cursor are preserved.
set -euo pipefail

usage() {
  echo 'Usage: bash install.sh [--preflight]' >&2
}

if (($# > 1)) || { (($# == 1)) && [[ $1 != --preflight ]]; }; then
  usage
  exit 2
fi

cd "$(dirname "$0")"

# Read-only checks; safe to run as an unprivileged user before deploying.
preflight() {
  local file cmd
  for file in disk-watch.sh disk-watch-smart.sh update.sh disk-watch.service disk-watch.timer scripts/backup-installed.sh scripts/check-config.sh; do
    [[ -s "$file" ]] || { echo "Preflight failed: missing or empty $file" >&2; return 1; }
  done

  (bash -n disk-watch.sh && bash -n install.sh && bash -n update.sh && bash -n scripts/backup-installed.sh && bash -n scripts/check-config.sh) || {
    echo 'Preflight failed: invalid Bash syntax' >&2
    return 1
  }
  sh -n disk-watch-smart.sh || {
    echo 'Preflight failed: invalid SMART adapter syntax' >&2
    return 1
  }

  # Core runtime and deployment tools only. curl/sendmail/smartctl are optional
  # and depend on the selected notification and SMART integrations.
  for cmd in bash sh install systemctl journalctl flock grep sed tail cut wc mv mkdir chmod hostname cp mktemp dirname date stat sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Preflight failed: required command not found: $cmd" >&2
      return 1
    }
  done

  # This installer deploys fixed unit names and executable paths. Detect
  # accidental drift before replacing installed files, without invoking
  # systemctl or adding a systemd-analyze dependency. Not a full unit parser.
  grep -Fxq 'ExecStart=/usr/local/sbin/disk-watch.sh scan' disk-watch.service || {
    echo 'Preflight failed: disk-watch.service ExecStart does not match the installed monitor' >&2
    return 1
  }
  grep -Fxq 'Unit=disk-watch.service' disk-watch.timer || {
    echo 'Preflight failed: disk-watch.timer does not target disk-watch.service' >&2
    return 1
  }

  # A matching line alone is insufficient: systemd may honor another active
  # directive later in the file. The shipped units use exactly one of each.
  # This is deliberately a narrow guard, not a full systemd unit parser.
  [[ $(grep -Ec '^[[:space:]]*ExecStart[[:space:]]*=' disk-watch.service) == 1 ]] || {
    echo 'Preflight failed: disk-watch.service has duplicate or missing ExecStart directives' >&2
    return 1
  }
  [[ $(grep -Ec '^[[:space:]]*Unit[[:space:]]*=' disk-watch.timer) == 1 ]] || {
    echo 'Preflight failed: disk-watch.timer has duplicate or missing Unit directives' >&2
    return 1
  }

  # smartd invokes this adapter without positional arguments. Validate the
  # fixed installed target so a valid but misdirected adapter cannot silently
  # drop SMART notifications after an upgrade.
  grep -Fxq 'exec /usr/local/sbin/disk-watch.sh smart' disk-watch-smart.sh || {
    echo 'Preflight failed: disk-watch-smart.sh does not forward to the installed SMART handler' >&2
    return 1
  }
}

if [[ ${1:-} == --preflight ]]; then
  preflight
  echo 'Preflight OK: local files, syntax, core commands and unit entry points. No installation performed.'
  exit 0
fi

[[ ${EUID} -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
preflight
test -s /etc/disk-watch.conf || { echo 'Create /etc/disk-watch.conf first; see README' >&2; exit 1; }
# Root install must never source a writable/untrusted Bash config. Check metadata
# before creating a backup or replacing installed files; do not print secrets.
bash ./scripts/check-config.sh /etc/disk-watch.conf

# Create a unique, root-private snapshot before replacing ANY installed files.
# Never copy host configuration, credentials, SMART rules or the journal cursor.
# Failed snapshots abort installation; a .complete marker is written last.
BACKUP_ROOT=/var/lib/disk-watch/backups
install -d -m 700 -- "$BACKUP_ROOT"
backup_dir=$(mktemp -d "$BACKUP_ROOT/backup.$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
if ! bash ./scripts/backup-installed.sh "$backup_dir" \
  /usr/local/sbin/disk-watch.sh \
  /usr/local/sbin/disk-watch-smart.sh \
  /etc/systemd/system/disk-watch.service \
  /etc/systemd/system/disk-watch.timer; then
  echo "Backup failed; no installed files replaced. Incomplete snapshot: $backup_dir" >&2
  exit 1
fi
echo "Pre-install snapshot saved: $backup_dir"

install -m 750 disk-watch.sh disk-watch-smart.sh /usr/local/sbin/
install -m 644 disk-watch.service disk-watch.timer /etc/systemd/system/
systemctl daemon-reload
if [[ ! -s /var/lib/disk-watch/kernel.cursor ]]; then
  /usr/local/sbin/disk-watch.sh init
fi
systemctl enable --now disk-watch.timer
echo 'Installed. Check: systemctl list-timers disk-watch.timer'
echo 'SMART integration remains configured separately in /etc/smartd.conf.'
