# 审查意见归档（2026-04-05）

本文归档本次 20 条审查意见及核对结论。结论分为三类：

- `属实`：问题与当前代码一致，建议按缺陷处理。
- `部分属实`：观察点成立，但原结论有前提、表述偏重，或影响范围被放大。
- `不属实`：当前代码或当前 SDK/运行时下，原结论不成立。

补充说明：

- 结论基于当前工作区代码核对。
- 附加做了本地验证，包括 `swift build`、Swift 6 严格并发构建、`NSColor` 颜色空间最小复现、`NSWindowController(window:)` 最小复现。

## 结论总览

| 编号 | 结论 | 修复状态 | 摘要 |
| --- | --- | --- | --- |
| 1 | 属实 | `[x]` | `LiveTranscriptionSession` 存在跨线程共享可变状态且未统一同步。 |
| 2 | 属实 | `[x]` | `OverlayColor` 的 fallback 可能因颜色空间不兼容而崩溃。 |
| 3 | 不属实 | `不适用` | `NSWindowController(window:)` 已将窗口设为 `isReleasedWhenClosed = false`。 |
| 4 | 属实 | `[x]` | `PopoverOutsideClickMonitor` 缺少 `deinit` 清理。 |
| 5 | 不属实 | `不适用` | 指定行位的 `group.addTask` 不是当前 Swift 6 并发报错点。 |
| 6 | 部分属实 | `[x]` | 固定按 5 秒计算会低估早期窗口值，但也符合当前注释语义。 |
| 7 | 属实 | `[x]` | `EntityCache` 在已锁定后仍覆盖翻译。 |
| 8 | 属实 | `[x]` | glossary 重叠词条的替换结果依赖字典迭代顺序。 |
| 9 | 属实 | `[x]` | VAD 推理错误被吞掉。 |
| 10 | 属实 | `[x]` | 摘要任务未保存、未取消，会并发写状态。 |
| 11 | 属实 | `[x]` | `silenceMs` 未使用，相关方法成为死代码。 |
| 12 | 部分属实 | `[x]` | 写法保守性不足，但“必然 fatal”表述偏重。 |
| 13 | 属实 | `[x]` | `footerBar` 未被引用。 |
| 14 | 属实 | `[x]` | `SettingsView` 初始化时被创建两次。 |
| 15 | 属实 | `[x]` | `SettingsStore.load()` 解码失败时静默回退默认值。 |
| 16 | 不属实 | `不适用` | 该 API 不是“macOS 14+ 已弃用”，而是未来版本将弃用。 |
| 17 | 属实 | `[x]` | `draftLengthFitScore` 逻辑重复。 |
| 18 | 不属实 | `不适用` | 当前调用链没有把 no-copy 缓冲异步逃逸出去。 |
| 19 | 部分属实 | `[ ]` | 8 次偏移描边确实更重，但是否已成性能问题需 profile。 |
| 20 | 部分属实 | `[x]` | 现已改为远离 overlay 低频探测、接近时再切回 30 FPS。 |

## 逐条归档

### 1. LiveTranscriptionSession 数据竞争

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/LiveTranscriptionSession.swift:60`，`Sources/V2SApp/Services/LiveTranscriptionSession.swift:241`
- 说明：
  - 类被标记为 `@unchecked Sendable`。
  - 大量状态被注释为“只在 `captureQueue` 访问”，但 `start()` / `stop()` 直接在调用线程改写同一对象上的多个字段。
  - `stop()` 会直接置空 capture/recognition/timer 相关属性，而 capture callback 和 `captureQueue.async` 管线仍可能同时读写这些状态。
  - 已修复：`stop()` 现在改为在 `captureQueue` 上串行执行 teardown；legacy recognizer 配置和音频 capture 启动也切到了 `captureQueue`。

### 2. OverlayColor fallback 会导致崩溃

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Models/OverlayStyle.swift:43`
- 说明：
  - 当前 fallback 为 `NSColor.white`。
  - 本地最小复现验证了对 `NSColor.white.redComponent` 的访问会因灰度颜色空间未先转换而抛 `NSInvalidArgumentException`。
  - 这里应改为明确的 sRGB 颜色，如 `NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)`。

