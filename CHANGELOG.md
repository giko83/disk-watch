# Changelog

All notable changes to Disk Watch are documented here. Entries under **Unreleased** describe changes proposed or merged since the last tagged release; they do not imply deployment to any host.

## Unreleased

### Added
- Add portable one-shot `check` command (alias of `scan`) and CLI `--config`/`--state-dir` overrides with environment-variable fallbacks. This does not require installation or a systemd timer when the invoking user can read the kernel journal.

### Fixed
- Return a clear diagnostic when the kernel journal cannot be read rather than exposing only a raw journalctl failure.
- Avoid changing the permissions of pre-existing state directories; use a private umask for new cursor and lock files.
- Avoid exposing the Telegram bot token in `curl` command-line arguments by passing the URL via stdin; reject malformed token values before invoking curl.
- Treat local syslog logging failures as non-fatal after successful I/O alert delivery, so the journal cursor advances and the same event is not resent solely because `logger` failed.

### Tests
- Add isolated portable CLI tests for quoted paths, option precedence, one-shot checks, missing configuration and failed journal reads.
- Add isolated `sendmail` transport smoke tests for test notifications, retry after failed mail delivery without losing the journal cursor, and SMART email formatting.
- Cover Telegram bot token format rejection and ensure the token is absent from curl process arguments while stdin config contains the URL.
- Add a regression for failed `logger` after successful Telegram delivery.
- Add a regression test ensuring a missing Telegram bot token fails the disk scan without advancing its journal cursor or contacting Telegram, allowing the pending alert to be retried after configuration is fixed.

### Documentation
- Document no-install CLI, cron scheduling and journald permissions in docs/portable.md, README, example config and roadmap.
- Clarify the isolated smoke-test coverage in README.md.
