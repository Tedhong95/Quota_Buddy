# Changelog

## 2026-07-09

- Changed window visibility rules: Quota Buddy now shows while Codex is running, follows the pet when available, and stays at the last usable position when the pet is unavailable.
- Added window position persistence and virtual-desktop bounds checks so disconnected or additional monitors do not leave the panel off-screen.
- Fixed startup so Quota Buddy launches without leaving a visible terminal window.
- Added single-instance language switching: if one language version is already running, opening the other version switches to it instead of starting a second copy.
- Added self-tests for hidden startup, Chinese/English switching, fallback switching, UI creation, and quota parsing.
