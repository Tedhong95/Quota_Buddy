# Changelog

## v2.0.0 - 2026-11-25

- Added a soft quota-colored halo with corrected glow bounds and four instant breathing choices (off by default), using a 50%–100% opacity range.
- Added categorized named color collections with HEX values, swatches, selected-state indicators and custom color entry.
- Refined centered reset details, proportional typography and the borderless rounded detail panel.
- Included the desktop promotional video with the release.

- Replaced the rectangular panel with a smaller circular-quota and rounded-detail layout while preserving both quotas, reset times, and reset-credit details.
- Matched the circular border and breathing glow to the 5-hour quota status color.
- Added automatic hiding at all four display edges; moving the pointer back to the narrow visible edge restores the panel for dragging.
- Preserved pet following, custom colors, multilingual display, resizing, topmost behavior, and multi-monitor positioning.

## v1.0.0 - 2026-08-28

- Restored the current 5-hour and weekly quota display confirmed by the latest ChatGPT desktop usage rules.
- Added separate progress bars, remaining percentages, reset times, and responsive compact layouts for both quota windows.
- Changed the breathing indicator to follow the 5-hour remaining quota while each quota row keeps its own status color.
- Simplified reset-credit labels by removing redundant `(weekly+5hr)` suffixes while preserving the full expiration time.

## v0.4.0 - 2026-08-03

- Added panel color presets based on the requested RGB palette, plus black, a native color picker, direct HEX input, automatic high-contrast text, and one-click default restoration.
- Added a persistent right-click pet-follow toggle.
- Updated compatibility for the unified ChatGPT desktop app and weekly-only quota responses.
- Improved startup responsiveness by showing the panel before quota refreshes and reusing the desktop client's quota helper.
- Fixed custom-color dialog crashes and retained compact responsive layouts across all themes.
- Improved pet following across Store and direct-download clients, fresh installations, multiple displays, different DPI settings, and non-standard pet sizes by using the active pet anchor and actual dimensions.
- Expanded self-tests for themes, HEX colors, the custom-color dialog, unified-client quota data, and multiple pet-state formats and sizes.

## v0.3.0 - 2026-07-15

- Improved responsive typography so text and status elements scale continuously with the panel width while the layout remains compact.
- Aligned reset-credit types and expiration dates into stable left/right columns; narrow layouts omit the expiration label to prevent clipping.
- Centered the available-reset summary in compact and medium layouts and reserved space for the resize grip.
- Added per-monitor DPI awareness for sharper text on displays using 125%, 150%, or mixed scaling.
- Reduced pet-follow jitter with faster position updates, sub-pixel filtering, shared-file retries, and cached pet-state reads.
- Improved topmost refresh behavior so the transparent panel remains visible above application windows.
- Made the most recently launched old/new or Chinese/English entry replace any previously running Quota Buddy instance.
- Updated self-tests to use current relative reset times instead of dates that eventually expire.

## v0.2.1 - 2026-07-13

- Fixed pet alignment on computers using non-100% display scaling by using the desktop coordinates directly.
- Changed the no-pet default position to the lower-right corner of the primary screen without saving pet-following coordinates as a normal placement.

## v0.2.0 - 2026-07-13

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
