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

![Mar-20-2026 11-08-59](https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7)

## 功能特性

- **菜单栏常驻应用**：启动后常驻于 macOS 菜单栏，随时可打开和控制字幕。
- **双语字幕悬浮条**：第一行显示翻译结果，第二行显示原始语音文本，便于快速对照。
- **灵活的音频输入**：既可使用麦克风，也可只捕获某个正在运行的 macOS 应用音频。
- **本地语音转写**：基于 Apple Speech 框架进行语音识别。
- **本地翻译**：基于 Apple Translation 框架进行翻译处理。
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

若系统提示无法验证开发者，可对 `v2s.app` **右键 → 打开 → 打开**，或在 **系统设置 → 隐私与安全性** 中放行。

首次使用时，v2s 会请求以下权限：

- **Speech Recognition**：用于将音频转写为文本。
- **Microphone**：当输入源为麦克风时需要。
- **Audio Capture**：当输入源为其他应用时需要。

## 环境要求

- **运行系统：** macOS **15** 或更高（与 Xcode 工程中的部署版本一致）。
- **翻译：** 当前使用的 Apple Translation 相关能力在 **macOS 26** 或更高版本上更完整；更低版本上翻译相关功能可能受限或不可用。
- **语音：** 在 **macOS 26+** 且使用 **macOS 26 SDK** 构建并关闭下文中的 legacy 开关时，可使用较新的流式语音能力；在更早的系统上，转写会使用经典的本地语音识别（`SFSpeechRecognizer`）。

## 从源码构建

需安装完整 **Xcode**（仅从 Mac App Store 安装「Command Line Tools」不足以构建本工程）。首次打开 Xcode 并完成附加组件安装。

```bash
git clone https://github.com/franklioxygen/v2s.git
cd v2s
open v2s.xcodeproj
```

在 Xcode 中选择 **v2s** 方案与 **My Mac**，使用 **运行** 或 **归档** 即可。

**默认编译方式（Xcode 16 / macOS 15 SDK）：** 工程里启用了 **`V2S_LEGACY_SPEECH_ONLY`**，用于在旧版 SDK 下跳过仅存在于 **macOS 26 SDK** 的 API，从而正常编译。运行时语音转写走 **兼容路径**，与在仅支持新 API 的系统上因不可用而回退的行为一致。

**如需启用 macOS 26 上的新版语音 API：** 安装带 **macOS 26 SDK** 的 Xcode 后，在 **编译设置 → Swift Compiler – Custom Flags → Active Compilation Conditions** 中，从 Debug / Release **移除 `V2S_LEGACY_SPEECH_ONLY`**（Debug 配置请保留 **`DEBUG`**）。

命令行示例：

```bash
# Debug
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug \
  -destination 'platform=macOS' build

# Release（从 DerivedData 产物路径打开 .app，或使用 -derivedDataPath 固定目录）
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Release \
  -destination 'platform=macOS' -derivedDataPath ./.build/release build
open ./.build/release/Build/Products/Release/v2s.app
```

打包成与 Release 类似的 zip：

```bash
ditto -c -k --keepParent ./.build/release/Build/Products/Release/v2s.app ./dist/v2s.app.zip
```

自动化升版本号、打标签并发布 GitHub Release 可参见 **`scripts/release.sh`**。

## 许可证

MIT