### 3. SettingsWindowController 缺少 `isReleasedWhenClosed = false`

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/UI/Settings/SettingsWindowController.swift:25`
- 说明：
  - 本地最小复现表明：`NSWindowController(window:)` 在 `super.init(window:)` 之后会自动把窗口的 `isReleasedWhenClosed` 从 `true` 设为 `false`。
  - 因此这里没有显式设置，最多是风格不一致，不是“关闭后再次打开会访问已释放窗口”的确定性崩溃点。

### 4. PopoverOutsideClickMonitor 缺少 `deinit` 清理

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/StatusBar/PopoverOutsideClickMonitor.swift`
- 说明：
  - 当前只有 `stop()`，没有 `deinit { stop() }`。
  - 如果未来调用路径在 `start()` 后直接释放实例而未先 `stop()`，event monitor 会泄漏。
  - 现有主路径里风险不高，但问题本身成立。

### 5. `group.addTask` 隐式强捕获 `@MainActor self`

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/App/AppModel.swift:1178`，`Sources/V2SApp/App/AppModel.swift:1850`
- 说明：
  - 这两处确实在 task group 子任务里引用了 `self`。
  - 但按当前代码和本地最小样例，编译器不会因为“未使用 `[weak self]`”本身在这两处报错。
  - 当前项目在 Swift 6 严格并发下的真实报错点位于 `TranslationCoordinator.run(using:)` 中对 `session` 的发送风险，而不是这里列出的两处。

### 6. SpeedMonitor.currentCPS 计算不准

- 结论：`部分属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/SpeedMonitor.swift:19-24`
- 说明：
  - 若目标是按“已有数据实际跨度”算 CPS，则窗口未满时固定除以 5000ms 会低估。
  - 但当前注释写的是“rolling 5-second window”，按固定 5 秒归一化也有一致性。
  - 另外目前没有发现 `currentCPS(nowMs:)` 的实际调用点。

### 7. EntityCache.record() 在 entry 已锁定后仍覆盖翻译

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/EntityCache.swift:16-26`
- 说明：
  - `locked` 设为 `true` 后，代码仍然执行 `entry.translation = translation`。
  - 这与注释里“锁定确认过的实体翻译”语义矛盾。
  - 当前 `EntityCache` 似乎尚未真正接入读写主流程，但实现问题存在。

### 8. GlossaryService.apply 级联替换不确定

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/GlossaryService.swift:6-17`
- 说明：
  - 当前直接遍历 `[String: String]` 并连续 `replacingOccurrences`。
  - 对于重叠词条，结果会依赖字典迭代顺序以及先替换了哪个词条。
  - 这会让替换结果不可预测。

### 9. VAD 推理错误被静默吞没

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/SileroVADEngine.swift:110`
- 说明：
  - `(try? infer(chunk: chunk)) ?? 0` 会把推理错误全部吞掉。
  - 一旦 ONNX 推理持续失败，外部只会看到长期“无语音”，没有日志也没有降级提示。

### 10. TranscriptView 摘要任务未存储/未取消

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/Settings/TranscriptView.swift:215-228`
- 说明：
  - `Task { ... }` 没有保存句柄。
  - 快速开关摘要、切换 tab、重复触发时，会产生多个并发任务竞争写入 `summarizedText`、`isSummarizing` 和 `summarizeError`。

### 11. ChunkScorer.score 中 `silenceMs` 参数未使用

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Models/ModeConfig.swift:113-145`
- 说明：
  - `score(...)` 接受了 `silenceMs`，但函数体没有读取。
  - `silenceScoreValue(silenceMs:)` 也未被调用，当前已是死代码。

### 12. Timer/AnimationContext 回调中使用 `MainActor.assumeIsolated`

