# speech_eval — 识别 + 翻译自动化迭代测试

每次改动识别、断句、草稿/提交或翻译逻辑后，用同一套音频和标准文稿重新跑一遍，
结果按语言记录在各自文件夹里，便于对比每次迭代是变好还是变差。

```bash
python3 speech_eval/run.py --lang en,ja --note "调整 VAD 静音阈值"   # 指定语言
python3 speech_eval/run.py --note "baseline"                          # 全部 27 种语言（约 1 小时）
python3 speech_eval/run.py --ref v0.3.39 --lang ja --note "发布版对照"  # 测某个 Git 版本
python3 speech_eval/run.py --lang de --clips news --trace --note "…"  # 另记识别器每个中间结果的逐词时间，排查重复/漏词
python3 speech_eval/run.py --report                                   # 只重新生成 HISTORY.md / SUMMARY.md
python3 speech_eval/run.py --rescore 20261116-182549                  # 用当前评分方式重算某次运行的翻译分数（不重新识别）
python3 speech_eval/calibrate_translation.py                          # 重新标定翻译评分的噪声与门槛（约 1.5 小时）
python3 speech_eval/compare_translation_strategy.py                   # 比较翻译策略（系统默认 vs .lowLatency）的速度与质量
python3 speech_eval/compare_translation_strategy.py --strategies default,preview  # app 的草稿翻译路径 vs 字幕路径
python3 -m unittest Tests/Scripts/test_speech_eval.py                 # 评分逻辑的单元测试
```

运行前请退出 v2s app：两者会争用系统语音识别服务，结果不可信（脚本检测到 app 在运行会拒绝执行）。

## 流程

```
文稿 (dialogue.txt / news.txt)
  │  audio.py：macOS `say` 逐行合成，记录每行起止时间
  ▼
音频 (audio/dialogue.wav, news.wav，各约 1 分钟)
  │  harness：按实时速度、10 ms 一块喂给 app 的 LiveTranscriptionSession
  │  （SpeechAnalyzer，不可用时走旧版 SFSpeechRecognizer，与 app 的 start() 一致）
  ▼
已提交字幕 + 草稿 + 时间戳 (runs/<run>/<clip>.events.jsonl)
  │  ① 识别评分：与标准原文对齐 → WER/CER、缺句、字幕延迟
  ▼
识别门槛？ ── 未通过 → 翻译标记为 skipped，本轮到此为止
  │ 通过
  ▼
  ② 翻译：经 app 的 TranslationCoordinator（同样的队列、缓存、句子上下文）
     - 流水线：识别出的字幕 → 译文（带 app 实际生成的 SentenceTranslationContext）
     - 上限：标准原文按 5 种"字没错、只是分句不同"的方式送去翻译：逐行带前 2 句上下文、
       逐行无上下文、每句一条、去掉逗号、两行合一
     都与参考译文算 chrF；保持率 = 流水线 chrF ÷ 5 种上限 chrF 的中位数
  ▼
history.jsonl / HISTORY.md（每种语言）+ SUMMARY.md（总览）
```

保持率衡量的是 **v2s 自己造成的损失**（识别错误、漏句、丢标点导致的语义变化）。Apple 翻译模型本身的质量
体现在"上限 chrF"里，它不是 v2s 能迭代的部分，所以不拿它做门槛。另记 `context_gain`
（带上下文的上限 ÷ 中位数）：大于 1 说明这段内容加上句子上下文能译得更好。

## 目标（`config.json`，可在 `lang.json` 的 `targets` 中按语言覆盖）

| 阶段 | 指标 | 门槛（不达标就不测翻译） | 目标 |
|---|---|---|---|
| 识别 | WER（按词：英/欧/印地/越南等） | ≤ 10% | ≤ 5% |
| 识别 | CER（按字：中/粤/日/韩/泰） | ≤ 8% | ≤ 4% |
| 翻译 →en（及其他目标） | 保持率，chrF6（6 字符 n-gram） | ≥ 94% | ≥ 98% |
| 翻译 →zh-Hans | 保持率，chrF3（3 字符 n-gram） | ≥ 92% | ≥ 96% |
| 翻译 | 覆盖率（有译文的字幕占比） | ≥ 98% | – |
| 延迟 | 句末到字幕提交 p50 / p90（只记录不卡） | – | ≤ 2 s / ≤ 4 s |

依据：合成语音干净、无噪声，比真实视频容易，所以门槛设在业界"可用字幕"水平（WER 10%），
目标设在"基本无感错误"水平（5%）。CER 的数值天然比 WER 低（一个错词只错一两个字），因此
门槛和目标相应收紧。

翻译门槛是实测标定的（`calibrate_translation.py`，结果见 `calibration/TRANSLATION.md`）：
27 种语言 × 2 段 × 各目标语言共 100 组，把正确原文按不同分句方式翻译，测出"字全对时分数会
自然浮动多少"，再用模拟的 5/10/20% 识别错误、重复字幕、漏句测"真出错时分数掉多少"。
门槛 = 字全对时出现过的最低值（完美的流水线永远不会被判失败），目标 = 字全对时 95% 能达到的值。
中文目标的 chrF 绝对值低（约 39），换种说法就会大幅波动，改用 3 字符 n-gram 并以中位数作分母后，
字全对时的最低值从 0.76 提高到 0.92，同时 10% 识别错误中有 65%、漏两句的情况中有 79% 会被拦下。
重复字幕几乎不影响 chrF，由识别阶段的插入错误负责发现。
同一音频上，错误率比上一次升高 1 个百分点以上、或 chrF 下降 2 分以上，会在历史里标记为回归。

