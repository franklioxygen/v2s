# Swedish (`sv`) — 识别 / 翻译迭代记录

由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。

目标：WER ≤ 10.0% 才进入翻译测试（门槛），≤ 5.0% 为达标；翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）→zh-Hans ≥ 92.0% 通过 / ≥ 96.0% 达标、→en ≥ 94.0% 通过 / ≥ 98.0% 达标；字幕延迟 p50 ≤ 2.0s、p90 ≤ 4.0s 为参考目标。

## 对话 dialogue

最佳 WER: **67.3%**（20261117-085254，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | – | – | ⛔ error | – | – / – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 67.3% | – | 🔴 fail | 1 | 25.6s / 43.8s | ⚪ skipped |  |

## 新闻 news

最佳 WER: **43.7%**（20261117-085254，a00ddd0）

| 运行 | 提交 | 备注 | WER | Δ | 识别 | 缺句 | 延迟 p50/p90 | 翻译 | 回归 |
|---|---|---|---|---|---|---|---|---|---|
| 20261116-182549 | a00ddd0 | baseline | – | – | ⛔ error | – | – / – | ⚪ skipped |  |
| 20261117-085254 | a00ddd0* | Drop reissued words by audio time outside Japanese | 43.7% | – | 🔴 fail | 0 | 29.5s / 50.2s | ⚪ skipped |  |

`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。