- 结论：`部分属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/Overlay/OverlayWindowController.swift:331`，`Sources/V2SApp/UI/Overlay/OverlayWindowController.swift:403`，`Sources/V2SApp/UI/Overlay/OverlayWindowController.swift:795`
- 说明：
  - 从稳妥性角度看，`Task { @MainActor in ... }` 的确更保守。
  - 但当前 `Timer` 是加在 `RunLoop.main` 上的，`NSAnimationContext` completion 也通常回到主线程。
  - 因此“若在后台线程触发将 fatal”这个理论风险存在，但作为当前代码中的确定性缺陷，表述偏重。

### 13. SettingsView.footerBar 是死代码

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/Settings/SettingsView.swift:398-408`
- 说明：
  - `footerBar` 已定义，但当前 `body` 未引用。

### 14. SettingsWindowController 初始化时创建了两次 SettingsView

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/Settings/SettingsWindowController.swift:26-57`
- 说明：
  - 先用空闭包创建一次 `SettingsView`。
  - 随后立即把 `hostingController.rootView` 替换成第二个 `SettingsView`。
  - 第一次完整 SwiftUI 层级实例化没有实际价值。

### 15. SettingsStore.load() 在解码错误时静默返回默认值

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/SettingsStore.swift:17-24`
- 说明：
  - 当前任何读取失败或 JSON 解码失败都会直接返回 `.default`。
  - 没有日志，也没有区分“文件不存在”和“文件损坏”。
  - 这会让用户设置被悄悄丢弃且难以定位原因。

### 16. `NSApp.activate(ignoringOtherApps:)` 在 macOS 14+ 已弃用

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/UI/Settings/SettingsWindowController.swift:70`，`Sources/V2SApp/UI/Settings/SettingsWindowController.swift:96`，`Sources/V2SApp/UI/Settings/TranscriptView.swift:40`
- 说明：
  - 当前 SDK 头文件标注的是“将在未来版本弃用”，不是“macOS 14+ 已弃用”。
  - `NSApplication.activate()` 是 macOS 14 新增 API，但带 `ignoringOtherApps` 的旧 API 目前仍可用。
  - 在当前这些 `@MainActor` 场景里，本地类型检查也没有得到弃用警告。

### 17. `draftLengthFitScore` 逻辑重复

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/LiveTranscriptionSession.swift:1766`，`Sources/V2SApp/Services/LiveTranscriptionSession.swift:2039`
- 说明：
  - 同一套长度评分逻辑既存在于 `draftLengthFitScore(for:)`，又在另一处被内联复制。
  - 后续调整阈值时容易改漏。

### 18. ApplicationAudioCapture 使用 `bufferListNoCopy + deallocator: nil`

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/Services/LiveTranscriptionSession.swift:2317-2328`
- 说明：
  - 当前 no-copy buffer 在 `handleCapturedAudio(_:)` 内创建后，立即同步传入 `append(audioBuffer:)`。
  - 后续处理链要么直接同步消费，要么很快复制/转换，不存在当前代码把底层 `AudioBufferList` 长时间异步持有出去的路径。
  - 这更像对未来改动的注意点，不是当前实现已证实的缺陷。

### 19. 文字描边使用 8 个偏移副本渲染，长字幕时性能开销较大

- 结论：`部分属实`
- 修复状态：`[ ] 未修复`
- 位置：`Sources/V2SApp/UI/Overlay/OverlayView.swift:620-638`
- 说明：
  - 8 个偏移 `Text` 副本一定比单层文本更重。
  - 但这种实现方式本身在 SwiftUI 里并不罕见。
  - 是否已经构成可感知性能问题，需要结合长字幕场景做 profile 才能定性。

### 20. 鼠标追踪定时器以 30 FPS 无条件运行

- 结论：`部分属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/Overlay/OverlayWindowController.swift:794`
- 说明：
  - 该定时器不是全局无条件运行；overlay 隐藏时会被停掉。
  - 之前 overlay 显示期间会固定 30 FPS 调 `updatePassThroughBubble()`，不以“鼠标是否靠近 overlay”为前提。
  - 现已改为根据鼠标与 overlay 的距离，在低频探测和 30 FPS 精跟踪之间切换。

## 建议优先级

若要按修复优先级推进，建议优先处理以下条目：

