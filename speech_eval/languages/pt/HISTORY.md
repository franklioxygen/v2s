# Portuguese (`pt`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：WER ≤ 10.0% 才进入翻译测试（门槛），≤ 5.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标、→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 WER: **6.0%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 25.2% | – | 🔴 fail | 0 | 1.3s / 2.1s | – | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 27.8% | +2.6 | 🔴 fail | 3 | 2.2s / 4.3s | – | – | ⚪ skipped | WER +2.6 pt vs 20261116-182549 |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 6.0% | -21.9 | 🟡 pass | 0 | 1.3s / 2.1s | 64.7 (90.3%) | 48.7 (86.8%) | 🔴 fail |  |

## 新闻 news

最佳 WER: **4.6%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 4.6% | – | 🟢 goal | 0 | 1.4s / 2.0s | 72.0 (93.3%) | 51.6 (91.2%) | 🔴 fail |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 73.7% | +69.1 | 🔴 fail | 1 | 18.9s / 32.5s | – | – | ⚪ skipped | WER +69.1 pt vs 20261116-182549 |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 4.6% | -69.1 | 🟢 goal | 0 | 1.4s / 2.0s | 72.0 (93.3%) | 51.6 (91.2%) | 🔴 fail |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
