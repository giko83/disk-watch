# Changelog

All notable changes to Disk Watch are documented here. Entries under **Unreleased** describe changes proposed or merged since the last tagged release; they do not imply deployment to any host.

## Unreleased

### Added
- Make locally built portable source archives byte-reproducible across build directories and umasks using normalized GNU tar/gzip metadata and file permissions; add an offline byte-comparison regression. GNU tar and gzip are build-only prerequisites, with no runtime change or published release.
- Add an opt-in offline restore rehearsal into a private, empty sandbox, re-verifying snapshot integrity and copied file contents/modes without touching installed paths, systemd or host state. This does not provide live rollback.
- Add a read-only recovery planner for verified pre-install snapshots: list four fixed paths to restore or review without copying, deleting, changing services or touching host state. This is not a root-level rollback or transactional update.
- Add a read-only pre-install snapshot verifier that checks private ownership/mode, completion marker, fixed-path present/absent manifests, symlinks and SHA-256 integrity before manual restore. It never writes host files or performs rollback; legacy snapshots without hashes are rejected.
- Add relative-path SHA-256 integrity manifests to newly created pre-install snapshots and verify them before marking a snapshot complete; `sha256sum` is now checked during installer preflight. This detects corruption but is not a signature or automatic rollback; older snapshots have no hashes.
- Before replacing installed files, the root installer now creates a timestamped, private pre-install snapshot of existing Disk Watch scripts and systemd units with present/absent manifests and a final completion marker. Backup errors abort installation; there is still no automatic rollback or backup pruning. No config, credentials or cursor are copied.
- Generate a portable archive SHA-256 checksum sidecar with a relative filename, allowing offline integrity verification even when the archive and checksum are moved together. The checksum is not an authenticity signature and adds no runtime dependency.
- Add a read-only, unprivileged `install.sh --preflight` command that checks required files, Bash/POSIX shell syntax and core commands before deployment. The updater invokes it after `git pull --ff-only` and before installing files; it is not a rollback mechanism.
- Add an offline, allowlist-based portable source archive builder (`scripts/build-portable.sh`), without Git, root, systemd or new runtime dependencies.
- Add portable one-shot `check` command (alias of `scan`) and CLI `--config`/`--state-dir` overrides with environment-variable fallbacks. This does not require installation or a systemd timer when the invoking user can read the kernel journal.

### Fixed
- Refuse pre-existing symlinks at either portable archive or `.sha256` output path before writing, avoiding accidental clobbering of symlink targets. Use a trusted output directory; this best-effort check does not eliminate concurrent path-replacement races. No new build or runtime dependency.
- Reject symlinked allowlisted files and a symlinked `docs/` parent when building the portable archive, before creating output, so links cannot dereference private content from outside the source tree. Offline fixture tests cover both cases; build/runtime dependencies are unchanged.
- Reject duplicate input source paths before creating pre-install snapshot manifests; previously a repeated path could yield a `.complete` snapshot that the strict verifier would reject. No runtime dependencies or live-host changes.
- Clean up only allowlisted files and empty directories created by a failed offline restore rehearsal, instead of leaving misleading partial sandbox output. Cleanup is best-effort and never touches the source snapshot or installed paths.
- Fail read-only installer preflight if the snapshot verifier, restore planner or sandbox rehearsal helper is missing, empty or Bash-syntax-invalid; this does not prove root-level recovery or change installed files.
- Reject unlisted snapshot files, hidden entries, symlinks and special files during read-only recovery verification; only four fixed installed paths and metadata files are eligible. No live paths or services are touched.
- Reject offline restore rehearsal destinations nested inside the source snapshot (including symlinked parent aliases) before any copy, preserving backup isolation without adding dependencies or touching live paths.
- Reject pre-install snapshot destinations that are not owned by the invoking user, not mode `700`, or not empty (including hidden files), before writing manifests or copies. This adds no new runtime dependency beyond the already required GNU `stat` and does not provide automatic rollback.
- Refuse root installation when `/etc/disk-watch.conf` is a symlink, not root-owned or group/world-accessible; the guard checks metadata before snapshots or replacement, without reading secrets or modifying permissions. Existing `640` configs need manual tightening; no new service or database.
- Reject duplicate active `ExecStart=` and timer `Unit=` directives in installer preflight, preventing a valid-looking entry from masking a later conflicting directive; no new runtime dependency.
- Reject a syntactically valid but misdirected `disk-watch-smart.sh` during read-only installer preflight, preventing silent loss of `smartd` forwarding after an update; add an offline regression without new runtime dependencies.
- Make installer preflight reject missing or syntactically invalid `update.sh` before replacing installed files; this does not add runtime dependencies or provide automatic rollback.
- Reject packaged systemd units whose service `ExecStart` or timer `Unit` no longer points to the installed Disk Watch entry points during read-only preflight; no extra runtime dependency or systemctl invocation.
- Avoid creating or requiring a writable state directory for notification-only `test` and `smart` commands in portable mode; add an offline regression test.
- Return a clear diagnostic when the kernel journal cannot be read rather than exposing only a raw journalctl failure.
- Avoid changing the permissions of pre-existing state directories; use a private umask for new cursor and lock files.
- Avoid exposing the Telegram bot token in `curl` command-line arguments by passing the URL via stdin; reject malformed token values before invoking curl.
- Treat local syslog logging failures as non-fatal after successful I/O alert delivery, so the journal cursor advances and the same event is not resent solely because `logger` failed.

