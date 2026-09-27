# Changelog

## Unreleased

### Fixed

- Read the resets-at field written by current Codex CLI logs (the previous reset-at key was never present, so waiting tasks did not resume).
- Anchor manual HH:mm reset times to their next occurrence instead of today midnight, fixing schedules that jumped forward about a day when a morning time was chosen in the evening.
- Check the five-hour rollover condition before advancing the time, instead of after.

### Changed

- Read child process output asynchronously from launch, preventing deadlocks when a resumed task prints more output than the pipe buffer holds.

### Added

- Per-task custom resume prompts: a top-panel input, right-click editing, prompt tooltips, and per-task persistence in queue.json.

## 0.1.0 — 2026-09-02

- Initial public Windows-only release.
- Chinese WinForms interface with English application branding.
- Automatic local reset detection and manual five-hour scheduling.
- Native `HH:mm` time picker and configurable safety buffer.
- Portable Desktop shortcut installer and uninstaller.
- Local-only state storage and Codex executable discovery.
