# Changelog

## 0.2.0 — 2026-09-27

### Fixed

- Read the resets-at field written by current Codex CLI logs (the previous reset-at key was never present, so waiting tasks did not resume).
- Anchor manual HH:mm reset times to their next occurrence instead of today midnight, fixing schedules that jumped forward about a day when a morning time was chosen in the evening.
- Check the five-hour rollover condition before advancing the time, instead of after.
- Keep the original session UUID immutable and refuse to start if the ID or workspace is missing.
- Detect a five-hour reset only from the selected session and require a matching explicit limit-failure event; ignore ordinary token-count usage telemetry and weekly windows.
- Resume an occupied session with bounded 15/30/60-second backoff after Codex explicitly rejects it with `active writer`; never terminate a shared Codex process.
- Migrate interrupted version-2 runs to a reconciliation state instead of automatically submitting the same prompt again.
- Classify authentication, network, limit, identity, and ownership failures; pause when a result is uncertain and provide an explicit, warned retry action.
- Persist complete per-attempt output logs locally and show the failure category, exit code, original thread ID, and log path in task details.
- Prevent multiple scheduler instances for the same Windows user from racing on the queue file.
- Migrate queue state to schema version 3 while preserving legacy prompts and task IDs.
- Pin the Codex executable and Codex Home per monitored task so a later retry does not silently switch to a different session store.
- Add isolated PowerShell 5.1 tests for limit detection, migration, argument quoting, writer-conflict backoff, and same-thread resume.

### Changed

- Read child process output asynchronously from launch, preventing deadlocks when a resumed task prints more output than the pipe buffer holds.
- Use the structured reset result's `ResetAt` value consistently on repeated limit failures.
- Keep the scheduler timer alive when one polling pass throws, and show actionable error details instead of stopping all monitoring.

### Added

- Per-task custom resume prompts: a top-panel input, right-click editing, prompt tooltips, and per-task persistence in queue.json.
- Add an error-details view and an explicit “verify then retry original session” action for outcomes that cannot be safely retried automatically.
- Add a dedicated “waiting for original session release” state and visible retry countdown.
- Add a bundled `QueueCore.ps1` with side-effect-free queue, error classification, reset scanner, and resume argument functions.

### Known limitation

- Codex does not expose a verified control endpoint for every desktop or IDE process that may hold a thread open. If another host retains the original thread, this release waits and retries; the user may need to release that thread in its host. The scheduler does not kill the shared host. A live end-to-end run against a real user thread was not performed as part of release validation; the runner integration was verified with an isolated fake Codex executable.

## 0.1.0 — 2026-09-02

- Initial public Windows-only release.
- Chinese WinForms interface with English application branding.
- Automatic local reset detection and manual five-hour scheduling.
- Native `HH:mm` time picker and configurable safety buffer.
- Portable Desktop shortcut installer and uninstaller.
- Local-only state storage and Codex executable discovery.
