# Quota Buddy

[中文说明](README.md) · [MIT License](LICENSE)

Quota Buddy is a small Windows utility that displays the remaining 5-hour and weekly Codex quota and available reset credits below the official Codex pet.

## Use

1. Open the Codex desktop app and its official pet.
2. Double-click `Start Quota Buddy-English.cmd`.
3. Drag the title area to move the panel, drag the lower-right corner to resize it, or right-click to refresh or exit.

The first run adds a Windows sign-in startup entry. The panel follows the pet and hides when the pet closes.

## Features

- Shows remaining quota, reset times, and available reset credits.
- Adapts its layout to the window width.
- Changes the indicator color and breathing speed as quota decreases.

The breathing indicator follows the lower of the two quotas: green at 50% or more, yellow at 21%–49%, red at 6%–20%, dark red at 5% or less, and gray when data is unavailable.

## Privacy

Quota Buddy only reads the Codex read-only quota service and local runtime records. It does not read, store, or transmit passwords, tokens, or login credentials, and it does not create logs.

## Self-test

Double-click `运行自检.cmd`. `全部通过 / All tests passed` means the app is working correctly.
