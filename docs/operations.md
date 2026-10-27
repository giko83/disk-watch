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
   sudo cp -a /usr/local/sbin/disk-watch-smart.sh /root/disk-watch-rollback/
   sudo cp -a /etc/systemd/system/disk-watch.service /root/disk-watch-rollback/
   sudo cp -a /etc/systemd/system/disk-watch.timer /root/disk-watch-rollback/
   ```

   If a file is absent, stop and inspect the existing installation rather than assuming these commands are universal.

4. Clone the public repository to `/opt/disk-watch`, review the diff against the installed scripts, and run `bash /opt/disk-watch/install.sh --preflight` **without sudo**. This read-only check validates required files (including `update.sh`), Bash syntax of the monitor/installer/updater, core command availability and the packaged service/timer entry points (`ExecStart=/usr/local/sbin/disk-watch.sh scan` and `Unit=disk-watch.service`) and the SMART adapter's exact forwarding target (`exec /usr/local/sbin/disk-watch.sh smart`). It also rejects duplicate active service `ExecStart=` and timer `Unit=` directives, even when the expected line is present. It does **not** parse arbitrary systemd units or validate running systemd, config permissions or notification delivery. If it fails, stop before replacing installed files. Then run `sudo bash /opt/disk-watch/install.sh`.
5. Check `systemctl list-timers disk-watch.timer`, `systemctl status disk-watch.timer --no-pager`, and `journalctl -u disk-watch.service -n 30 --no-pager`. Run `sudo /usr/local/sbin/disk-watch.sh test` and **verify receipt** through the configured transport.

The installer does not change `/etc/disk-watch.conf`, `/etc/smartd.conf`, or `/var/lib/disk-watch/kernel.cursor`. Those files are host-specific; never commit them or paste secrets into GitHub issues.

## Before each manual update

- Review the commits and changes on `main`; do not update solely because a PR exists.
- Check for uncommitted changes in the checkout with `git -C /opt/disk-watch status --short`.
- Record the deployed revision with `git -C /opt/disk-watch rev-parse HEAD`.
- Preserve copies of the currently installed scripts and units (see above). **The current `update.sh` is not transactional and does not automatically restore the previous version.**
- Update **one host at a time**, verify notifications and timer behavior, then continue to the next host.

Run `sudo bash /opt/disk-watch/update.sh` only after review. It executes `git pull --ff-only`, then a read-only `install.sh --preflight` before attempting installation. A preflight failure leaves installed scripts and units unchanged, **but the Git checkout is already updated**; it does not restore the previous commit. Installation failures after preflight can still leave partial changes, so keep backups and verify each host.

The repository also includes `bash tests/test-update.sh`, an **offline unprivileged regression test** for updater control flow. It uses a disposable copy of the updater with only its root guard disabled, plus mocked Git and installer commands. It covers missing/dirty checkouts, failed fast-forward pulls, failed preflight, failed installation and a successful command sequence. **It does not exercise actual root installation, backups, systemd or rollback**, so it is not a substitute for a host-specific recovery plan.

## Manual rollback of deployed files

If an update fails, first stop further deployments. Restore the backed-up binaries and units from the *same host*:

```sh
sudo install -m 750 /root/disk-watch-rollback/disk-watch.sh /usr/local/sbin/disk-watch.sh
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
