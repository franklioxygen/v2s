# Chinese (Traditional) (`zh-Hant`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：CER ≤ 8.0% 才进入翻译测试（门槛），≤ 4.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 CER: **7.4%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | CER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 27.8% | – | 🔴 fail | 0 | 4.8s / 10.9s | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 19.4% | -8.3 | 🔴 fail | 2 | 2.0s / 7.4s | – | ⚪ skipped |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 7.4% | -12.0 | 🟡 pass | 0 | 1.9s / 7.4s | 58.6 (89.9%) | 🔴 fail |  |

## 新闻 news

最佳 CER: **5.4%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | CER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 17.6% | – | 🔴 fail | 0 | 6.0s / 12.8s | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 22.7% | +5.0 | 🔴 fail | 2 | 3.6s / 12.8s | – | ⚪ skipped | CER +5.0 pt vs 20261116-182549 |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 5.4% | -17.3 | 🟡 pass | 0 | 3.6s / 12.8s | 68.9 (94.6%) | 🟡 pass |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
