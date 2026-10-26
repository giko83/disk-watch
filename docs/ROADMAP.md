# Disk Watch — roadmap and feature backlog

Source of truth for planned work: [GitHub Issues](https://github.com/giko83/disk-watch/issues?q=is%3Aissue). All entries below are **proposals, not implemented features**, until their issues are closed with tested changes and the relevant documentation is updated.

Last curated: 2026-10-26.

**In progress:** #18 has a first no-install CLI step (`check`, `--config`, `--state-dir` and mocked regression tests). The issue stays open until portable release packaging and the remaining acceptance criteria are verified. See [portable usage](portable.md).

## Design constraints

1. **Minimal dependencies:** Bash and common Linux utilities for the existing kernel log monitor; `smartctl` (smartmontools) is optional and required only for SMART operations; `curl` for HTTP notifications, `sendmail` for mail, `git` only for Git-based updates. No mandatory database, Python, Node.js, UI server, cloud, or continuously running agent.
2. **Portable-first:** installation into system paths and systemd scheduling should be optional. Support manual CLI use and external schedulers (e.g. cron). Gracefully explain when journald, SMART support, or permissions are unavailable. New portability backends must document their prerequisites.
3. **Conservative disk access:** SMART checks and tests can wake sleeping drives. Never assume `-n standby` works through USB bridges; unsupported power-state detection must be treated as unsafe for never-wake policies. Avoid destructive tests.
4. **Honest statistics:** distinguish raw firmware-reported counters from derived estimates and absent data. Bytes written and SSD wear may be available for some NVMe/ATA devices, but bytes deleted, TRIM/discard calls and NAND erase cycles are **not universally reported**. Never synthesize missing hardware metrics.
5. **Privacy and resilience:** never commit or log tokens; keep `/etc/disk-watch.conf` and `/var/lib/disk-watch` outside Git; retain journal cursor, history and existing host settings across upgrades.
6. **Maintainer-friendly:** prefer a small, testable core with offline mocks/fixtures. Every behavior change updates CLI examples, relevant documentation, tests, and (for releases) changelog.
7. **Safe delivery:** changes are reviewed and tested before merge. Work through one active PR at a time where practical; close/supersede obsolete PRs instead of leaving overlapping work. No automatic deployment to production hosts.

## P0 — foundations / next implementation candidates

| Issue | Goal | Main deliverable |
| --- | --- | --- |
| [#18](https://github.com/giko83/disk-watch/issues/18) | Portable mode | Manual standalone runner, no mandatory systemd or installation |
| [#19](https://github.com/giko83/disk-watch/issues/19) | On-demand SMART tests | Safe short / long self-tests per specified disk |
| [#20](https://github.com/giko83/disk-watch/issues/20) | Scheduled SMART tests | Configurable per-disk test cadence, opt-in and standby-aware |
| [#21](https://github.com/giko83/disk-watch/issues/21) | SMART history | Persistent timestamped per-disk snapshots, tests and retention |
| [#22](https://github.com/giko83/disk-watch/issues/22) | Disk write / wear metrics | Raw and normalized counters with units and unavailable semantics |
| [#23](https://github.com/giko83/disk-watch/issues/23) | Stable drive IDs | WWN/serial/by-id mapping, USB/SAT capability matrix |
| [#24](https://github.com/giko83/disk-watch/issues/24) | Safer upgrades | Preflight checks, backups, documented and tested rollback |

## P1 — diagnostics and useful insights

| Issue | Goal | Main deliverable |
| --- | --- | --- |
| [#25](https://github.com/giko83/disk-watch/issues/25) | Self-test progress | Monitor completion/failure and persist outcome |
| [#26](https://github.com/giko83/disk-watch/issues/26) | Meaningful alerts | Thresholds, change detection, cooldown and recovery |
| [#27](https://github.com/giko83/disk-watch/issues/27) | Read-only reports | Status, inventory, history and CLI summaries |
| [#28](https://github.com/giko83/disk-watch/issues/28) | Protect sleeping disks | Explicit per-drive never-wake policy, USB-safe behavior |
| [#29](https://github.com/giko83/disk-watch/issues/29) | Disk lifecycle events | Correlate kernel I/O errors, resets and device disconnects |
| [#30](https://github.com/giko83/disk-watch/issues/30) | Data export | CSV, JSONL and optional Prometheus textfile |

## P2 — optional extensions

| Issue | Goal | Main deliverable |
| --- | --- | --- |
| [#31](https://github.com/giko83/disk-watch/issues/31) | Offline visualization | Static HTML dashboard, no runtime web server |
| [#32](https://github.com/giko83/disk-watch/issues/32) | Additional transports | Optional generic webhook / ntfy notifications |
| [#33](https://github.com/giko83/disk-watch/issues/33) | Quality and releases | OS compatibility matrix, fixture coverage, portable release archive |

## Suggested implementation order

1. **Identity and safe diagnostics:** #23 → #19. Know which disk is addressed, and only then permit an explicit self-test.
2. **Persistent evidence:** #21 → #22 → #25 → #27. Record data before plotting or aggregating it.
3. **Sleep-safe scheduling:** #28 → #20. A user opt-in schedule should never defeat a configured never-wake policy.
4. **Delivery and portability:** #24 and #18, maintaining the existing timer and config compatibility.
5. **Alerts, exports and optional UI:** #26 → #30 → #31. Other improvements can be tackled independently.

The priority groups express desirability, **not a promised delivery schedule**; each issue can be adjusted as test coverage and user feedback improve.

## Feature development definition of done

- [ ] One issue or clearly scoped PR, no duplicate/obsolete overlapping work.
- [ ] New behavior has deterministic offline tests, including errors, unsupported devices, standby and configuration compatibility where applicable.
- [ ] Tests/CI pass and are reviewed before merge; CI failures are fixed or the proposed change is closed, not left stranded.
- [ ] README, example configuration, and relevant operations/SMART documentation are updated alongside the code.
- [ ] Existing host configurations, secrets, cursors and data histories remain intact.
- [ ] The release notes identify any changes in prerequisites or behavior.
- [ ] No unattended production deployment is implied by a GitHub merge.

## Technical references

- [smartctl manual](https://manpages.debian.org/trixie/smartmontools/smartctl.8.en.html) — SMART command capabilities and power-mode limitations.
- [USB/SATA standby troubleshooting](smart-usb-standby.md).
- [Safe installation and rollback runbook](operations.md).
