# Operations runbook

This document is for maintainers deploying Disk Watch to existing Debian or Proxmox hosts. **No automatic deployment is configured.** Treat a GitHub pull request as proposed code, not a production release.

## Before the first Git-based deployment

On each host, one at a time:

1. Confirm the current `disk-watch.timer` is running and the host's notification path works.
2. Record the current deployment: `systemctl status disk-watch.timer --no-pager` and `systemctl cat disk-watch.service disk-watch.timer`.
3. Back up the installed scripts and units **before** running `install.sh`:

   ```sh
   sudo install -d -m 700 /root/disk-watch-rollback
   sudo cp -a /usr/local/sbin/disk-watch.sh /root/disk-watch-rollback/
   sudo cp -a /usr/local/sbin/disk-watch-health.sh /root/disk-watch-rollback/
   sudo cp -a /usr/local/sbin/disk-watch-smart.sh /root/disk-watch-rollback/
   sudo cp -a /etc/systemd/system/disk-watch.service /root/disk-watch-rollback/
   sudo cp -a /etc/systemd/system/disk-watch.timer /root/disk-watch-rollback/
   ```

   If a file is absent, stop and inspect the existing installation rather than assuming these commands are universal.

4. Clone the public repository to `/opt/disk-watch`, review the diff against the installed scripts, and run `bash /opt/disk-watch/install.sh --preflight` **without sudo**. This read-only check validates required files (including `update.sh`), Bash syntax of the monitor/installer/updater, core command availability, the backup helper and the three read-only recovery helpers (snapshot verifier, restore planner and rehearsal), and the packaged service/timer entry points (`ExecStart=/usr/local/sbin/disk-watch.sh scan` and `Unit=disk-watch.service`) and the SMART adapter's exact forwarding target (`exec /usr/local/sbin/disk-watch.sh smart`). It also rejects duplicate active service `ExecStart=` and timer `Unit=` directives, even when the expected line is present. It checks recovery-helper presence and Bash syntax only, **not** whether a root-level restore works. It does **not** parse arbitrary systemd units or validate running systemd, config permissions or notification delivery. If it fails, stop before replacing installed files. Then run `sudo bash /opt/disk-watch/install.sh`.
5. Check `systemctl list-timers disk-watch.timer`, `systemctl status disk-watch.timer --no-pager`, and `journalctl -u disk-watch.service -n 30 --no-pager`. Run `sudo /usr/local/sbin/disk-watch.sh test` and **verify receipt** through the configured transport.

**Root-install config guard (not part of unprivileged `--preflight`):** before snapshotting or replacing files, `install.sh` checks that `/etc/disk-watch.conf` is a regular non-symlink file owned by root (UID 0), with no group/other permission bits. This prevents executing an untrusted writable Bash config as root. Check with `sudo stat -c '%u %a %n' /etc/disk-watch.conf`; correct it manually with `sudo chown root:root /etc/disk-watch.conf` and `sudo chmod 600 /etc/disk-watch.conf` (mode `400` is also accepted). This intentionally rejects existing `640` configs until permissions are tightened; no automatic permission changes occur. The metadata checker is covered by unprivileged tests using mocked `stat`; **real root installation and rollback are still unverified**. This is a pre-deployment guard, not a transactional update or a full race-free security audit.

The installer does not change `/etc/disk-watch.conf`, `/etc/smartd.conf`, or `/var/lib/disk-watch/kernel.cursor`. Those files are host-specific; never commit them or paste secrets into GitHub issues.

## Before each manual update

- Review the commits and changes on `main`; do not update solely because a PR exists.
- Check for uncommitted changes in the checkout with `git -C /opt/disk-watch status --short`.
- Record the deployed revision with `git -C /opt/disk-watch rev-parse HEAD`.
- Preserve copies of the currently installed scripts and units (see above). The installer now also creates a private pre-install snapshot, but **`update.sh` is not transactional and does not automatically restore the previous version.**
- Update **one host at a time**, verify notifications and timer behavior, then continue to the next host.

Run `sudo bash /opt/disk-watch/update.sh` only after review. It executes `git pull --ff-only`, then a read-only `install.sh --preflight` before attempting installation. A preflight failure leaves installed scripts and units unchanged, **but the Git checkout is already updated**; it does not restore the previous commit. Installation failures after preflight can still leave partial changes despite the new pre-install snapshot, so keep backups and verify each host.

The repository also includes `bash tests/test-update.sh`, an **offline unprivileged regression test** for updater control flow. It uses a disposable copy of the updater with only its root guard disabled, plus mocked Git and installer commands. It covers missing/dirty checkouts, failed fast-forward pulls, failed preflight, failed installation and a successful command sequence. **It does not exercise actual root installation, backups, systemd or rollback**, so it is not a substitute for a host-specific recovery plan.

## Automatic pre-install snapshots (not automatic rollback)

