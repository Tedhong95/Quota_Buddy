# Quota Buddy

[中文说明](README.md) · [MIT License](LICENSE)

Quota Buddy is a small Windows utility that displays the remaining weekly Codex quota, available reset credits, reset types, and expiration dates below the official Codex pet.

## Use

Supports Windows 10/11 and requires the latest signed-in GPT/Codex desktop client. No administrator access or extra runtime installation is required.

1. Download and extract the complete project folder to a fixed location.
2. Open the GPT/Codex desktop client.
3. Double-click `Start Quota Buddy-English.cmd`.
4. Drag the title area to move the panel, or drag the right edge or lower-right corner to change its width. After resizing stops, the height automatically tightens to fit all content without blank space. Right-click to refresh or exit.

The first run adds a Windows sign-in startup entry. The panel stays directly below and follows the pet while it is open; when no pet is available, it defaults to the lower-right corner of the primary screen.

## Features

- Shows the weekly quota, reset time, and each available reset credit's type and expiration date.
- Adapts its layout to the window width.
- Automatically tightens its height to prevent cropped content and unnecessary blank space.
- Changes the indicator color and breathing speed as quota decreases.

The breathing indicator follows the weekly quota: green at 50% or more, yellow at 21%–49%, red at 6%–20%, dark red at 5% or less, and gray when data is unavailable.

## Privacy

Quota Buddy only reads the Codex read-only quota service and local runtime records. It does not read, store, or transmit passwords, tokens, or login credentials. If quota reading or startup fails, it stores a local diagnostic record without login credentials in the `.codex` folder.

## Self-test

Double-click `运行自检.cmd`. `全部通过 / All tests passed` means the app is working correctly.
