# SMART monitoring without waking sleeping USB disks

Disk Watch reads the **kernel journal** for I/O errors. That journal scan does not query SMART or spin up a monitored data disk by itself. SMART checks are a separate feature provided by `smartd`, which can wake sleeping disks on some USB-SATA bridges.

## Why `-n standby` is not always enough

The `-n standby` option tells `smartd` to skip a check when it can determine that a drive is in standby. Some USB-SATA bridges do **not** support ATA CHECK POWER STATUS, so `smartd` cannot make that determination and may ignore the directive.

A characteristic journal entry is:

```text
Device: /dev/sdX [SAT], no ATA CHECK POWER STATUS support, ignoring -n Directive
```

**If this appears, do not assume that periodic SMART polling will preserve standby.**

## Diagnose without querying the sleeping drive

These commands inspect configuration, device symlinks, or existing logs; they do not issue SMART commands to the sleeping disk:

```sh
sudo journalctl -u smartmontools -b --no-pager | grep -Ei 'CHECK POWER|standby|ignoring -n|monitoring|opened'
sudo grep -Ev '^([[:space:]]*#|[[:space:]]*$)' /etc/smartd.conf
ls -l /dev/disk/by-id/
```

Do **not** run `smartctl -a`, `smartctl -x`, or `smartd -q onecheck` merely to verify that a drive remains asleep: these operations may wake it. A reported standby state from an unreliable USB bridge is not proof that the platters are stopped.

## Configure only disks that should be polled

When a bridge cannot reliably report the drive's power mode, the conservative solution is to **exclude that disk from periodic SMART checks**, while retaining kernel I/O error monitoring through Disk Watch.

1. Identify the drives that *should* receive SMART polling by their persistent `/dev/disk/by-id/` symlinks.
2. Back up `/etc/smartd.conf`.
3. Replace `DEVICESCAN` with explicit entries for only those drives.
4. Restart `smartmontools` and confirm the monitored-device count and names in the daemon logs.

Illustrative configuration (replace the identifier with a real one; confirm that `-d sat` is appropriate for your device):

```text
/dev/disk/by-id/ata-EXAMPLE_DRIVE_SERIAL -d sat -a -n standby -m root -M exec /usr/local/sbin/disk-watch-smart.sh
```

The `-n standby` option still depends on power-status support **for each included drive**. If an included drive reports `ignoring -n Directive`, it may still be awakened by polling.

After restarting, read the **new** log entries:

```sh
sudo systemctl restart smartmontools
sudo journalctl -u smartmontools -n 50 --no-pager
```

Look for the list of devices and `Monitoring N ATA/SATA ... devices`. Historical lines from the previous daemon instance may still mention excluded drives; compare timestamps or the new `smartd` process ID.

## What protection remains?

- Disk Watch still scans the kernel journal for I/O and storage errors **when they occur**.
- Excluded drives no longer receive automatic SMART checks from `smartd`, so **SMART-only warnings, attribute changes, and temperature alerts are no longer available for those drives**.
- Other services, mounts, backups, or filesystem access can still wake a sleeping disk. Exclusion from `smartd` is not a guarantee of permanent standby.
- A failing disk should not be kept in service solely to preserve standby. Keep verified backups and plan replacement.

This procedure intentionally avoids a disk-specific sleep timer: USB enclosure firmware, mount behavior, and power management differ between systems.
