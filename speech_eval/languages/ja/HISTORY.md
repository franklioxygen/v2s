# Japanese (`ja`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：CER ≤ 8.0% 才进入翻译测试（门槛），≤ 4.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标、→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 CER: **4.4%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | CER | Δ | 识别 | 缺句 | 延迟 p50/p90 | →en chrF (保持率) | →zh-Hans chrF (保持率) | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 4.4% | – | 🟡 pass | 0 | 9.6s / 17.9s | 56.1 (90.9%) | 42.3 (93.1%) | 🔴 fail |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 4.4% | +0.0 | 🟡 pass | 0 | 9.6s / 17.9s | 56.2 (91.0%) | 41.2 (90.7%) | 🔴 fail |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 4.4% | +0.0 | 🟡 pass | 0 | 9.6s / 17.8s | 56.2 (91.0%) | 41.2 (90.7%) | 🔴 fail |  |

## 新闻 news

最佳 CER: **16.3%**（20261116-182549，a00ddd0）

| 运行 | 提交 | 备注 | CER | Δ | 识别 | 缺句 | 延迟 p50/p90 | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | 16.3% | – | 🔴 fail | 1 | 18.0s / 36.4s | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 16.3% | +0.0 | 🔴 fail | 1 | 18.1s / 36.4s | ⚪ skipped |  |
| 20261117-101548 | a00ddd0* | Find committed text in later results by word alignment, not audio time | 16.3% | +0.0 | 🔴 fail | 1 | 18.0s / 36.4s | ⚪ skipped |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
