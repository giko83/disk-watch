# Disk Watch

A minimal Linux disk monitoring tool for Debian and Proxmox VE, with Telegram alerts.

- **Kernel storage errors** are detected from the system journal every minute.
- **SMART warnings** can be forwarded by `smartd` using the included adapter.
- **Telegram** Bot API or **local sendmail** transport (e.g. Proxmox Notifications).
- Uses a persistent journal cursor so old errors are not repeatedly announced.

**SMART/USB standby:** see [the non-waking troubleshooting guide](docs/smart-usb-standby.md) before enabling SMART polling on disks that should sleep.

**Initial public release:** based on a working homelab deployment. Not yet security-audited or broadly tested. This does not replace verified backups.

**Offline CI compatibility:** GitHub Actions checks Bash syntax and the nine mocked regression suites on Ubuntu 22.04/24.04 and Debian 12/13. Debian tests run as an unprivileged user in a read-only container with networking disabled and no disk devices mounted; the runner pulls the image before isolation. This is not proof of live Proxmox, SMART hardware, journald permissions or root installer/rollback compatibility. Run the same suites locally with `for test_script in tests/test-*.sh; do bash "$test_script"; done`. No runtime dependencies change.

## Requirements

Linux with Bash, a readable systemd kernel journal (`journalctl`), `grep`, `flock` and standard utilities. The **root installer** additionally requires GNU `stat` (coreutils) to check configuration metadata; standalone one-shot monitoring does not. **systemd timer installation is optional** for one-shot portable checks; `journalctl` is still required for the kernel-monitoring backend. Add curl for direct Telegram, smartmontools for SMART alerts, or working local sendmail for mail transport.

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
(cd dist && sha256sum -c disk-watch-portable.tar.gz.sha256)
tar -xzf dist/disk-watch-portable.tar.gz
cd disk-watch-portable
bash ./disk-watch.sh --help
```

The archive builder needs Bash and standard Linux build utilities (GNU `tar`, `gzip`, `cp`, `mktemp`, `chmod`, `sha256sum`); no root, Git at build time, Python, database, network or systemd timer. Identical source files now produce a byte-identical archive across repeated builds and caller umasks: archive timestamps and ownership are normalized, documentation is non-executable and only `disk-watch.sh` is executable. This is a reproducible local source bundle, **not** a published or signed release. It writes a companion `.sha256` file to check for accidental archive corruption (not a signature or proof of authenticity). The archive includes only an explicit list of public files, **not** your real configuration, secrets, cursor or local state. Keep a trusted configuration outside the extracted directory and use `--config` / `--state-dir` as shown above. Kernel checks still require a readable `journalctl`; the archive is not a prebuilt binary or a GitHub release. See [portable usage](docs/portable.md). The builder refuses symbolic links for any allowlisted input and for the `docs/` directory, to avoid copying private files from outside the checkout into a public archive. Use regular files from a trusted source tree; no runtime prerequisites change. It also rejects pre-existing symbolic links, non-regular output targets (such as FIFOs), and existing output files hardlinked to an allowlisted source or the builder itself, at either the archive or `.sha256` path. This prevents blocking on a FIFO or accidentally truncating a packaged source file; ordinary existing archive files can still be rebuilt. Build into a directory you control; the check is not atomic protection against a concurrent attacker replacing paths. The builder stages the archive and checksum beside the destination, so a failed compression or checksum generation leaves existing artifacts intact and removes temporary staging files. Before publication it also rejects an empty checksum sidecar (even if `sha256sum` exits successfully) and verifies the staged digest against the staged archive; a failure preserves the previous pair. Publication uses two separate renames, **not an atomic archive/checksum pair**: do not read or distribute artifacts during a concurrent rebuild. GNU `mv` is a build-only utility; runtime requirements are unchanged.

## Cached disk health reports (opt-in SMART collection)

The CLI now supports `status`, `disks`, `health`, `history --device ID`, and `report --since YYYY-MM-DD`. **Reading saved results never runs smartctl or wakes disks.** A live reading is explicitly opt-in, may wake a sleeping disk, and requires `smartmontools`:

```sh
sudo /usr/local/sbin/disk-watch.sh status
sudo /usr/local/sbin/disk-watch.sh disks
sudo /usr/local/sbin/disk-watch.sh health --device /dev/nvme0 --refresh --wake-ok
sudo /usr/local/sbin/disk-watch.sh history --device SERIAL --format tsv
```

Data is saved in `/var/lib/disk-watch/health/snapshots.tsv` only after a deliberate refresh, not as part of the one-minute monitoring timer. **Never use --refresh on intentionally sleeping USB backup drives unless you want to wake them.** The initial cache may be empty and report `unavailable`. A mocked SCSI/USB SMART report using `Serial number:` (lowercase "number") preserves its serial as the cached disk ID. If no serial is exposed, a valid 16-hex-digit `LU WWN Device Id:` or `WWN Device Id:` from the same explicitly requested SMART report is used as `wwn:<lowercase-hex>`; otherwise the cache falls back to the supplied device path. Serial IDs retain precedence for compatibility. This is text parsing, not automatic by-id discovery, USB bridge capability detection, or a guarantee that a device can be queried without waking. Live refresh refuses symlinks in any existing state-directory ancestor (as well as the state/health directories), snapshot or lock symlinks, and non-directory ancestors/non-regular targets before probing a disk; use trusted state paths (this is not race-proof). An existing nonempty snapshot history must retain the exact 13-column TSV header and newline-terminated data rows with 13 fields and nonempty timestamp/device/ID. Refresh rejects incompatible headers, malformed rows or an unterminated last row **before** running SMART, rather than mixing records or waking a disk unnecessarily. Validation repeats under the append lock and scans the existing history; it does not repair or migrate data, validate metric semantics, or change cached read commands. Offline regression: `bash tests/test-health.sh` (Bash, awk and GNU coreutils; no root, hardware or network required). See [the health command guide](docs/health.md) for limitations, NVMe write estimates, permissions and the machine-readable TSV format.

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

It checks required source/unit files (including the updater), Bash syntax for the monitor, installer and updater, core command availability, the backup and read-only recovery helpers (snapshot verifier, restore planner and sandbox rehearsal), and the packaged service/timer entry points (`ExecStart` and `Unit`) plus the SMART adapter's installed `smart` handler target, without installing or contacting any disk. These checks also reject duplicate active `ExecStart=` or timer `Unit=` directives that could override the expected entries. They are exact checks for the shipped unit files, **not** full systemd unit validation. Recovery-helper checks confirm only file presence and Bash syntax, not successful root-level restoration. It does **not** validate the live notification transport, systemd runtime, or permissions; keep the backup and post-install checks described in the [operations runbook](docs/operations.md).

**Root-install configuration guard:** the actual installer (not the read-only `--preflight`) now refuses `/etc/disk-watch.conf` if it is a symlink, not a regular file, not owned by UID 0, or accessible to group/other users. Before updating, check `sudo stat -c '%u %a %n' /etc/disk-watch.conf`; if needed, correct ownership and permissions with `sudo chown root:root /etc/disk-watch.conf` and `sudo chmod 600 /etc/disk-watch.conf`. A root-owned mode `400` also passes. This guard does not read or display secrets, does not change the config, and runs **before** snapshots or file replacement. Existing installations using group-readable mode `640` must be tightened manually before an update; there is no automatic chmod. See [operations](docs/operations.md).

Install the scripts and systemd units:

```sh
sudo bash /opt/disk-watch/install.sh
sudo /usr/local/sbin/disk-watch.sh test
systemctl list-timers disk-watch.timer
```

The installer deliberately does not modify `/etc/smartd.conf`. Existing SMART hooks remain valid.

**New: pre-install snapshots.** Before replacing installed scripts or systemd units, `install.sh` saves any existing versions in a unique, root-private `/var/lib/disk-watch/backups/backup.TIMESTAMP.RANDOM/` directory. It records `format.txt` (schema `2`), `present.txt`, `absent.txt`, and a final `.complete` marker; a failed backup stops deployment before any installed file is replaced. The backup helper also rejects duplicate source paths before writing manifests, preventing a completed but unverifiable snapshot. It refuses symlinked installed source files **and symlinked parent directories** before copying, to avoid snapshotting a file reached through an unexpected path alias. This is a best-effort preflight guard, not protection against concurrent path replacement. The five covered installed paths now include `disk-watch-health.sh` alongside the monitor, SMART adapter and two systemd units. The snapshot excludes `/etc/disk-watch.conf`, SMART rules, Telegram secrets, and the journal cursor. The snapshots are **not automatic rollback**: restoration remains a deliberate manual operation (see [operations runbook](docs/operations.md)). The backup helper now refuses snapshot directories that are not owned by the invoking user, are not mode `700`, or already contain files (including hidden files). The installer creates a fresh private directory automatically; do not prepopulate or reuse one. Backups accumulate until an administrator reviews and removes older copies; no automatic pruning is performed. Newly created snapshots also include a relative-path `SHA256SUMS` manifest, checked before the `.complete` marker is written; this requires `sha256sum` (GNU coreutils) at installation time. Before manual recovery, run the read-only snapshot verifier (`sudo bash /opt/disk-watch/scripts/verify-installed-snapshot.sh "$SNAPSHOT"`) as described in the [operations runbook](docs/operations.md). It rejects incomplete, damaged or unsafe snapshots, including unlisted files and symlinks (even hidden entries); older checksum-bearing four-path snapshots are still readable but explicitly warn that the health helper was never captured, while older snapshots without checksums remain unsupported; it does not restore files or change services. Existing older snapshots may not have checksums. Checksums detect corruption, not malicious changes by an attacker able to edit the backup and its manifest. For a **read-only recovery checklist**, run `sudo bash /opt/disk-watch/scripts/plan-installed-restore.sh "$SNAPSHOT"` after choosing the snapshot. It verifies integrity first, then lists the five known installed paths as `RESTORE` or `REVIEW ABSENT` (or `NOT CAPTURED` for the health helper in old four-path snapshots); it never copies, deletes, restarts services, or changes host state. Review the output and follow the manual procedure in the runbook. It is not an automatic or tested root-level rollback. To rehearse copying verified saved files **without touching installed paths**, create a new empty private directory and run `sudo bash /opt/disk-watch/scripts/rehearse-installed-restore.sh "$SNAPSHOT" "$SANDBOX"` (where `SANDBOX` is an absolute, root-owned mode `700` directory you created with `sudo mktemp -d`). The helper re-verifies integrity, copies only saved allowlisted files under the sandbox prefix and checks contents and modes. It rejects a sandbox nested inside the source snapshot, even through a symlinked parent path, so rehearsal cannot write into its own backup. It never deletes absent paths or calls systemd; it is **not** proof of a real root-level rollback. On a failed copy or content/mode check, it attempts to remove only its own partial sandbox copies and empty directories; inspect the sandbox before reuse because cleanup is best-effort. See the runbook for cleanup and limitations.


For a **manual update**, run:

```sh
sudo bash /opt/disk-watch/update.sh
```

This runs `git pull --ff-only`, checks the downloaded checkout with `install.sh --preflight`, then redeploys the scripts only if preflight succeeds. If preflight fails, installed files are not replaced, **but the Git checkout has already advanced**. It does not overwrite your Telegram token or journal cursor. It creates a pre-install snapshot before replacing files, but is NOT a transactional rollback mechanism: failures after the snapshot may still leave partial changes. Do not enable automatic updates until reviewed and tested.

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
for script in disk-watch.sh install.sh update.sh scripts/build-portable.sh scripts/backup-installed.sh scripts/verify-installed-snapshot.sh scripts/rehearse-installed-restore.sh tests/*.sh; do bash -n "$script"; done
sh -n disk-watch-smart.sh
bash tests/test-disk-watch.sh
bash tests/test-mail-transport.sh
bash tests/test-portable.sh
bash tests/test-portable-package.sh
bash tests/test-install-preflight.sh
bash tests/test-update.sh
bash tests/test-health.sh
bash tests/test-backup.sh
bash tests/test-verify-snapshot.sh
```

