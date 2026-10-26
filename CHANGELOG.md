# Changelog

All notable changes to Disk Watch are documented here. Entries under **Unreleased** describe changes proposed or merged since the last tagged release; they do not imply deployment to any host.

## Unreleased

### Fixed
- Treat local syslog logging failures as non-fatal after successful I/O alert delivery, so the journal cursor advances and the same event is not resent solely because `logger` failed.

### Tests
- Add a regression for failed `logger` after successful Telegram delivery.

### Tests
- Add a regression test ensuring a missing Telegram bot token fails the disk scan without advancing its journal cursor or contacting Telegram, allowing the pending alert to be retried after configuration is fixed.

### Documentation
- Clarify the isolated smoke-test coverage in README.md.
