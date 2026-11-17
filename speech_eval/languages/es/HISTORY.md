# Spanish (`es`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：WER ≤ 10.0% 才进入翻译测试（门槛），≤ 5.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标、→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 WER: **2.2%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 2.2% | – | 🟢 goal | 0 | 1.6s / 2.1s | 71.5 (96.8%) | 51.5 (93.8%) | 🟡 pass |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 13.9% | +11.7 | 🔴 fail | 1 | 2.8s / 7.3s | – | – | ⚪ skipped | WER +11.7 pt vs 20261116-182549 |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 2.2% | -11.7 | 🟢 goal | 0 | 1.6s / 2.1s | 71.5 (96.8%) | 51.5 (93.8%) | 🟡 pass |  |
| 20261117-162053 | ff254fc* | Commit run-on drafts without punctuation in parts (#42) | 2.2% | +0.0 | 🟢 goal | 0 | 1.6s / 2.1s | 71.5 (96.8%) | 51.5 (93.8%) | 🟡 pass |  |

## 新闻 news

最佳 WER: **0.5%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 20.7% | – | 🔴 fail | 0 | 1.5s / 2.7s | – | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 7.1% | -13.6 | 🟡 pass | 1 | 2.2s / 7.0s | 68.4 (92.3%) | 50.6 (93.0%) | 🔴 fail |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 0.5% | -6.6 | 🟢 goal | 0 | 1.5s / 2.0s | 73.5 (99.2%) | 53.2 (97.8%) | 🟢 goal |  |
| 20261117-162053 | ff254fc* | Commit run-on drafts without punctuation in parts (#42) | 0.5% | +0.0 | 🟢 goal | 0 | 1.5s / 2.0s | 73.0 (98.4%) | 53.2 (97.9%) | 🟢 goal |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
