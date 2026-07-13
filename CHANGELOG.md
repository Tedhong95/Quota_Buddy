# Changelog

## 2026-07-13

- Updated the interface for the latest GPT quota rules by removing the discontinued 5-hour quota.
- Added the type and expiration date for every available reset credit.
- Changed the breathing-light color to follow the weekly remaining quota.
- Matched the weekly percentage and progress-bar colors to the breathing indicator.
- Added separate right-edge, bottom-edge, and corner resizing with content-safe minimum heights.
- Improved compact layouts to avoid duplicate reset-count text and unnecessary blank space.

## 2026-07-09

- Added support for the latest Codex rate-limit records (`usedPercent`/`resetsAt`), including escaped records stored in SQLite.
- Improved official quota reading for `rateLimitsByLimitId.codex` responses and merged WAL/main-database candidates before selecting the newest valid record.
- Tightened quota validation so old test text, chat transcripts, and unrealistic reset dates are not shown as real remaining quota.
- Added local diagnostics for hidden startup and quota-service failures.
- Fixed pet following so the panel uses Codex's recorded pet coordinates directly instead of relying on fragile window matching.
- Changed window visibility rules: Quota Buddy now shows while Codex is running, follows the pet when available, and stays at the last usable position when the pet is unavailable.
- Added window position persistence and virtual-desktop bounds checks so disconnected or additional monitors do not leave the panel off-screen.
- Fixed startup so Quota Buddy launches without leaving a visible terminal window.
- Added single-instance language switching: if one language version is already running, opening the other version switches to it instead of starting a second copy.
- Added self-tests for hidden startup, Chinese/English switching, fallback switching, UI creation, and quota parsing.
