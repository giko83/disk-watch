# Changelog

All notable changes to Disk Watch are documented here. Entries under **Unreleased** describe changes proposed or merged since the last tagged release; they do not imply deployment to any host.

## Unreleased

### Added
- Add relative-path SHA-256 integrity manifests to newly created pre-install snapshots and verify them before marking a snapshot complete; `sha256sum` is now checked during installer preflight. This detects corruption but is not a signature or automatic rollback; older snapshots have no hashes.
- Before replacing installed files, the root installer now creates a timestamped, private pre-install snapshot of existing Disk Watch scripts and systemd units with present/absent manifests and a final completion marker. Backup errors abort installation; there is still no automatic rollback or backup pruning. No config, credentials or cursor are copied.
- Generate a portable archive SHA-256 checksum sidecar with a relative filename, allowing offline integrity verification even when the archive and checksum are moved together. The checksum is not an authenticity signature and adds no runtime dependency.
- Add a read-only, unprivileged `install.sh --preflight` command that checks required files, Bash/POSIX shell syntax and core commands before deployment. The updater invokes it after `git pull --ff-only` and before installing files; it is not a rollback mechanism.
- Add an offline, allowlist-based portable source archive builder (`scripts/build-portable.sh`), without Git, root, systemd or new runtime dependencies.
- Add portable one-shot `check` command (alias of `scan`) and CLI `--config`/`--state-dir` overrides with environment-variable fallbacks. This does not require installation or a systemd timer when the invoking user can read the kernel journal.

### Fixed
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
- Document manual checksum verification before recovery, legacy snapshot limitations and the GNU coreutils `sha256sum` installer requirement.
- Explain versioned pre-install snapshots, how to inspect a completed manifest and limitations of manual recovery in README and the operations runbook.
- Explain duplicate systemd directive detection and the limits of the lightweight preflight in README and operations runbook.
- Show how to verify the portable source archive before extraction and clarify checksum limitations and the build-only `sha256sum` dependency.
- Explain installer preflight limitations and safe manual update behavior in README and the operations runbook.
- Document portable archive build, extraction, configuration isolation and remaining portability limitations.
- Document no-install CLI, cron scheduling and journald permissions in docs/portable.md, README, example config and roadmap.
- Clarify the isolated smoke-test coverage in README.md.