1. `1` `2` `9` `10` `15`
2. `4` `7` `8` `11` `14` `17`
3. `6` `12` `13` `19` `20`

通常不建议按原表述直接接收以下条目：

- `3`
- `5`
- `16`
- `18`

## 补充审查（二）

以下为第二轮补充审查意见的核对结果与处理状态。

### 总览

| 编号 | 结论 | 修复状态 | 摘要 |
| --- | --- | --- | --- |
| C1 | 不属实 | `不适用` | `SettingsWindowController` 未显式设置 `isReleasedWhenClosed = false`，但 `NSWindowController(window:)` 已自动处理。 |
| C2 | 不属实 | `不适用` | `group.addTask` 两处并不是当前 Swift 6 严格并发报错点。 |
| W1 | 属实 | `[x]` | `reset()` 与 `recoverSession()` 的 continuation 取消逻辑重复。 |
| W2 | 部分属实 | `[x]` | `levenshteinDistance` 边界写法脆弱，可读性差。 |
| W3 | 属实 | `[x]` | 翻译等待与 runner/queue 获取已改为事件驱动唤醒。 |
| W4 | 部分属实 | `[x]` | `SileroVADHysteresis` 死区内会清理对侧陈旧计数。 |
| W5 | 不属实 | `不适用` | `oldConfig` 不能改成 `let`，因为 `invalidate()` 是 mutating。 |
| I1 | 属实 | `[x]` | `JSONEncoder.pretty` 每次保存都会新建实例。 |
| I2 | 属实 | `[x]` | 鼠标追踪改为远离 overlay 低频探测、接近时再切回 30 FPS。 |
| I3 | 部分属实 | `[x]` | schema 迁移导致整体解码失败的风险已缓解，但损坏 JSON 仍会回退默认值。 |
| I4 | 属实 | `[x]` | 仓库 URL 之前使用了强制解包。 |

### C1. SettingsWindowController 缺少 `isReleasedWhenClosed = false`

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/UI/Settings/SettingsWindowController.swift`
- 说明：
  - 本地最小复现确认：`NSWindowController(window:)` 会在 `super.init(window:)` 后将 `window.isReleasedWhenClosed` 从 `true` 置为 `false`。
  - 因此该意见不是当前代码中的实际崩溃点。

### C2. `group.addTask` 隐式强捕获 `@MainActor self`

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/App/AppModel.swift`
- 说明：
  - 这两处确实隐式捕获了 `self`，但按本地 Swift 6 严格并发最小样例验证，不会因为这一模式本身在这里报错。
  - 当前项目真实的严格并发错误点仍在 `TranslationCoordinator.run(using:)` 对 `TranslationSession` 的使用。

### W1. `recoverSession` 与 `reset` 存在重复的 continuation 取消逻辑

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/App/AppModel.swift`
- 说明：
  - 已提取共用清理路径，新增 `cancelOutstandingOperations()` 和 `cancel(_ operation:)`，避免两处状态清理逻辑分叉。

### W2. `levenshteinDistance` 的边界处理脆弱

- 结论：`部分属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/App/AppModel.swift`
- 说明：
  - 原实现结果基本正确，但写法脆弱且不直观。
  - 已改为标准边界处理：先对空串做 `guard` 返回，再进入 `1...m` / `1...n` 循环。

### W3. 翻译等待使用 `50ms` 轮询

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/App/AppModel.swift`
- 说明：
  - `waitForTranslatedCaption` 现在改为 caption 级一次性 waiter，翻译完成、超时、取消或 session 重置时直接唤醒。
  - `TranslationCoordinator.run(using:)` 的 runner 抢占与 `nextOperation` 队列等待也已改为 continuation 驱动，不再依赖固定间隔 `Task.sleep` 轮询。

### W4. `SileroVADHysteresis` 概率死区

- 结论：`部分属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/SileroVADHysteresis.swift`
- 说明：
  - 仍保留迟滞死区，但在死区内会清理当前状态对应的“翻转方向”计数，避免退出死区后沿用陈旧累计值立刻翻转。
  - 这样保留了迟滞效果，同时收敛了计数器陈旧带来的边界行为。

