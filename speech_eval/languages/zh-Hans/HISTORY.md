# Chinese (Simplified) (`zh-Hans`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：CER ≤ 8.0% 才进入翻译测试（门槛），≤ 4.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 CER: **5.1%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | CER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 39.9% | – | 🔴 fail | 0 | 2.0s / 12.0s | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 25.7% | -14.2 | 🔴 fail | 3 | 1.5s / 5.0s | – | ⚪ skipped |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 5.1% | -20.6 | 🟡 pass | 0 | 1.6s / 5.3s | 61.2 (89.3%) | 🔴 fail |  |

## 新闻 news

最佳 CER: **0.7%**（20261117-101548，a00ddd0）

| 运行 | 提交 | 备注 | CER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 20.9% | – | 🔴 fail | 0 | 6.2s / 12.9s | – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 2.4% | -18.5 | 🟢 goal | 0 | 4.1s / 12.8s | 72.8 (97.7%) | 🟡 pass |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 0.7% | -1.7 | 🟢 goal | 0 | 4.1s / 12.8s | 72.7 (97.5%) | 🟡 pass |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
