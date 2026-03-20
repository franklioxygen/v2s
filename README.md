# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s app icon" width="256" height="256">
</p>

<p align="center">
  <strong>Live bilingual subtitles for meetings, calls, streams, and videos on macOS.</strong>
</p>

<p align="center">
  v2s turns microphone input or app audio into a clean two-line subtitle bar so you can follow speech in one language and read it in another without leaving the screen you are already using.
</p>

![Mar-20-2026 11-08-59](https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7)


## Why v2s

- Follow live conversations with translated subtitles pinned at the top of your screen.
- Capture from your microphone or from a specific macOS app instead of your entire system mix.
- Keep the original speech and the translated line visible together for fast context switching.
- Stay in a lightweight menu bar workflow instead of juggling browser tabs or full-screen caption apps.

## Features

- Menu bar app built for always-available subtitle access.
- Live subtitle overlay with translated text on the first line and source text on the second.
- Audio source selection for microphones and running macOS apps.
- On-device speech transcription powered by Apple Speech.
- On-device translation powered by Apple Translation.
- Overlay styling controls so the subtitle bar stays readable on top of real work.

## Privacy

- No account, cloud backend, analytics, or telemetry.
- Audio and subtitle text never leave your Mac through v2s.
- Translation uses Apple's on-device Translation framework. Some language packs may need to be downloaded first through System Settings.
- Speech recognition uses Apple's on-device Speech framework. Some locales may fall back to Apple's servers unless on-device recognition is explicitly configured.

## Getting Started

1. Download the latest `.app.zip` from [Releases](https://github.com/user/v2s/releases).
2. Unzip and move `v2s.app` to your Applications folder.
3. Launch v2s — it appears as an icon in your menu bar.
4. Select an input source (a running app or microphone).
5. Choose your input and subtitle languages.
6. Click **Start**.

v2s will ask for permissions on first use:

- **Speech Recognition** — to transcribe audio into text.
- **Microphone** — when using a microphone as the input source.
- **Audio Capture** — when capturing audio from another app.

## Requirements

- macOS 15 or newer
- Translation requires macOS 26 or newer

## Building from Source

```bash
git clone https://github.com/user/v2s.git
cd v2s
open v2s.xcodeproj
```

Or from the terminal:

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build
```

## License

MIT
