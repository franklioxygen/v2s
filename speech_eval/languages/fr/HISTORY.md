# French (`fr`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：WER ≤ 10.0% 才进入翻译测试（门槛），≤ 5.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标、→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 WER: **23.3%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 83.1% | – | 🔴 fail | 1 | 1.9s / 4.6s | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 37.2% | -45.9 | 🔴 fail | 4 | 1.6s / 5.3s | ⚪ skipped |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 23.3% | -13.9 | 🔴 fail | 1 | 1.5s / 2.3s | ⚪ skipped |  |

## 新闻 news

最佳 WER: **0.0%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 0.0% | – | 🟢 goal | 0 | 1.8s / 6.5s | 72.5 (98.7%) | 49.9 (98.9%) | 🟢 goal |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 21.7% | +21.7 | 🔴 fail | 0 | 6.6s / 18.3s | – | – | ⚪ skipped | WER +21.7 pt vs 20261116-182549 |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 0.0% | -21.7 | 🟢 goal | 0 | 1.8s / 6.5s | 72.5 (98.7%) | 49.9 (98.9%) | 🟢 goal |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
