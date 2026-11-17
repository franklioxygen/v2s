# English (`en`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：WER ≤ 10.0% 才进入翻译测试（门槛），≤ 5.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 WER: **0.6%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 0.6% | – | 🟢 goal | 0 | 0.7s / 1.0s | 57.4 (92.9%) | 🟡 pass |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 0.6% | +0.0 | 🟢 goal | 0 | 0.6s / 1.0s | 57.4 (92.9%) | 🟡 pass |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 0.6% | +0.0 | 🟢 goal | 0 | 0.7s / 1.0s | 57.4 (92.9%) | 🟡 pass |  |
| 20261117-162053 | ff254fc* | Commit run-on drafts without punctuation in parts (#42) | 0.6% | +0.0 | 🟢 goal | 0 | 0.7s / 1.0s | 57.4 (92.9%) | 🟡 pass |  |

## 新闻 news

最佳 WER: **1.8%**（20261117-085254，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 10.5% | – | 🔴 fail | 0 | 0.8s / 1.3s | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 1.8% | -8.8 | 🟢 goal | 0 | 0.8s / 1.3s | 59.9 (98.9%) | 🟢 goal |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 1.8% | +0.0 | 🟢 goal | 0 | 0.8s / 1.3s | 59.9 (98.9%) | 🟢 goal |  |
| 20261117-162053 | ff254fc* | Commit run-on drafts without punctuation in parts (#42) | 1.8% | +0.0 | 🟢 goal | 0 | 0.8s / 1.3s | 58.5 (96.5%) | 🟢 goal |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
