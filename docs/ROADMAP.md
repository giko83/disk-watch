# Disk Watch — roadmap and feature backlog

Source of truth for planned work: [GitHub Issues](https://github.com/giko83/disk-watch/issues?q=is%3Aissue). All entries below are **proposals, not implemented features**, until their issues are closed with tested changes and the relevant documentation is updated.

Last curated: 2026-10-30.

**Partial #24 snapshot verification gate:** after the installer creates a completed private five-path pre-install snapshot, it independently verifies the manifest, allowlist, metadata and hashes before replacing any installed file. Offline regressions cover completed-snapshot corruption and installer gate ordering. No new dependencies, root tests, deployment or automatic rollback; real partial-install recovery and systemd restoration remain unverified. #24 remains open.

**Partial #24 checkout-source guard:** read-only installer preflight now rejects symlinked required checkout files and a symlinked `scripts/` directory before any root deployment. Offline regression covers both refusal paths and a normal checkout. No new runtime dependencies, host changes or deployment; this does not validate root rollback, defend against hostile hard links or eliminate filesystem races. #24 remains open.

**Partial #24 installed-source alias safety:** pre-install snapshotting now refuses existing installed scripts/units with multiple hard links, before creating any manifest or replacing host files. Offline mocks verify no snapshot artifacts, unchanged shared source bytes, and acceptance after unlinking the alias. GNU `stat` was already required; this is a best-effort guard, not root rollback or protection against filesystem races. #24 remains open.

**Partial #21 metric-integrity increment:** explicit SMART refresh now refuses existing history with unknown health/self-test statuses or malformed numeric counters, before hardware access and again under the append lock. Offline fixtures check rejection, no probe, unchanged bytes, and valid-history compatibility. This does not add raw SMART provenance, retention, stable IDs on all devices or automatic repair; #21 remains open.

**Partial #21 hardlink safety increment:** explicit SMART refresh now rejects snapshot and lock files with multiple hard links (as well as dangling symlinks), before any SMART probe and again under the write lock. Offline tests verify refusal, unchanged shared target bytes and no probe. GNU `stat` is required for opt-in refresh only; cached reads are unchanged. This is best-effort filesystem hardening, not race-proof isolation or complete stable-ID history/retention; #21 remains open.

**Partial #23 identification increment:** common placeholder serial values (UNKNOWN/N/A/NONE/UNAVAILABLE/NOT AVAILABLE/NOT SPECIFIED/OEM filler/zero-only/all-F) and all-zero/all-F WWNs are now excluded from cache identities; a valid WWN is preferred to the device path when the serial is only a placeholder. Offline mocks cover these collisions. Cached opt-in SMART refresh recognizes both `Serial Number:` and SCSI/USB-style `Serial number:` text labels (trimming whitespace). When no serial exists, a validated 16-hex-digit WWN from the same report now supplies a `wwn:<hex>` cache ID; otherwise it falls back to the device path. Offline mocks cover spaced/compact WWNs, path changes, malformed values and serial precedence. This is not /dev/disk/by-id discovery, USB/SAT capability probing, or a never-wake policy; #23 remains open. See [health guide](health.md).

**Partial #21 UTC-history increment:** explicit refresh now also refuses existing snapshot rows with malformed UTC timestamps, impossible Gregorian dates (including non-leap February 29) or out-of-range clock fields, before SMART access and again under the lock. Offline mocks assert unchanged history, zero probes on rejection and acceptance of valid leap-day history. This does not validate all metric semantics or implement retention; #21 remains open.

**Partial #21 safety increment:** explicit SMART snapshot refresh now rejects directly symlinked state/health directories and symlinked or non-regular snapshot/lock targets before disk access, with offline regressions. This now also rejects symlinked or non-directory ancestors of the state directory before SMART access, with offline regressions. An additional guard rejects existing snapshot histories with incompatible or unterminated TSV headers, malformed 13-column data rows, missing required timestamp/device/ID or an unterminated last row before SMART access, with offline regression tests and no automatic migration. It scans existing rows on each opt-in refresh and repeats under the write lock; cached reads are unchanged. It is not stable-ID history, retention or race-proof filesystem isolation; #21 remains open.

**Implemented (issue #27, [PR #63](https://github.com/giko83/disk-watch/pull/63)):** cached non-waking `status`, `disks`, `health`, `history`, and `report` commands with optional explicit SMART snapshots (`--refresh --wake-ok`) are merged into `main` with offline tests. They are **not automatically deployed** to the three homelab hosts. Persistent alert history and comprehensive timestamped SMART self-test collection remain outside this MVP; `SMART PASSED` is not a reliability guarantee. See [health guide](health.md).

**In progress:** #24 root-run updater Git invocations now disable repository hooks during pull and configured fsmonitor during status/pull, with exact-command offline mocks; this is not a Git sandbox or root rollback. #24 now has a read-only installer preflight for local files, syntax and required commands; timestamped pre-install snapshots of existing installed files (with manifests and offline tests) are now available, with source leaf/parent symlink refusal before copying; a read-only snapshot verifier is available for checksum and manifest validation; a read-only restore planner now turns verified manifests into an allowlisted human checklist without writing host files; an offline restore rehearsal copies only verified allowlisted files into a private empty sandbox and checks their modes and contents without changing installed paths; the rehearsal also rejects sandboxes nested in source snapshots, including symlink aliases; installer preflight now also checks that all three recovery helpers exist and parse as Bash (offline only); new format-2 snapshots now include `disk-watch-health.sh` (previously omitted despite being deployed) with a five-path strict manifest; checksum-bearing legacy four-path snapshots remain verifiable but explicitly warn that the health helper is not captured; automatic rollback and real root-level recovery validation remain outstanding; root installation now checks config ownership and restrictive permissions before any replacement (tested offline with mocked metadata). Offline mocked updater-flow regression tests now cover successful and failed Git/preflight/install control paths, including failed Git status checks and a checkout made dirty during pull; the updater refuses to install from such a tree. This does not prove real root installation, Git-hook isolation or rollback. #18 has a no-install CLI (`check`, `--config`, `--state-dir`) and an offline portable source-archive builder with an SHA-256 integrity sidecar and mocked regression tests. The issue stays open until published release packaging, additional compatibility coverage and the remaining acceptance criteria are verified. See [portable usage](portable.md). #33 has an initial reproducible local archive build (normalized GNU tar/gzip metadata and offline byte-for-byte regression), plus Ubuntu 22.04/24.04 and Debian 12/13 offline CI for Bash syntax and nine mocked suites; live Proxmox compatibility, real SMART fixtures, published release and remaining acceptance criteria are still outstanding. The portable builder now also refuses symlinked allowlisted inputs and a symlinked docs directory, with offline regressions, to prevent unintentional inclusion of files outside the checkout. It also refuses pre-existing symlinks, non-regular output targets and hard links to packaged source files or the builder at archive/checksum paths, avoiding blocked writes and accidental source truncation; use a trusted output directory because this is not a race-proof guarantee. Archive and checksum generation now stages both outputs before publishing, preserving existing files on compression/checksum failure; the two final renames are not an atomic pair. Staged checksums are also required to be non-empty and verified against the staged archive before publication, including when a faulty `sha256sum` exits successfully without output.

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
| [#27](https://github.com/giko83/disk-watch/issues/27) | Read-only reports — **implemented** | Status, inventory, history and CLI summaries (explicit refresh optional) |
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
