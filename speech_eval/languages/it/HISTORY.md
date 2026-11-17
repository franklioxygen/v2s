# Italian (`it`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：WER ≤ 10.0% 才进入翻译测试（门槛），≤ 5.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标、→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 WER: **3.4%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 39.6% | – | 🔴 fail | 0 | 1.8s / 10.5s | – | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 17.4% | -22.2 | 🔴 fail | 2 | 1.9s / 3.7s | – | – | ⚪ skipped |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 3.4% | -14.1 | 🟢 goal | 0 | 1.6s / 2.8s | 69.5 (92.8%) | 48.3 (84.8%) | 🔴 fail |  |

## 新闻 news

最佳 WER: **0.5%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 0.5% | – | 🟢 goal | 0 | 1.4s / 1.7s | 73.5 (96.5%) | 51.7 (89.6%) | 🔴 fail |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 36.2% | +35.7 | 🔴 fail | 2 | 15.5s / 21.4s | – | – | ⚪ skipped | WER +35.7 pt vs 20261116-182549 |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 0.5% | -35.7 | 🟢 goal | 0 | 1.4s / 1.8s | 73.5 (96.5%) | 51.7 (89.6%) | 🔴 fail |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