Before replacing any installed scripts or units, `install.sh` creates a new private snapshot under `/var/lib/disk-watch/backups/backup.YYYYMMDDTHHMMSSZ.RANDOM/`. The included `scripts/backup-installed.sh` copies the **previously installed** regular files, preserving permissions, and writes `present.txt` and `absent.txt` manifests. New snapshots also contain `SHA256SUMS` with relative paths for every copied file; hashes are verified before `.complete` is written. A new installation with no previous files has an empty checksum manifest. The `.complete` marker is created **only after every copy and checksum verification succeeds**. Format-2 snapshots require the health helper to be listed as present or absent; format-1 snapshots created earlier cannot restore it. The installer preflight now requires GNU `sha256sum` (coreutils), which is already used by the optional portable archive builder. The helper also refuses a directory not owned by the invoking user, not mode `700`, or already containing any entry (including hidden files), before writing manifests. It rejects repeated source paths before writing any manifest, so a completed snapshot cannot contain duplicate present/absent records. The installer creates a fresh private directory automatically. If an installed source file or any of its parent directories is a symlink, the backup directory is unsafe, or a copy fails, installation stops before replacing installed files; do not use an incomplete snapshot for recovery. The parent-symlink check is exercised with a nested offline fixture and adds no runtime dependency beyond the existing GNU utilities. It is not race-proof against concurrent path replacement. This is a local safeguard, not a defense against a compromised root account or an unsafe parent directory.

A new format-2 snapshot contains only previous versions of these **five** paths (if present): `/usr/local/sbin/disk-watch.sh`, `/usr/local/sbin/disk-watch-health.sh`, `/usr/local/sbin/disk-watch-smart.sh`, `/etc/systemd/system/disk-watch.service`, and `/etc/systemd/system/disk-watch.timer`. `format.txt` contains `2` and distinguishes complete five-path manifests from older four-path snapshots; a missing entry in a format-2 manifest fails verification. Older four-path snapshots with valid checksums remain readable, but **do not include the health helper**, which must be recovered separately if needed. It **does not** copy `/etc/disk-watch.conf`, `/etc/smartd.conf`, credentials or journal cursor/state. New installations can have entries in `absent.txt` and no previous installed files to restore.

To inspect a snapshot as root, choose its exact directory and verify completion:

```sh
sudo find /var/lib/disk-watch/backups -maxdepth 1 -type d -name 'backup.*' -print
# Replace the placeholder with one existing directory from the listing.
SNAPSHOT=/var/lib/disk-watch/backups/backup.REPLACE_WITH_EXACT_NAME
sudo test -f "$SNAPSHOT/.complete"
sudo cat "$SNAPSHOT/present.txt"
sudo cat "$SNAPSHOT/absent.txt"
```

For snapshots created with this feature, **verify checksums before any restore**, using relative paths from the snapshot directory:

```sh
sudo sh -c 'cd "$1" || exit; if [ -s present.txt ]; then sha256sum -c SHA256SUMS; else test -f SHA256SUMS && test ! -s SHA256SUMS; fi' sh "$SNAPSHOT"
```

For a stricter read-only verification, run the included checker before restoring anything:

```sh
sudo bash /opt/disk-watch/scripts/verify-installed-snapshot.sh "$SNAPSHOT"
```

It checks that the snapshot is private and owned by the invoking user, the completion marker and both manifests are consistent with the five fixed installed paths (four for checksum-bearing legacy snapshots), the copied files and parent directories are not symlinks, and every checksum matches without extra entries. It also rejects unlisted non-directory entries (including hidden files, symlinks and special files) anywhere in the snapshot; empty extra directories are not restore candidates. The verifier requires standard GNU `find` in addition to the previously documented tools. A zero exit **does not perform a restore**, and an empty snapshot has nothing to restore. It requires Bash and standard Linux utilities including GNU `stat` and `sha256sum`; it does not contact disks, Git, systemd or the network. This is offline validation, **not** a transactional rollback or a root-level restore test.

A nonzero exit means **stop and investigate**; do not restore damaged files. Older snapshots created before checksum support have no `SHA256SUMS` and cannot pass this verification; inspect their contents and origin separately rather than treating a missing manifest as valid. SHA-256 protects against accidental corruption, **not** against an attacker able to rewrite both backup files and checksums. This check does not provide automatic rollback or prove real root-level recovery.


### Read-only recovery plan (no restore)

After selecting a completed snapshot, generate an explicit recovery checklist **before** touching any installed file:

```sh
SNAPSHOT=/var/lib/disk-watch/backups/backup.REPLACE_WITH_EXACT_NAME
sudo bash /opt/disk-watch/scripts/plan-installed-restore.sh "$SNAPSHOT"
```

The planner first runs the strict snapshot verifier and **fails without emitting a plan** if the snapshot is incomplete, tampered, legacy or unsafe. It then lists exactly five allowlisted installed paths: `RESTORE` means a previous file is available (with its saved file mode); `REVIEW ABSENT` means the file did not exist when the snapshot was taken; `NOT CAPTURED` warns that a legacy four-path snapshot has no saved `disk-watch-health.sh`. Never treat `NOT CAPTURED` as evidence that the file was absent. **Do not automatically delete an absent entry**: investigate whether it was created by this installation and whether another service uses it. A snapshot path containing spaces is supported.

