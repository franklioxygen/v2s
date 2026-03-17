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

![v2s screenshot](https://github.com/user-attachments/assets/d5f10b08-a4a2-463e-9c0c-ad18c5d890b0)

## Why v2s

- Follow live conversations with translated subtitles pinned at the top of your screen.
- Capture from your microphone or from a specific macOS app instead of your entire system mix.
- Keep the original speech and the translated line visible together for fast context switching.
- Stay in a lightweight menu bar workflow instead of juggling browser tabs or full-screen caption apps.

## Standout Features

- Menu bar app built for always-available subtitle access.
- Live subtitle overlay with translated text on the first line and source text on the second.
- Audio source selection for microphones and running macOS apps.
- Apple Speech transcription pipeline for live recognition.
- Apple Translation pipeline for bilingual subtitle output.
- Overlay styling controls so the subtitle bar stays readable on top of real work.

## Privacy & Connectivity

- No v2s account, cloud backend, analytics SDK, or custom telemetry is built into this repository.
- This codebase does not send captured audio or subtitle text to any v2s-operated server, because there is no v2s server in the product flow.
- Translation uses Apple's system Translation framework and local language assets on the Mac when available; some language assets may need to be downloaded first.
- Internet is not required to contact any v2s service.
- Full offline operation is not guaranteed for every language or device in the current implementation:
- Apple documents that some Speech framework recognition paths depend on Apple servers unless on-device recognition is explicitly required.
- The current speech pipeline uses `SFSpeechRecognizer` but does not set `requiresOnDeviceRecognition = true`, so speech recognition may still depend on Apple's service for some locales.

## What You Can Use Today

- Launch v2s as a macOS menu bar app.
- Pick a microphone or a supported app audio source.
- Start a live transcription session.
- See translated subtitles appear in a floating desktop overlay.
- Adjust overlay appearance from settings.

## In Progress

- Better subtitle segmentation and pacing.
- Wider app-audio compatibility and diagnostics.
- Release CI automation and credential setup.
- Polished onboarding and production install docs.

## Requirements

- macOS 15 or newer
- Xcode 17 or newer
- Speech Recognition permission
- Audio capture permission when using app audio sources

## Run Locally

Open the Xcode project:

```bash
open /Users/franklioxygen/Projects/v2s/v2s.xcodeproj
```

Build from the terminal:

```bash
cd /Users/franklioxygen/Projects/v2s
swift build
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/v2s.app
```

## Release

Create a GitHub release with an auto-bumped version and a versioned installer package:

```bash
cd /Users/franklioxygen/Projects/v2s
./scripts/release.sh
```

Optional bumps:

```bash
./scripts/release.sh patch
./scripts/release.sh minor
./scripts/release.sh major
./scripts/release.sh 1.2.0
```

The release script:

- requires a clean `main` worktree
- bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `v2s.xcodeproj/project.pbxproj`
- builds the Release app
- signs the app with `Developer ID Application`
- creates a signed installer package with `Developer ID Installer`
- notarizes the package with Apple and staples the notarization ticket
- creates `dist/v2s-<version>.pkg` and `dist/v2s-<version>.sha256`
- commits the version bump, tags `v<version>`, pushes to GitHub, and creates a GitHub release with both assets attached

Requirements:

- authenticated GitHub CLI: `gh auth login`
- a buildable project state
- installed `Developer ID Application` and `Developer ID Installer` certificates in your keychain
- notarization credentials via one of:
- `NOTARYTOOL_KEYCHAIN_PROFILE` from `xcrun notarytool store-credentials`
- `NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_TEAM_ID`, and `NOTARYTOOL_APP_PASSWORD`
- `NOTARYTOOL_KEY_PATH` and `NOTARYTOOL_KEY_ID`, plus `NOTARYTOOL_ISSUER` when required

Example with a keychain profile:

```bash
export APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export PKG_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
export NOTARYTOOL_KEYCHAIN_PROFILE="AC_NOTARY"
./scripts/release.sh
```

## Documents

- [System Design](docs/v2s-system-design.md)
- [MVP Plan](docs/v2s-mvp-plan.md)
