# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s 应用图标" width="256" height="256">
</p>

<p align="center">
  <strong>macOS 上适用于会议、通话、直播和视频的实时双语字幕。</strong>
</p>

<p align="center">
  v2s 可以将麦克风输入或指定应用的音频转换成简洁的双行字幕条，让你在不离开当前屏幕的情况下，一边听原语言，一边看目标语言字幕。
</p>

<p align="center">
  <a href="README.md">English Doc</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7" alt="Mar-20-2026 11-08-59">
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/449039ee-c329-426e-a55b-ab6660c56ca7" alt="Screenshot 2026-03-25 at 1 10 39 PM" width="500">
</p>

## 功能特性

- **菜单栏常驻应用**：启动后常驻于 macOS 菜单栏，随时可打开和控制字幕。
- **双语字幕悬浮条**：第一行显示翻译结果，第二行显示原始语音文本，便于快速对照。
- **灵活的音频输入**：既可使用麦克风，也可只捕获某个正在运行的 macOS 应用音频。
- **本地语音转写**：基于 Apple Speech 框架进行语音识别。
- **本地翻译**：基于 Apple Translation 框架进行翻译处理。
- **AI 摘要**：基于 Apple Intelligence 对字幕记录进行智能摘要，快速掌握对话要点。
- **可调节的字幕样式**：支持调整悬浮条样式，保证字幕在真实工作场景中依然清晰可读。

## 隐私保护

- 无需账号，也没有云端后台、分析或遥测。
- 音频和字幕文本不会通过 v2s 离开你的 Mac。
- 翻译依赖 Apple 的本地 Translation 框架，部分语言包可能需要先在系统设置中下载。
- 语音识别依赖 Apple Speech 框架；某些语言环境下，如果未明确启用本地识别，可能会回退到 Apple 服务器。

## 快速开始

1. 从 [Releases](https://github.com/franklioxygen/v2s/releases) 页面下载最新的 `.app.zip`。
2. 解压后将 `v2s.app` 移动到 `Applications` 文件夹。
3. 启动 v2s，它会以图标形式出现在菜单栏中。
4. 选择输入源：麦克风或某个正在运行的应用。
5. 选择输入语言和字幕语言。
6. 点击 **Start**。

首次使用时，v2s 会请求以下权限：

- **Speech Recognition**：用于将音频转写为文本。
- **Microphone**：当输入源为麦克风时需要。
- **Audio Capture**：当输入源为其他应用时需要。

## 环境要求

- 翻译功能需要 macOS 26 或更高版本

## 从源码构建

```bash
git clone https://github.com/franklioxygen/v2s.git
cd v2s
open v2s.xcodeproj
```

也可以直接使用终端构建：

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build
```

## 许可证

MIT