The planner is intentionally read-only: it does not copy, remove, `chmod`, run `systemctl`, change config/cursors, or roll back Git. It needs Bash and standard GNU Linux tools (`stat`, `sha256sum`, `grep`), not smartctl or network access. Its offline tests verify valid, empty, tampered and quoted-path snapshots. This is a checklist, **not** proof of root-level recovery or a transactional updater.

### Offline restore rehearsal (sandbox only)

Before attempting manual recovery, you can rehearse file copying into a **new empty private directory**. This detects a broken or unreadable backup without writing to installed paths:

```sh
SNAPSHOT=/var/lib/disk-watch/backups/backup.REPLACE_WITH_EXACT_NAME
SANDBOX=$(sudo mktemp -d /tmp/disk-watch-rehearsal.XXXXXXXX)
sudo bash /opt/disk-watch/scripts/rehearse-installed-restore.sh "$SNAPSHOT" "$SANDBOX"
sudo find "$SANDBOX" -type f -print
# After reviewing copied files, remove this disposable sandbox manually.
```

The rehearsal verifies the snapshot first, requires a pre-existing empty mode `700` sandbox owned by the invoking user, and copies only allowlisted saved files into sandbox-prefixed paths while checking contents and modes. It never touches live installed paths, removes absent files, invokes systemd, changes Git, or changes private configuration/state. An invalid snapshot or unsafe sandbox fails before any copy. A sandbox inside the snapshot directory is rejected, including when reached through a symlinked parent, to prevent writing into the backup itself. If a copy or post-copy check fails, the helper attempts to remove its own partial files and empty directories from the sandbox; cleanup is best-effort, so inspect the sandbox before reuse. The sandbox can contain historical executable code; do not execute it. This is an **offline regression-tested rehearsal**, not a verified root-level restore or transactional rollback. Root-level systemd and failure recovery remain untested.

For manual recovery, restore **only paths listed in `present.txt`** from the matching paths inside that completed snapshot, using the same-host rollback procedure below. For example, if the monitor script is listed:

```sh
sudo install -m 750 "$SNAPSHOT/usr/local/sbin/disk-watch.sh" /usr/local/sbin/disk-watch.sh
```

Likewise restore the health helper, SMART adapter and unit files when present, then `systemctl daemon-reload`, restart the timer and verify notifications. Do not blindly delete paths listed in `absent.txt`; determine whether they were newly installed and whether other services depend on them. **A snapshot is not a tested transactional rollback** and does not restore the Git checkout or reverse systemd side effects. The backup helper is covered by isolated offline tests, but real root-level restoration is not yet verified.

Snapshots are never automatically pruned. Review and remove old backups manually only after confirming a stable installation and keeping an appropriate recovery point; do not include private config or secrets in GitHub reports.

## Manual rollback of deployed files

If an update fails, first stop further deployments. Restore the backed-up binaries and units from the *same host*:

```sh
sudo install -m 750 /root/disk-watch-rollback/disk-watch.sh /usr/local/sbin/disk-watch.sh
sudo install -m 750 /root/disk-watch-rollback/disk-watch-health.sh /usr/local/sbin/disk-watch-health.sh
sudo install -m 750 /root/disk-watch-rollback/disk-watch-smart.sh /usr/local/sbin/disk-watch-smart.sh
sudo install -m 644 /root/disk-watch-rollback/disk-watch.service /etc/systemd/system/disk-watch.service
sudo install -m 644 /root/disk-watch-rollback/disk-watch.timer /etc/systemd/system/disk-watch.timer
sudo systemctl daemon-reload
sudo systemctl restart disk-watch.timer
```

Then check the timer and perform a notification test. **Do not delete or reset the journal cursor to roll back code.** A rollback of installed files does *not* roll back the Git checkout: record the prior revision and review the checkout before the next update, or the newer code may be installed again.

These steps restore only the listed files. If an update introduced other resources, investigate those changes separately before declaring rollback complete.

## SMART and USB standby

`smartd` configuration is deliberately outside the installer. After changes, verify its monitored device list in `journalctl -u smartmontools -n 50 --no-pager`. USB-SATA bridges without ATA CHECK POWER STATUS support may **ignore** `-n standby` and wake sleeping disks; explicitly exclude such devices from periodic SMART polling when standby is required.

## When to investigate

- Timer inactive or failing: `systemctl status disk-watch.timer disk-watch.service --no-pager`.
- Journal read or notification errors: `journalctl -u disk-watch.service -n 100 --no-pager`.
- SMART warnings: `journalctl -u smartmontools -n 100 --no-pager`.
- Telegram not received: inspect service exit status and verify the configured bot/chat outside GitHub; HTTP acceptance is not proof of delivery to a person.
- Kernel journal rotation or missing cursor: investigate before reinitializing, since reinitialization can skip older errors.

Disk Watch is an alerting aid, not a substitute for verified backups or redundant monitoring.
