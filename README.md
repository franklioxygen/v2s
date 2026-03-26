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

<p align="center">
  <a href="README.zh-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7" alt="Mar-20-2026 11-08-59">
</p>

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

1. Download the latest `.app.zip` from [Releases](https://github.com/franklioxygen/v2s/releases).
2. Unzip and move `v2s.app` to your Applications folder.
3. Launch v2s — it appears as an icon in your menu bar.
4. Select an input source (a running app or microphone).
5. Choose your input and subtitle languages.
6. Click **Start**.

If macOS says the app cannot be verified, **right-click** `v2s.app` → **Open** → **Open**, or allow it under **System Settings → Privacy & Security**.

v2s will ask for permissions on first use:

- **Speech Recognition** — to transcribe audio into text.
- **Microphone** — when using a microphone as the input source.
- **Audio Capture** — when capturing audio from another app.

## Requirements

- **Runtime:** macOS **15** or newer (see deployment target in the Xcode project).
- **Translation:** Apple’s Translation APIs used by v2s require **macOS 26** or newer for full functionality; on older systems, translation-related features may be limited or unavailable.
- **Speech:** On macOS 26+, the app can use Apple’s newer streaming speech APIs when built with a **macOS 26 SDK** (see *Building from Source*). On earlier macOS versions, transcription uses the classic on-device speech stack (`SFSpeechRecognizer`).

## Building from Source

Install the full **Xcode** app from the Mac App Store (Command Line Tools alone are not enough). Open the project once to finish additional components if prompted.

```bash
git clone https://github.com/franklioxygen/v2s.git
cd v2s
open v2s.xcodeproj
```

Select the **v2s** scheme and **My Mac**, then **Product → Run** or **Archive** as needed.

**Default compile mode (Xcode 16 / macOS 15 SDK):** the target defines **`V2S_LEGACY_SPEECH_ONLY`**, which omits APIs that only exist in the macOS 26 SDK so the app builds on older toolchains. Speech recognition then uses the **legacy** path at runtime, which matches how the app already behaves when newer APIs are unavailable.

**Enabling macOS 26 speech APIs:** install **Xcode with the macOS 26 SDK**, then in **Build Settings → Swift Compiler – Custom Flags → Active Compilation Conditions** remove **`V2S_LEGACY_SPEECH_ONLY`** from both Debug and Release (keep **`DEBUG`** in Debug).

Terminal examples:

```bash
# Debug
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug \
  -destination 'platform=macOS' build

# Release (install the .app from the reported DerivedData path, or use -derivedDataPath)
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Release \
  -destination 'platform=macOS' -derivedDataPath ./.build/release build
open ./.build/release/Build/Products/Release/v2s.app
```

To ship a zip like the GitHub releases:

```bash
ditto -c -k --keepParent ./.build/release/Build/Products/Release/v2s.app ./dist/v2s.app.zip
```

For automated version bumps, Git tags, and GitHub releases, see **`scripts/release.sh`**.

## License

MIT
