#!/usr/bin/env bash
# Run as root from a local Git checkout. Existing configs and journal cursor are preserved.
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
cd "$(dirname "$0")"
bash -n disk-watch.sh
bash -n install.sh
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
