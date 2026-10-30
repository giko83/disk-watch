# Cached disk health and inventory

Disk Watch now has **read-only, non-waking** health reports. No database, Python, web UI, daemon, or mandatory `smartctl` is needed to *read saved data*.

## Commands

After installation:

```sh
sudo /usr/local/sbin/disk-watch.sh status
sudo /usr/local/sbin/disk-watch.sh disks
sudo /usr/local/sbin/disk-watch.sh health
sudo /usr/local/sbin/disk-watch.sh history --device MY-DISK-SERIAL
sudo /usr/local/sbin/disk-watch.sh report --since 2026-10-01
sudo /usr/local/sbin/disk-watch.sh disks --format tsv
```

The `health` command without refresh is simply the last saved SMART snapshot per disk, **not a live scan**. You can limit it with `health --device SERIAL` (or the saved device path) without probing the drive. On a new installation it honestly reports `SMART history: unavailable` until at least one opt-in snapshot exists. `status --format tsv` exports key/value rows; the other TSV commands export a 13-column snapshot schema. For offline tests or portable mode, provide `--state-dir DIR` *after* the subcommand, or use `DISK_WATCH_STATE_DIR`.

## Explicitly collect a SMART health snapshot

**SMART access may wake a sleeping disk, and some USB-SATA adapters cannot report standby reliably.** Only run the following for a disk you intentionally want to query:

```sh
sudo /usr/local/sbin/disk-watch.sh health --device /dev/nvme0 --refresh --wake-ok
```

Replace `/dev/nvme0` with the exact device you have identified. Prefer a persistent `/dev/disk/by-id/...` path for SATA drives when available. The command runs `smartctl -a` once, then appends a limited, parsed snapshot to `/var/lib/disk-watch/health/snapshots.tsv`. It does **not** initiate short/long self-tests, perform writes to the device, configure schedules or change `smartd`.

`--refresh` and `--wake-ok` are both required. Do **not** run against USB backup disks deliberately configured to remain asleep (such as a Restic backup disk) unless you intentionally accept a spin-up. **Default reports never query hardware**, even if a `--device` filter is present.

## Existing history format guard

Before any explicit SMART probe, refresh rejects snapshot and lock targets that are symlinks (including dangling symlinks), non-regular files or regular files with multiple hard links. This prevents writing to another path sharing the same inode (for example a hardlinked unrelated file). The check runs again before append and under the lock; it is **best-effort, not race-proof**. Use a private, trusted state directory. A hardlinked existing history or lock must be investigated and separated manually; no automatic migration is performed. This check requires GNU `stat` (coreutils) **only for opt-in refresh**, not for cached `status`/`health`/`history` reads. Offline regression: `bash tests/test-health.sh` (no real SMART devices).

An explicit `health --refresh --wake-ok` refuses to append if the existing nonempty `health/snapshots.tsv` has a different header from the current 13-column schema, or if that header lacks its terminating newline. It also rejects existing data rows with a field count other than 13, missing timestamp/device/ID, a malformed UTC timestamp (including invalid Gregorian dates or times), or a final line without a newline (which would otherwise be joined to the next appended record). These checks happen **before smartctl**, so rejected history does not wake the disk; they repeat under the snapshot lock. The existing file is left unchanged, and cached read commands are unaffected. Validation scans the existing history on each explicit refresh; it does not validate metric semantics or leap-second authenticity, migrate schemas, repair damaged data or protect against concurrent hostile filesystem changes.

To diagnose the mismatch without changing the file, inspect the first line, for example:

```sh
sudo head -n 1 /var/lib/disk-watch/health/snapshots.tsv
sudo awk -F '\t' 'NR>1 && (NF!=13 || $1=="" || $2=="" || $3=="") {print "invalid row:", NR}' /var/lib/disk-watch/health/snapshots.tsv
sudo awk -F '\t' 'NR>1 && $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ {print "invalid UTC shape:", NR}' /var/lib/disk-watch/health/snapshots.tsv
```

