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

The `health` command without refresh is simply the last saved SMART snapshot per disk, **not a live scan**. On a new installation it honestly reports `SMART history: unavailable` until at least one opt-in snapshot exists. `status --format tsv` exports key/value rows; the other TSV commands export a 13-column snapshot schema. For offline tests or portable mode, provide `--state-dir DIR` *after* the subcommand, or use `DISK_WATCH_STATE_DIR`.

## Explicitly collect a SMART health snapshot

**SMART access may wake a sleeping disk, and some USB-SATA adapters cannot report standby reliably.** Only run the following for a disk you intentionally want to query:

```sh
sudo /usr/local/sbin/disk-watch.sh health --device /dev/nvme0 --refresh --wake-ok
```

Replace `/dev/nvme0` with the exact device you have identified. Prefer a persistent `/dev/disk/by-id/...` path for SATA drives when available. The command runs `smartctl -a` once, then appends a limited, parsed snapshot to `/var/lib/disk-watch/health/snapshots.tsv`. It does **not** initiate short/long self-tests, perform writes to the device, configure schedules or change `smartd`.

`--refresh` and `--wake-ok` are both required. Do **not** run against USB backup disks deliberately configured to remain asleep (such as a Restic backup disk) unless you intentionally accept a spin-up. **Default reports never query hardware**, even if a `--device` filter is present.

## Snapshot fields

`timestamp_utc`, `device`, `id` (SMART serial where available, else device path), `model`, `health` (firmware SMART overall result), `temperature_c`, `power_on_hours`, `reallocated`, `pending`, `media_errors`, `gb_written`, `wear_percent`, `last_test`.

Unavailable information is printed literally as `unavailable`, **never as zero**. `gb_written` is a decimal-GB estimate derived *only when* the NVMe Data Units Written counter is exposed (each unit represents 512,000 bytes). It is not written for drives that lack this counter. `last_test` is a coarse indicator from the available SMART text, not a complete timestamped self-test log. `health=passed` only reflects the SMART firmware overall assessment and **does not certify disk reliability**; check pending/reallocated sectors and errors independently. Firmware attributes differ between SATA, NVMe and USB bridges, and unsupported fields remain unavailable.

The CSV/JSONL export, full historical SMART self-test log, automatic snapshot schedule, per-drive never-wake policies and fleet-wide aggregate health assessment are tracked by separate roadmap issues. This implementation does not automatically collect new snapshots. Reports are local and read-only; `status` shows `last_alert: unavailable` until a future issue persists alert history.

## Format, privacy and retention

The history is a root-owned, append-only TSV with permissions `600` (within a private `health/` directory); it stores serials and model names, not Telegram tokens. Back it up if the history matters to you; a new host with no snapshots will not show historical metrics. No retention or automatic pruning is applied yet. Device names such as `/dev/sda` are not persistent identities; a changed device path can make a non-serial sample look like a different disk.

The installer and updater preserve `/etc/disk-watch.conf`, existing kernel cursor state and previous snapshot records. Production deployment is **manual**, one host at a time, with backup/preflight and post-install Telegram checks. See [operations](operations.md).

For non-Linux/unusual smartctl output, parsing is best-effort: if the report cannot be read, it returns an error without saving a new snapshot. Mocks of NVMe and ATA are tested in CI; this is **not** hardware certification or a full NVMe JSON parser.
