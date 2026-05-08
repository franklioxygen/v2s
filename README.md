# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s app icon" width="256" height="256">
</p>

<p align="center">
  <strong>Private interview assistant and bilingual live subtitle overlay for macOS.</strong>
</p>

<p align="center">
  v2s helps you follow interviews, meetings, calls, streams, and videos with bilingual subtitles,
  multi-source audio capture, and an optional GPT assistant that can use transcript history,
  screen OCR, and current-screen context when you explicitly ask for help.
</p>

<p align="center">
  <a href="README.zh-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7" alt="Mar-20-2026 11-08-59">
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/449039ee-c329-426e-a55b-ab6660c56ca7" alt="Screenshot 2026-03-25 at 1 10 39 PM" width="500">
</p>

## Why v2s

- Use a discreet macOS overlay to keep interview or meeting context visible while staying in your current app.
- Follow live conversations with bilingual subtitles, including original and translated text.
- Capture from one or more microphones and running macOS apps instead of your entire system mix.
- Ask GPT for a follow-up, explanation, or likely answer using the conversation history and visible screen context.
- Keep a lightweight menu bar workflow instead of juggling browser tabs or full-screen caption apps.

## Features

- Menu bar app built for always-available subtitle access.
- Live subtitle overlay with translated text on the first line and source text on the second.
- Multi-source audio capture for microphones and running macOS apps.
- Per-source language selection for bilingual or mixed-language conversations.
- On-device speech transcription powered by Apple Speech.
- On-device translation powered by Apple Translation.
- Transcript summarization powered by Apple Intelligence for quick overview of conversations.
- GPT interview assistant with Follow Up and Ask actions, global hotkeys, configurable model, API key, and API base URL.
- Screen context support through macOS screenshot capture plus Vision OCR; text-only fallback is used when a provider rejects images.
- Scrollable subtitle and GPT reply modes with a hotkey to switch between them.
- Privacy mode for the overlay and settings windows so they can be hidden from screenshots, screen recording, and screen sharing.
- Single-instance launch guard: opening v2s again wakes the existing window, or restarts it if the old instance is unresponsive.
- Overlay styling controls so the subtitle bar stays readable on top of real work.

## Privacy

- No built-in account, cloud backend, analytics, or telemetry.
- Audio transcription and translation are handled through Apple's system frameworks.
- Translation uses Apple's on-device Translation framework. Some language packs may need to be downloaded first through System Settings.
- Speech recognition uses Apple's on-device Speech framework. Some locales may fall back to Apple's servers unless on-device recognition is explicitly configured.
- GPT features are optional and user configured. When you press Follow Up or Ask, v2s sends the prior transcript, timestamps, conversation/source name, skills prompt, OCR text, and, when available and supported by the provider, a current-screen screenshot to your configured API endpoint.
- If screen capture permission is missing or the selected API/model does not support images, v2s falls back to text and OCR context and shows an in-overlay warning indicator.

## Getting Started

1. Download the latest `.app.zip` from [Releases](https://github.com/NX-lite/v2s/releases).
2. Unzip and move `v2s.app` to your Applications folder.
3. Launch v2s — it appears as an icon in your menu bar.
4. Select an input source (a running app or microphone).
5. Choose your input and subtitle languages.
6. Click **Start**.
7. Optional: configure GPT API settings, skills, and hotkeys for interview assistance.

v2s will ask for permissions on first use:

- **Speech Recognition** — to transcribe audio into text.
- **Microphone** — when using a microphone as the input source.
- **Audio Capture** — when capturing audio from another app.
- **Screen Capture** — only when you ask GPT to use visible screen context.

If macOS shows "Apple could not verify 'v2s' is free of malware that may harm your Mac or compromise your privacy", make sure the app came from a trusted release, then remove the quarantine attribute:

```bash
sudo xattr -dr com.apple.quarantine /Applications/v2s.app
```

## Requirements

- Translation requires macOS 26 or newer

## Building from Source

```bash
git clone https://github.com/NX-lite/v2s.git
cd v2s
open v2s.xcodeproj
```

Or from the terminal:

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build
```

## License

MIT