The tests use temporary directories and mock `journalctl`, `curl`, `sendmail`, and `logger`; they do **not** access real disks, send Telegram messages, send real email, or change systemd services. The mail-transport tests cover the notification test command, I/O alert retry after a failed `sendmail`, and SMART alert formatting. Portable tests cover quoted paths, CLI precedence, one-shot checks and failed journal reads. The archive test builds the portable package, verifies its SHA-256 sidecar and rejection of tampering, checks its exact allowlist and executes an offline init/check from the extracted tree. Installer preflight tests run without root and verify missing-file/syntax diagnostics without calling systemctl. GitHub Actions runs the same checks on pull requests. Current coverage includes journal cursor initialization and idempotence (re-running `init` preserves an existing cursor), preserving pending alerts after failed delivery **or missing/invalid Telegram credentials**, successful I/O alert delivery, clean scans, non-fatal local logger failure after successful delivery, and SMART alert content/failure handling; it is not an end-to-end hardware test.

## Offline compatibility checks

GitHub Actions runs the Bash syntax checks and all eight mocked offline test suites on **Ubuntu 22.04 and Ubuntu 24.04** (two pinned LTS runner images, rather than the moving `ubuntu-latest`). Both jobs must pass before a PR is considered verified. The jobs run unprivileged, use no real SMART devices, host journal, systemd service, or credentials, and print the Bash/GNU tar/gzip/coreutils versions used. To repeat the same tests locally without touching disks or services:

```sh
for script in disk-watch.sh install.sh update.sh scripts/*.sh tests/*.sh; do bash -n "$script"; done
sh -n disk-watch-smart.sh
for test_script in tests/test-*.sh; do bash "$test_script"; done
```

These are **Ubuntu runner compatibility checks**, not proof of Debian, Proxmox, real hardware, root installation, or a non-journald backend. No runtime prerequisites or production configurations change. See [portable compatibility notes](docs/portable.md) and [issue #33](https://github.com/giko83/disk-watch/issues/33).

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
