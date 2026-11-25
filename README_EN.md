# Quota Buddy

[中文说明](README.md) · [MIT License](LICENSE)

Current release: **v2.0.0**, featuring a quota-colored halo, instant breathing modes, categorized color collections, and edge auto-hide.

[Desktop promotional video](promo/Quota_Buddy_Desktop_1125.mp4) · [Latest release](https://github.com/Tedhong95/Quota_Buddy/releases/latest)

Quota Buddy is a small Windows utility that displays the remaining 5-hour and weekly Codex quotas, available reset credits, reset types, and expiration dates below the official Codex pet.

## Use

Supports Windows 10/11 and requires the latest signed-in GPT/Codex desktop client. No administrator access or extra runtime installation is required.

1. Download and extract the complete project folder to a fixed location.
2. Open the GPT/Codex desktop client.
3. Double-click `Start Quota Buddy-English.cmd`.
4. Hold and drag the panel to move it; drag the right edge or lower-right corner to resize it. Moving it to any display edge hides it automatically; move the pointer over the narrow visible edge to reveal and drag it again. Right-click to toggle pet following, choose or enter a panel color, restore the default color, refresh, or exit.

The first run adds a Windows sign-in startup entry. The panel stays directly below and follows the pet while it is open; when no pet is available, it defaults to the lower-right corner of the primary screen.

## Features

- Shows both quotas in the circular area and keeps reset times, reset-credit types, and expiration times in the compact detail area.
- Auto-hides at the top, bottom, left, or right display edge and reveals when the pointer returns.
- Adapts its layout to the window width.
- Automatically tightens its height to prevent cropped content and unnecessary blank space.
- Supports color presets, black, the system color picker, and direct HEX entry while maintaining readable text contrast.
- Lets you enable or disable pet following from the right-click menu.
- Changes the indicator color and breathing speed as quota decreases.

The breathing indicator follows the 5-hour quota: green at 50% or more, yellow at 21%–49%, red at 6%–20%, dark red at 5% or less, and gray when data is unavailable. Each quota row uses the same thresholds based on its own remaining quota.

## Privacy

Quota Buddy only reads the Codex read-only quota service and local runtime records. It does not read, store, or transmit passwords, tokens, or login credentials. If quota reading or startup fails, it stores a local diagnostic record without login credentials in the `.codex` folder.

## Self-test

Double-click `运行自检.cmd`. `全部通过 / All tests passed` means the app is working correctly.