### W5. `recoverSession` 中 `var oldConfig` 应为 `let`

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/App/AppModel.swift`
- 说明：
  - 本地构建验证表明 `TranslationSession.Configuration.invalidate()` 是 mutating。
  - 将 `oldConfig` 改为 `let` 会直接导致编译失败，因此该意见不成立。

### I1. `JSONEncoder.pretty` 每次 `save()` 都创建新实例

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/SettingsStore.swift`
- 说明：
  - 已将 `JSONEncoder.pretty` 从 computed property 改为 `static let` 单例初始化。

### I2. 鼠标追踪定时器 30 FPS 无条件运行

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/Overlay/OverlayWindowController.swift`
- 说明：
  - 仍保留定时器方案，但不再在 overlay 可见期间始终固定 30 FPS。
  - 现在会根据鼠标与 overlay 的距离在低频探测和 30 FPS 精跟踪之间切换，降低远离 overlay 时的常驻轮询成本。

### I3. `SettingsStore.load()` 在非文件缺失错误时记录日志但丢弃用户设置

- 结论：`部分属实`
- 修复状态：`[x] 已缓解`
- 位置：`Sources/V2SApp/Services/SettingsStore.swift`，`Sources/V2SApp/Models/AppSettings.swift`
- 说明：
  - 该问题在 schema 迁移场景下已部分缓解。
  - `AppSettings.init(from:)` 现在对各字段采用更保守的单字段回退策略，避免新增/异常字段导致整个设置对象解码失败。
  - 但如果 JSON 本体已损坏，`SettingsStore.load()` 仍会记录日志并回退默认值。

### I4. `URL(string:)!` 强制解包

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/App/AppModel.swift`，`Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift`
- 说明：
  - 已将仓库 URL 改为可选值传递，`VersionLink` 也改为接受可选 URL。
  - URL 无效时仅显示版本文本，不再依赖强制解包。

## 补充审查（三）

以下为第三轮补充审查意见的核对结果与处理状态。

### 总览

| 编号 | 结论 | 修复状态 | 摘要 |
| --- | --- | --- | --- |
| G1 | 属实 | `[x]` | `GlossaryService` 在大小写折叠后重复 key 时可能崩溃。 |
| P1 | 部分属实 | `[x]` | `PopoverOutsideClickMonitor.deinit` 存在线程上下文隐患。 |
| S1 | 不属实 | `不适用` | `SettingsStore` 共享 `JSONEncoder` 在当前 `@MainActor` 约束下不是实际问题。 |

### G1. `GlossaryService` 的重复 key 崩溃

- 结论：`属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/Services/GlossaryService.swift`
- 说明：
  - 之前使用 `Dictionary(uniqueKeysWithValues:)` 收集归一化后的 glossary key。
  - 当用户录入仅大小写不同或 trim 后相同的术语时，归一化 key 会重复并触发运行时 trap。
  - 现已改为按排序后的优先级逐项构建字典，遇到重复 key 时保留首个候选，不再崩溃。

### P1. `PopoverOutsideClickMonitor.deinit` 线程安全

- 结论：`部分属实`
- 修复状态：`[x] 已修复`
- 位置：`Sources/V2SApp/UI/StatusBar/PopoverOutsideClickMonitor.swift`
- 说明：
  - `deinit` 本身不是 actor-isolated，上一个版本会直接在析构线程调用 `NSEvent.removeMonitor(...)`。
  - 这在实际主线程释放路径下通常没问题，但若最后一次释放发生在后台线程，清理线程就不稳定。
  - 现已在 `deinit` 中根据当前线程决定直接清理或切回主线程异步清理。

### S1. `SettingsStore.JSONEncoder.pretty` 共享实例

- 结论：`不属实`
- 修复状态：`不适用`
- 位置：`Sources/V2SApp/Services/SettingsStore.swift`
- 说明：
  - 当前 `SettingsStore` 整体受 `@MainActor` 约束，`save()` 不会并发访问共享 encoder。
  - 因此这不是现阶段的实际缺陷，只是对未来去隔离化改动的潜在提醒。