状态：🟢 goal（达到目标）· 🟡 pass（过门槛未达目标）· 🔴 fail · ⚪ skipped（识别未过门槛，未测翻译）· ⛔ error（识别器/翻译模型不可用或运行失败）。

## 目录

```
speech_eval/
  run.py  harness.py  audio.py  metrics.py  history.py   流程、构建、合成、评分、历史
  calibrate_tts.py                   校准 TTS 语速
  calibrate_translation.py           标定翻译评分的噪声与门槛
  calibration/TRANSLATION.md         最近一次翻译评分标定结果（原始输出在 calibration/translation/，不入库）
  compare_translation_strategy.py    比较 TranslationSession 的 preferredStrategy（macOS 26.4+）
  calibration/STRATEGY.md            最近一次策略比较结果（原始输出在 calibration/strategy/，不入库）
  support/SpeechEvalHarness.swift    在 app 代码副本中运行的 XCTest（识别回放 + 翻译）
  config.json                        门槛与目标
  SUMMARY.md                         最新一次结果总览（自动生成）
  languages/<id>/
    lang.json        识别 locale、WER/CER、TTS 声音与语速、翻译目标语言、正字法等价规则
    dialogue.txt     对话标准原文（A:/B: 两个说话人，16 句）
    news.txt         新闻标准原文（一人稍快播报，10 句）
    HISTORY.md       本语言每次运行的结果表（自动生成，纳入版本控制）
    history.jsonl    同上的原始数据
    audio/           合成音频与每行时间（本地生成，不入库）
    runs/<run>/      每次运行明细（不入库）：
                       <clip>.diff.txt            逐句 REF/HYP 对照，[ ] 标出错误 —— 迭代时主要看这个
                       <clip>.asr.json            识别指标与逐句准确率/延迟
                       <clip>.events.jsonl        原始事件：C 提交字幕、D 草稿、F 识别器最终结果（含音频起止秒与逐词时间），
                                                  加 --trace 时另记 V 识别器中间结果；查重复或漏词时对照 F / V
                       <clip>.<目标>.translation.txt  字幕→译文、原文→译文≈参考译文 对照
                       <clip>.<目标>.ceiling*.jsonl   5 种分句方式的原文译文
                       *.build.log                xcodebuild 日志
```

## 语言与文稿

覆盖 app 中既能识别又能翻译的 27 种语言：

- 设备端识别（SpeechAnalyzer）：en, zh-Hans, zh-Hant, yue, ja, ko, es, de, fr, it, pt, hi
- 旧版识别（SFSpeechRecognizer，经 Apple 服务器）：ar, da, fi, he, id, ms, nb, nl, pl, ru, sv, th, tr, uk, vi

所有语言的对话和新闻是 **同一内容的平行文本**，逐行对齐。因此任何语言的文稿都可直接作为
其他语言的翻译参考：英文→`languages/zh-Hans/`，其他语言→zh-Hans 和 en（zh-Hant、yue
到 zh-Hans 的翻译系统不支持，只测→en）。文稿刻意不含阿拉伯数字，避免"三"/"3"这类格式差异干扰评分。

语速由 `calibrate_tts.py` 按声音逐个校准后写入 `lang.json`：两段都约 60 秒，新闻每秒字符数
至少比对话快 10%。修改文稿后运行 `python3 speech_eval/calibrate_tts.py --lang <id>` 重新校准。

正字法等价规则（`lang.json` → `normalize`）只处理拼写变体（如俄语 ё/е、阿语 hamza 写法、
印地语 nukta、土耳其语 İ/ı 大小写），**不得用来掩盖识别错误**。

## 迭代方法

1. 改代码前先跑一次相关语言作为基线（`--note "baseline"`）。
2. 修改后再跑，`--note` 写清楚改了什么。
3. 看终端输出和 `HISTORY.md` 的 Δ / 回归列；具体错在哪看 `runs/<run>/<clip>.diff.txt`。
4. 修改涉及断句/翻译显示时，再按 `reports/sentence-only-display/e2e` 的端到端回放检查画面。

## 用真实录音替换

合成语音是可复现的起点，但比真人语音容易。要加入真实录音：把 1 分钟左右的录音放到
`languages/<id>/audio/<clip>.wav`，按录音内容逐句改写 `<clip>.txt`，并在
`audio/manifest.json` 对应条目写 `"recorded": true`（脚本将不再覆盖它；没有逐行时间，延迟不计算）。
注意：录音改变后与之前的历史不可比，Δ 只在同一音频之间计算。

## 已知限制

- 文稿和参考译文由人工智能撰写，未经母语者校对；用于相对比较（迭代前后）是可靠的，
  绝对分数仅供参考。发现不自然的句子可以直接改，改后音频会自动重新合成（历史从此另起比较基线）。
- 部分语言只有一个系统声音，对话的 B 由同一声音降调（`b_pitch`）模拟第二个说话人。
- 翻译阶段使用 app 记录的句子上下文，但不包含草稿提升（promoted draft translation）与词汇表；
  画面上的最终效果仍以端到端回放为准。
- 旧版识别（服务器端）的 15 种语言需要"语音识别"权限，而 xcodebuild 的测试进程无法弹出授权，
  目前这些语言会在 15 秒后记为 ⛔ error（文稿、音频、翻译参考都已就绪）。要测它们，需要一个
  带 `NSSpeechRecognitionUsageDescription` 的小型宿主 app 来运行回放，并由用户点一次"允许"；
  启用后它们的音频会发送到 Apple 的语音服务。
- 设备端语言首次运行时，系统会按需下载该语言的语音模型（与 app 中首次选择该语言相同）。
