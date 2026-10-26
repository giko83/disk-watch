# Disk Watch

A minimal Linux disk monitoring tool for Debian and Proxmox VE, with Telegram alerts.

- **Kernel storage errors** are detected from the system journal every minute.
- **SMART warnings** can be forwarded by `smartd` using the included adapter.
- **Telegram** Bot API or **local sendmail** transport (e.g. Proxmox Notifications).
- Uses a persistent journal cursor so old errors are not repeatedly announced.

**SMART/USB standby:** see [the non-waking troubleshooting guide](docs/smart-usb-standby.md) before enabling SMART polling on disks that should sleep.

**Initial public release:** based on a working homelab deployment. Not yet security-audited or broadly tested. This does not replace verified backups.

## Requirements

Linux, systemd, Bash, journalctl, grep, flock. Add curl for direct Telegram, smartmontools for SMART alerts, or working local sendmail for mail transport.

## Existing or new installation

Clone into `/opt/disk-watch`:

```sh
sudo apt-get install -y git
sudo git clone https://github.com/giko83/disk-watch.git /opt/disk-watch
```

For a **new** host, create `/etc/disk-watch.conf` (as root) based on `disk-watch.conf.example`. Set `HOST_LABEL`, `TRANSPORT`, and private Telegram credentials as appropriate; `chmod 600 /etc/disk-watch.conf`.

For an **existing** host that already has Disk Watch configured, *do not overwrite* `/etc/disk-watch.conf`. It stays in place along with `/var/lib/disk-watch/kernel.cursor`.

Install the scripts and systemd units:

```sh
sudo bash /opt/disk-watch/install.sh
sudo /usr/local/sbin/disk-watch.sh test
systemctl list-timers disk-watch.timer
```

The installer deliberately does not modify `/etc/smartd.conf`. Existing SMART hooks remain valid.

For a **manual update**, run:

```sh
sudo bash /opt/disk-watch/update.sh
```

This runs `git pull --ff-only` and redeploys the scripts. It does not overwrite your Telegram token or journal cursor. It is NOT a transactional rollback mechanism. Do not enable automatic updates until reviewed and tested.

For safe rollout, verification, and manual rollback on existing hosts, see the [operations runbook](docs/operations.md). The updater does **not** provide automatic rollback.

## SMART integration

Back up `/etc/smartd.conf`, then add the following to the appropriate monitored-device rule, keeping `-m root`:

```text
-M exec /usr/local/sbin/disk-watch-smart.sh
```

`smartd` invokes a helper **without** positional arguments; the included helper supplies `smart`.

Test a SMART notification by temporarily appending `-M test` and running `smartd -q onecheck`, then restore the original rule before restarting the service. This does not launch an extended self-test.

**USB power-saving caveat:** some USB-SATA bridges cannot report ATA power state, so `smartd` ignores `-n standby` and may wake the disk. Use explicit device rules and exclude drives that must stay asleep if necessary.

## Configuration and privacy

Keep tokens and host-specific settings in `/etc/disk-watch.conf`, owned by root with permission `600`. It is **never** part of the Git checkout. Avoid pasting Telegram tokens in issues or pull requests.

```ini
HOST_LABEL=my-server
TRANSPORT=telegram
TG_BOT_TOKEN='YOUR_SECRET'
TG_CHAT_ID='YOUR_CHAT'
```

For Proxmox using local mail forwarding to its existing Notifications webhook, use `TRANSPORT=mail` instead.

## Commands

```sh
sudo /usr/local/sbin/disk-watch.sh init
sudo /usr/local/sbin/disk-watch.sh scan
sudo /usr/local/sbin/disk-watch.sh test
systemctl list-timers disk-watch.timer
journalctl -u disk-watch.service -n 30 --no-pager
```

## Development and tests

Run the isolated smoke tests before submitting a change:

```sh
bash -n disk-watch.sh install.sh update.sh tests/test-disk-watch.sh
bash tests/test-disk-watch.sh
```

The tests use temporary directories and mock `journalctl`, `curl`, and `logger`; they do **not** access real disks, send Telegram messages, or change systemd services. GitHub Actions runs the same checks on pull requests. Current coverage includes journal cursor initialization and idempotence (re-running `init` preserves an existing cursor), preserving pending alerts after failed delivery **or missing Telegram credentials**, successful I/O alert delivery, clean scans, and SMART alert content/failure handling; it is not an end-to-end hardware test.

## Known limitations

- Journal rotation/cursor expiration may cause missed events; no continuous live daemon is used.
- Telegram HTTP success means the API accepted the request, not necessarily that a person read it.
- Mail transport can queue mail without proving delivery to Telegram.
- A reboot or disk failure can still prevent the host from reporting its own failure.
- `update.sh` does not automatically roll back a failed update.
- Disk Watch does not check actual storage SMART values without `smartd`, nor does it perform surface scans.

MIT licensed. Contributions welcome.
