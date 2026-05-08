# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s 应用图标" width="256" height="256">
</p>

<p align="center">
  <strong>macOS 私密面试助手与实时双语字幕悬浮层。</strong>
</p>

<p align="center">
  v2s 面向面试、会议、通话、直播和视频场景，提供双语字幕、多输入源捕获，以及可选 GPT 助手。用户主动点击 Follow Up 或 Ask 时，它可以结合历史对话、时间线、屏幕 OCR 和当前屏幕上下文给出回复。
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
- **多输入源捕获**：可同时选择多个麦克风或正在运行的 macOS 应用作为输入源。
- **分输入源语言设置**：不同输入源可分别选择语音识别语言，适合双语或混合语言对话。
- **本地语音转写**：基于 Apple SpeechAnalyzer 进行语音识别。
- **本地翻译**：基于 Apple Translation 框架进行翻译处理。
- **AI 摘要**：基于 Apple Intelligence 对字幕记录进行智能摘要，快速掌握对话要点。
- **GPT 面试助手**：支持 Follow Up、Ask、快捷键、Skills 提示词、API Key、模型和 API Base URL 自定义。
- **屏幕上下文**：可调用 macOS 截图和 Vision OCR，将当前屏幕截图与 OCR 文本一起传给 GPT；当 API 不支持图像时自动降级为文字和 OCR。
- **字幕 / GPT 回复双界面**：两个界面都支持滚动查看上下文，并可通过快捷键切换。
- **隐私模式**：字幕、GPT 回复和设置窗口可在截图、录屏、屏幕共享中隐藏。
- **单实例守卫**：重复打开 v2s 会自动唤醒已有窗口；如果旧实例无响应，则结束旧实例后重新启动。
- **可调节的字幕样式**：支持调整悬浮条样式，保证字幕在真实工作场景中依然清晰可读。

## 输入语言

v2s 的输入语言列表仅包含 Apple SpeechAnalyzer/SpeechTranscriber 路径支持的语言。界面不会暴露地区变体；v2s 会为每种语言选择一个默认支持地区。

支持的输入语言：粤语、简体中文、英语、法语、德语、意大利语、日语、韩语、葡萄牙语和西班牙语。

## 隐私保护

- 没有内置账号、云端后台、分析或遥测。
- 语音识别和翻译主要通过 Apple 系统框架完成。
- 翻译依赖 Apple 的本地 Translation 框架，部分语言包可能需要先在系统设置中下载。
- 语音识别依赖 Apple 的本地 SpeechAnalyzer/SpeechTranscriber 资源，并仅面向上方列出的输入语言。
- GPT 功能是可选且由用户配置的。点击 Follow Up 或 Ask 时，v2s 会把历史字幕、时间戳、对话 / 输入源名称、Skills 提示词、OCR 文本，以及在权限和模型支持时的当前屏幕截图发送到你配置的 API 地址。
- 如果没有屏幕录制权限，或当前 API / 模型拒绝图像输入，v2s 会自动降级为文字和 OCR 上下文，并在 GPT 回复界面显示红色状态提示。

## 快速开始

1. 从 [Releases](https://github.com/franklioxygen/v2s/releases) 页面下载最新的 `.app.zip`。
2. 解压后将 `v2s.app` 移动到 `Applications` 文件夹。
3. 启动 v2s，它会以图标形式出现在菜单栏中。
4. 选择输入源：麦克风或某个正在运行的应用。
5. 选择输入语言和字幕语言。
6. 点击 **Start**。
7. 可选：配置 GPT API、Skills 和快捷键，用于面试辅助和追问。

首次使用时，v2s 会请求以下权限：

- **Speech Recognition**：用于将音频转写为文本。
- **Microphone**：当输入源为麦克风时需要。
- **Audio Capture**：当输入源为其他应用时需要。
- **Screen Capture**：仅在你要求 GPT 使用当前屏幕上下文时需要。

如果 macOS 提示“Apple 无法验证‘v2s’是否包含可能危害 Mac 安全或泄漏隐私的恶意软件”，请先确认应用来自可信发布源，然后移除隔离属性：

```bash
sudo xattr -dr com.apple.quarantine /Applications/v2s.app
```

## 环境要求

- 语音转写和翻译功能需要 macOS 26 或更高版本

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
