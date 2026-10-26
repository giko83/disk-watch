# Changelog

All notable changes to Disk Watch are documented here. Entries under **Unreleased** describe changes proposed or merged since the last tagged release; they do not imply deployment to any host.

## Unreleased

### Added
- Add a read-only, unprivileged `install.sh --preflight` command that checks required files, Bash/POSIX shell syntax and core commands before deployment. The updater invokes it after `git pull --ff-only` and before installing files; it is not a rollback mechanism.
- Add an offline, allowlist-based portable source archive builder (`scripts/build-portable.sh`), without Git, root, systemd or new runtime dependencies.
- Add portable one-shot `check` command (alias of `scan`) and CLI `--config`/`--state-dir` overrides with environment-variable fallbacks. This does not require installation or a systemd timer when the invoking user can read the kernel journal.

### Fixed
- Avoid creating or requiring a writable state directory for notification-only `test` and `smart` commands in portable mode; add an offline regression test.
- Return a clear diagnostic when the kernel journal cannot be read rather than exposing only a raw journalctl failure.
- Avoid changing the permissions of pre-existing state directories; use a private umask for new cursor and lock files.
- Avoid exposing the Telegram bot token in `curl` command-line arguments by passing the URL via stdin; reject malformed token values before invoking curl.
- Treat local syslog logging failures as non-fatal after successful I/O alert delivery, so the journal cursor advances and the same event is not resent solely because `logger` failed.

### Tests
- Fix CI syntax checks to validate each Bash script separately rather than treating additional paths as arguments to the first script; validate the POSIX SMART adapter with `sh -n`.
- Add offline installer preflight regression coverage for missing files, invalid Bash syntax, unsupported arguments and no systemctl invocation.
- Verify exact portable archive contents and run packaged `init`/`check` against offline journal and mail mocks in CI.
- Add isolated portable CLI tests for quoted paths, option precedence, one-shot checks, missing configuration and failed journal reads.
- Add isolated `sendmail` transport smoke tests for test notifications, retry after failed mail delivery without losing the journal cursor, and SMART email formatting.
- Cover Telegram bot token format rejection and ensure the token is absent from curl process arguments while stdin config contains the URL.
- Add a regression for failed `logger` after successful Telegram delivery.
- Add a regression test ensuring a missing Telegram bot token fails the disk scan without advancing its journal cursor or contacting Telegram, allowing the pending alert to be retried after configuration is fixed.

### Documentation
- Explain installer preflight limitations and safe manual update behavior in README and the operations runbook.
- Document portable archive build, extraction, configuration isolation and remaining portability limitations.
- Document no-install CLI, cron scheduling and journald permissions in docs/portable.md, README, example config and roadmap.
- Clarify the isolated smoke-test coverage in README.md.
