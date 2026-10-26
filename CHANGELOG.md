# Changelog

All notable changes to Disk Watch are documented here. Entries under **Unreleased** describe changes proposed or merged since the last tagged release; they do not imply deployment to any host.

## Unreleased

### Fixed
- Avoid exposing the Telegram bot token in `curl` command-line arguments by passing the URL via stdin; reject malformed token values before invoking curl.
- Treat local syslog logging failures as non-fatal after successful I/O alert delivery, so the journal cursor advances and the same event is not resent solely because `logger` failed.

### Tests
- Cover Telegram bot token format rejection and ensure the token is absent from curl process arguments while stdin config contains the URL.
- Add a regression for failed `logger` after successful Telegram delivery.
- Add a regression test ensuring a missing Telegram bot token fails the disk scan without advancing its journal cursor or contacting Telegram, allowing the pending alert to be retried after configuration is fixed.

### Documentation
- Clarify the isolated smoke-test coverage in README.md.
