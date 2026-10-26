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
  for file in disk-watch.sh disk-watch-smart.sh disk-watch.service disk-watch.timer; do
    [[ -s "$file" ]] || { echo "Preflight failed: missing or empty $file" >&2; return 1; }
  done

  (bash -n disk-watch.sh && bash -n install.sh) || {
    echo 'Preflight failed: invalid Bash syntax' >&2
    return 1
  }
  sh -n disk-watch-smart.sh || {
    echo 'Preflight failed: invalid SMART adapter syntax' >&2
    return 1
  }

  # Core runtime and deployment tools only. curl/sendmail/smartctl are optional
  # and depend on the selected notification and SMART integrations.
  for cmd in bash sh install systemctl journalctl flock grep sed tail cut wc mv mkdir chmod hostname; do
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
}

if [[ ${1:-} == --preflight ]]; then
  preflight
  echo 'Preflight OK: local files, syntax, core commands and unit entry points. No installation performed.'
  exit 0
fi

[[ ${EUID} -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
preflight
test -s /etc/disk-watch.conf || { echo 'Create /etc/disk-watch.conf first; see README' >&2; exit 1; }

install -m 750 disk-watch.sh disk-watch-smart.sh /usr/local/sbin/
install -m 644 disk-watch.service disk-watch.timer /etc/systemd/system/
systemctl daemon-reload
if [[ ! -s /var/lib/disk-watch/kernel.cursor ]]; then
  /usr/local/sbin/disk-watch.sh init
fi
systemctl enable --now disk-watch.timer
echo 'Installed. Check: systemctl list-timers disk-watch.timer'
echo 'SMART integration remains configured separately in /etc/smartd.conf.'