### Tests
- Add an offline duplicate-source backup regression that asserts a clear diagnostic and an untouched private snapshot directory.
- Simulate a mid-rehearsal copy failure after an earlier successful copy; assert an empty sandbox, a diagnostic and unchanged snapshot hashes (offline, no root or hardware).
- Exercise missing and syntactically broken recovery helpers in unprivileged installer preflight fixtures; confirm no systemctl invocation. CI also checks the helper scripts directly with Bash syntax validation.
- Add offline snapshot-verifier regressions for hidden extra files, unlisted symlinks and unexpected nested files, without root, hardware or network.
- Cover direct and symlink-aliased nested rehearsal sandboxes, asserting clear rejection and unchanged snapshot contents with offline fixtures.
- Rehearse verified and empty snapshots offline, preserve copied file modes, and reject damaged snapshots, unsafe or prepopulated sandboxes and missing arguments without touching installed paths.
- Exercise recovery planning on valid, empty, tampered and space-containing snapshot paths; ensure no plan is emitted for damaged snapshots and no files are changed (offline, no root).
- Add offline verifier fixtures for valid and empty snapshots, tampered files, duplicate/unknown manifest entries, extra hashes, absent-file conflicts, missing markers, legacy snapshots, public directories and symlinks.
- Verify snapshot SHA-256 manifests, reject tampered copies, accept an empty new-install snapshot and refuse completion if checksum generation fails (all offline).
- Extend offline snapshot regression coverage for world-readable and prepopulated (hidden-entry) backup directories, confirming that neither is marked complete or overwritten.
- Extend offline installer preflight tests to require the config checker and verify root ownership, restrictive modes, malformed metadata, missing files and symlink rejection using mocked `stat`, without accessing host config or invoking systemd.
- Add offline snapshot regression tests for preserved content/modes, missing-file manifests, refusal to reuse a completed snapshot, symlink rejection and copy failure; extend installer preflight tests to reject a missing or syntactically invalid backup helper.
- Add unprivileged offline updater control-flow regression coverage with mocked Git and installer: missing/dirty checkout, failed fast-forward pull, failed preflight, failed install and successful ordered update. CI runs the suite; no real Git pull, installation or network is performed.
- Add offline negative cases for conflicting duplicate systemd service and timer directives; verify preflight never invokes `systemctl`.
- Add offline negative cases for a missing updater and invalid updater Bash syntax in the read-only installer preflight suite.
- Exercise preflight rejection of syntactically valid but misdirected service/timer units with offline fixtures, without invoking systemctl.
- Verify the portable archive checksum, basename portability and rejection of modified archive contents with offline tests.
- Fix CI syntax checks to validate each Bash script separately rather than treating additional paths as arguments to the first script; validate the POSIX SMART adapter with `sh -n`.
- Add offline installer preflight regression coverage for missing files, invalid Bash syntax, unsupported arguments and no systemctl invocation.
- Verify exact portable archive contents and run packaged `init`/`check` against offline journal and mail mocks in CI.
- Add isolated portable CLI tests for quoted paths, option precedence, one-shot checks, missing configuration and failed journal reads.
- Add isolated `sendmail` transport smoke tests for test notifications, retry after failed mail delivery without losing the journal cursor, and SMART email formatting.
- Cover Telegram bot token format rejection and ensure the token is absent from curl process arguments while stdin config contains the URL.
- Add a regression for failed `logger` after successful Telegram delivery.
- Add a regression test ensuring a missing Telegram bot token fails the disk scan without advancing its journal cursor or contacting Telegram, allowing the pending alert to be retried after configuration is fixed.

### Documentation
- Document recovery-helper preflight coverage and its limitations in README, operations runbook and roadmap.
- Clarify that snapshot verification rejects unlisted non-directory content and requires standard `find`, without implying a tested root-level rollback.
- Explain why the offline restore rehearsal must use a sandbox outside the source snapshot, even when paths use symlinked parents.
- Explain safe sandbox rehearsal, partial-sandbox cleanup and why it does not prove root-level rollback.
- Document how to generate and interpret the verified recovery checklist before manual restoration, including absent-file safety and unverified root-level rollback limitations.
- Document read-only snapshot verification before manual restore, prerequisites and remaining root-level rollback limitations.
- Document manual checksum verification before recovery, legacy snapshot limitations and the GNU coreutils `sha256sum` installer requirement.
- Explain versioned pre-install snapshots, how to inspect a completed manifest and limitations of manual recovery in README and the operations runbook.
- Explain duplicate systemd directive detection and the limits of the lightweight preflight in README and operations runbook.
- Show how to verify the portable source archive before extraction and clarify checksum limitations and the build-only `sha256sum` dependency.
- Explain installer preflight limitations and safe manual update behavior in README and the operations runbook.
- Document portable archive build, extraction, configuration isolation and remaining portability limitations.
- Document no-install CLI, cron scheduling and journald permissions in docs/portable.md, README, example config and roadmap.
- Clarify the isolated smoke-test coverage in README.md.
