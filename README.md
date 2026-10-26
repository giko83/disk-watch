# Disk Watch

A minimal Linux disk monitoring tool for Debian and Proxmox VE, with Telegram alerts.

- **Kernel storage errors** are detected from the system journal every minute.
- **SMART warnings** can be forwarded by `smartd` using the included adapter.
- **Telegram** Bot API or **local sendmail** transport (e.g. Proxmox Notifications).
- Uses a persistent journal cursor so old errors are not repeatedly announced.

**SMART/USB standby:** see [the non-waking troubleshooting guide](docs/smart-usb-standby.md) before enabling SMART polling on disks that should sleep.

**Initial public release:** based on a working homelab deployment. Not yet security-audited or broadly tested. This does not replace verified backups.

## Requirements

Linux with Bash, a readable systemd kernel journal (`journalctl`), `grep`, `flock` and standard utilities. **systemd timer installation is optional** for one-shot portable checks; `journalctl` is still required for the kernel-monitoring backend. Add curl for direct Telegram, smartmontools for SMART alerts, or working local sendmail for mail transport.

## Portable one-shot use (no installation)

You can run `disk-watch.sh` directly from a source checkout or extracted tree, without root **when your user can read the kernel journal**, and without installing a systemd timer. Configure a private Bash config outside Git and a writable local state directory:

```sh
bash ./disk-watch.sh --config "$HOME/.config/disk-watch/config" --state-dir "$HOME/.local/state/disk-watch" init
bash ./disk-watch.sh --config "$HOME/.config/disk-watch/config" --state-dir "$HOME/.local/state/disk-watch" check
```

`check` is a one-shot alias of `scan`. Both use the existing journal cursor and alert transport. The notification-only `test` and `smart` commands do not create a state directory or require access to a writable cursor location. `--help` works without a config file. The options `--config` and `--state-dir` can also be provided as `DISK_WATCH_CONFIG` and `DISK_WATCH_STATE_DIR` environment variables. **Portable mode currently still needs journald**; it does not run SMART self-tests or install a scheduler. See the [portable mode guide](docs/portable.md) for config examples, cron scheduling, permissions and limitations.

## Build a no-install portable archive

For an offline, self-contained **source archive** containing the one-shot CLI, example configuration, license and documentation, run from a checkout:

```sh
bash scripts/build-portable.sh
tar -xzf dist/disk-watch-portable.tar.gz
cd disk-watch-portable
bash ./disk-watch.sh --help
```

The archive builder needs only Bash and standard utilities (`tar`, `cp`, `mktemp`); no root, Git at build time, Python, database, network or systemd timer. The archive includes only an explicit list of public files, **not** your real configuration, secrets, cursor or local state. Keep a trusted configuration outside the extracted directory and use `--config` / `--state-dir` as shown above. Kernel checks still require a readable `journalctl`; the archive is not a prebuilt binary or a GitHub release. See [portable usage](docs/portable.md).

## Existing or new installation

Clone into `/opt/disk-watch`:

```sh
sudo apt-get install -y git
sudo git clone https://github.com/giko83/disk-watch.git /opt/disk-watch
```

For a **new** host, create `/etc/disk-watch.conf` (as root) based on `disk-watch.conf.example`. Set `HOST_LABEL`, `TRANSPORT`, and private Telegram credentials as appropriate; `chmod 600 /etc/disk-watch.conf`.

For an **existing** host that already has Disk Watch configured, *do not overwrite* `/etc/disk-watch.conf`. It stays in place along with `/var/lib/disk-watch/kernel.cursor`.

Before installing, run the **read-only preflight** from the checkout (no root or host config required):

```sh
bash /opt/disk-watch/install.sh --preflight
```

It checks required source/unit files, shell syntax and core command availability without installing or contacting any disk. It does **not** validate the live notification transport, systemd runtime, or permissions; keep the backup and post-install checks described in the [operations runbook](docs/operations.md).

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

This runs `git pull --ff-only`, checks the downloaded checkout with `install.sh --preflight`, then redeploys the scripts only if preflight succeeds. If preflight fails, installed files are not replaced, **but the Git checkout has already advanced**. It does not overwrite your Telegram token or journal cursor. It is NOT a transactional rollback mechanism. Do not enable automatic updates until reviewed and tested.

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

Keep tokens and host-specific settings in `/etc/disk-watch.conf`, owned by root with permission `600`. It is **never** part of the Git checkout. Avoid pasting Telegram tokens in issues or pull requests. The Telegram transport validates the bot token format and passes its URL to `curl` through standard input rather than a process command-line argument, reducing accidental exposure in process listings. Root-level process inspection and the configuration file still require normal host security controls.

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
bash -n disk-watch.sh install.sh update.sh scripts/build-portable.sh tests/test-disk-watch.sh tests/test-mail-transport.sh tests/test-portable.sh tests/test-portable-package.sh tests/test-install-preflight.sh
bash tests/test-disk-watch.sh
bash tests/test-mail-transport.sh
bash tests/test-portable.sh
bash tests/test-portable-package.sh
bash tests/test-install-preflight.sh
```

The tests use temporary directories and mock `journalctl`, `curl`, `sendmail`, and `logger`; they do **not** access real disks, send Telegram messages, send real email, or change systemd services. The mail-transport tests cover the notification test command, I/O alert retry after a failed `sendmail`, and SMART alert formatting. Portable tests cover quoted paths, CLI precedence, one-shot checks and failed journal reads. The archive test builds the portable package, checks its exact allowlist and executes an offline init/check from the extracted tree. Installer preflight tests run without root and verify missing-file/syntax diagnostics without calling systemctl. GitHub Actions runs the same checks on pull requests. Current coverage includes journal cursor initialization and idempotence (re-running `init` preserves an existing cursor), preserving pending alerts after failed delivery **or missing/invalid Telegram credentials**, successful I/O alert delivery, clean scans, non-fatal local logger failure after successful delivery, and SMART alert content/failure handling; it is not an end-to-end hardware test.

## Roadmap and contributing

Development priorities are tracked as [GitHub issues](https://github.com/giko83/disk-watch/issues). See the [issue-linked roadmap](docs/ROADMAP.md) for **16 proposed features**, their implementation order, acceptance criteria, and the project's minimal-dependency design principles.

Highlights (planned, **not implemented yet**): on-demand and scheduled SMART short/long self-tests; history of results and device health; disk writes and wear statistics where firmware exposes them; disk-safe standby policies; and further portable release distribution and non-journald compatibility (no-install CLI and local archive builder are available). See each issue for constraints and non-destructive testing requirements.

Contributions should include offline tests and update the relevant README, examples and docs in the same change. Avoid overlapping PRs and never commit private Telegram credentials or host configuration. A GitHub merge does **not** deploy new code to production servers automatically.

## Known limitations

- Journal rotation/cursor expiration may cause missed events; no continuous live daemon is used.
- Telegram HTTP success means the API accepted the request, not necessarily that a person read it.
- Mail transport can queue mail without proving delivery to Telegram.
- A reboot or disk failure can still prevent the host from reporting its own failure.
- `update.sh` does not automatically roll back a failed update.
- Disk Watch does not check actual storage SMART values without `smartd`, nor does it perform surface scans.

MIT licensed. Contributions welcome.
