# Vinyl

A tiny, draggable vinyl record for Spotify on your Mac.

Your album art sits at the center. The record spins while music plays. Hover to reveal your track and playback controls; move away and it becomes just a record again.

<p align="center">
  <img src="docs/vinyl-idle.png" width="276" alt="Vinyl record at rest">
  <img src="docs/vinyl-hover.png" width="276" alt="Playback controls appear on hover">
</p>

[Download for Apple Silicon](https://github.com/jeff960149-rgb/spotify-vinyl/releases/latest) · [繁體中文](README.zh-TW.md)

## Features

- Floating, transparent desktop record with live Spotify album artwork.
- Smooth rotation during playback; pauses at its current angle.
- Previous, play/pause and next controls on hover.
- Drag the outer grooves to move it. Position and size are remembered.
- Three sizes, with readable track text even on the smallest record.
- Optional mode that shows the record when Spotify has no main window on the current desktop, including when minimized or hidden.
- Menu bar and right-click menus for visibility, size, position and quitting.
- Respects the macOS Reduce Motion setting.

## Install

Requires **macOS 14 or later**, an **Apple Silicon Mac** for the downloadable binary, and the **Spotify desktop app**. Tested on Apple Silicon with macOS 26.6.2. The interface is currently in Traditional Chinese.

1. Download `Vinyl-macOS-arm64.zip` from [Releases](https://github.com/jeff960149-rgb/spotify-vinyl/releases/latest).
2. Unzip, move `Vinyl.app` to Applications, then open it.
3. Allow Vinyl to control Spotify when macOS asks.
4. Play a song in Spotify. Hover over the record to control playback.

This early release is ad-hoc signed, **not Apple-notarized**. macOS may block the first launch. If you choose to trust this build, follow [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-hk/102445). You can also inspect and compile the source yourself.

Use the record icon in the menu bar or right-click the record:

| Menu item | Meaning |
| --- | --- |
| 顯示唱片 / 隱藏唱片 | Show / hide |
| Spotify 收起後才顯示 | Show when Spotify has no main window on the current desktop |
| 開啟 Spotify | Open Spotify |
| 小唱片 / 中唱片 / 大唱片 | Small / medium / large |
| 重設位置 | Reset position and show the record |
| 自動化權限設定… | Open Automation settings |
| 結束 Vinyl | Quit |

The record stays visible by default. Automatic visibility is based on window presence, not simply which app is focused. Spotify continues playing the audio; Vinyl is a separate controller.

## Build from source

Install Apple's Command Line Tools, then:

```sh
git clone https://github.com/jeff960149-rgb/spotify-vinyl.git
cd spotify-vinyl
./scripts/build.sh
open build/Vinyl.app
```

The script compiles for your Mac's architecture using the selected Xcode/Command Line Tools SDK. There are no third-party dependencies. `VINYL_SDK` can select a matching SDK if your compiler and default SDK differ; `VINYL_ARCH` accepts `arm64` or `x86_64`. Intel builds are not runtime-tested.

Run the visual smoke check in a logged-in macOS desktop session:

```sh
./scripts/smoke-test.sh
```

It renders the idle/hover states and checks hover state, resizing and recovery from off-screen placement. It uses placeholder artwork, makes no Spotify requests, and does not save window preferences. Spotify playback and automatic visibility still need manual verification with a running Spotify app.

## Permissions and data

Vinyl reads track metadata and sends playback commands using Spotify's local AppleScript interface. macOS Automation permission for Spotify is required. Artwork is fetched over HTTPS from the URL supplied by Spotify. There is no separate account, API key, analytics service or developer server. Position, size and visibility preferences stay in local macOS preferences.

## Current limits

- Spotify desktop only; no web player, mobile or Windows support.
- Album art falls back to the built-in label if no artwork is available.
- Automatic visibility uses a main-window size heuristic and may need refinement for future Spotify window layouts.
- No automatic updates or launch-at-login setting.
- Preview images use original placeholder artwork, not an included music catalog.

Vinyl is an independent project and is not affiliated with Spotify.