Preserve the original history and investigate the schema or damaged rows before attempting any manual conversion. The examples detect column-count/required-field problems and timestamp shape, but not invalid calendar days or clock ranges; refresh performs those additional checks. An unterminated final row must be checked separately. Refresh uses existing Bash, `awk` and GNU coreutils (`tail`); no new runtime service or hardware probe is required. Older/custom history is not silently rewritten.

## Snapshot fields

`timestamp_utc`, `device`, `id` (SMART serial if available, otherwise validated WWN prefixed `wwn:`, otherwise device path), `model`, `health` (firmware SMART overall result), `temperature_c`, `power_on_hours`, `reallocated`, `pending`, `media_errors`, `gb_written`, `wear_percent`, `last_test`.

Unavailable information is printed literally as `unavailable`, **never as zero**. `gb_written` is a decimal-GB estimate derived *only when* the NVMe Data Units Written counter is exposed (each unit represents 512,000 bytes). It is not written for drives that lack this counter. `last_test` is a coarse indicator from the available SMART text, not a complete timestamped self-test log. `health=passed` only reflects the SMART firmware overall assessment and **does not certify disk reliability**; check pending/reallocated sectors and errors independently. Firmware attributes differ between SATA, NVMe and USB bridges, and unsupported fields remain unavailable. The serial parser accepts both `Serial Number:` and `Serial number:` labels in smartctl text (common in SCSI/USB reports) and trims surrounding whitespace. If no serial is provided, a 16-hex-digit `LU WWN Device Id:` or `WWN Device Id:` (spaces ignored, hex lowercased) is used as `wwn:<hex>`. Common non-unique serial placeholders (`UNKNOWN`, `N/A`, `NONE`, `UNAVAILABLE`, `NOT AVAILABLE`, `NOT SPECIFIED`, `To Be Filled By O.E.M.`, and zero-only or all-`F` serials; case-insensitive) are ignored; a valid WWN can then be used instead. All-zero and all-`F` WWNs (including spaced smartctl output) are also ignored as non-unique sentinel identifiers. An unusable or absent WWN falls back to the explicit device path, which is not stable across reboots. Existing real serial-based IDs retain precedence, so older history is not silently relabeled. This parses an identifier already present in an explicitly requested SMART report; it does not discover /dev/disk/by-id links, verify WWN uniqueness, or determine whether a USB bridge supports safe standby probing.

The CSV/JSONL export, full historical SMART self-test log, automatic snapshot schedule, per-drive never-wake policies and fleet-wide aggregate health assessment are tracked by separate roadmap issues. This implementation does not automatically collect new snapshots. Reports are local and read-only; `status` shows `last_alert: unavailable` until a future issue persists alert history.

## Format, privacy and retention

The history is a root-owned, append-only TSV with permissions `600` (within a private `health/` directory); it stores serials and model names, not Telegram tokens. Before any live SMART probe, refresh now rejects a directly symlinked state or health directory, a symlinked snapshot or lock file, and non-regular snapshot/lock targets (such as FIFOs). These checks are repeated before writing; the lock is opened without truncating an existing regular file. Refresh also walks existing ancestors of the state/health directory and refuses symlinks or non-directory components (including relative --state-dir paths). Use a trusted state directory and trusted parent paths: these best-effort checks do **not** eliminate concurrent path-replacement races. Existing setups using a symlink as the state directory must switch to its real directory path for refresh; cached reads remain unchanged. Back it up if the history matters to you; a new host with no snapshots will not show historical metrics. No retention or automatic pruning is applied yet. Device names such as `/dev/sda` are not persistent identities; a changed device path can make a non-serial sample look like a different disk.

The installer and updater preserve `/etc/disk-watch.conf`, existing kernel cursor state and previous snapshot records. Production deployment is **manual**, one host at a time, with backup/preflight and post-install Telegram checks. See [operations](operations.md).

For non-Linux/unusual smartctl output, parsing is best-effort: if the report cannot be read, it returns an error without saving a new snapshot. Mocks of NVMe, ATA and synthetic SCSI/USB serial-label variants are tested in CI; this is **not** hardware certification, a USB standby-safety probe or a full NVMe JSON parser.
