# v2s

`v2s` is a macOS menu bar app for turning live voice into bilingual subtitles.


![Screenshot 2026-03-17 at 1 29 49 PM](https://github.com/user-attachments/assets/d5f10b08-a4a2-463e-9c0c-ad18c5d890b0)


## What It Does

- Captures audio from a selected microphone or a selected macOS app
- Uses Apple Speech APIs for transcription
- Uses Apple Translation APIs for subtitle translation
- Shows a desktop-top subtitle bar with translated text on the first line and source text on the second line

## Current Status

This repository is in active MVP development.

Implemented so far:

- macOS menu bar app shell
- source picker for running apps and microphones
- subtitle overlay window
- live app-audio capture via Core Audio Process Tap
- speech recognition pipeline
- translation pipeline with queued caption display

Still in progress:

- more robust subtitle segmentation tuning
- broader app-source compatibility and diagnostics
- packaging and release workflow

## Project Structure

- `Sources/`: app source code
- `Config/`: app configuration files
- `docs/v2s-system-design.md`: system design
- `docs/v2s-mvp-plan.md`: MVP execution plan
- `v2s.xcodeproj`: Xcode project

## Requirements

- macOS 15 or newer
- Xcode 17 or newer
- Speech Recognition permission
- Audio capture permission when using app audio sources

## Run

Open the Xcode project:

```bash
open /Users/franklioxygen/Projects/v2s/v2s.xcodeproj
```

Or build from the terminal:

```bash
cd /Users/franklioxygen/Projects/v2s
swift build
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/v2s.app
```

## Documents

- [System Design](docs/v2s-system-design.md)
- [MVP Plan](docs/v2s-mvp-plan.md)
