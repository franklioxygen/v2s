"""Per-language result history (history.jsonl + HISTORY.md) and the overall SUMMARY.md."""
import json
from pathlib import Path

# 'pass' is a result status, not a password.
STATUS_ICON = {'goal': '🟢 goal', 'pass': '🟡 pass', 'fail': '🔴 fail', 'skipped': '⚪ skipped', 'error': '⛔ error'}  # nosec B105


def load(lang_dir):
    path = Path(lang_dir) / 'history.jsonl'
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]


def previous(records, record):
    """Latest earlier record of the same clip on the same audio and mode."""
    for old in reversed(records):
        if (old['clip'], old.get('audio_recipe'), old.get('mode')) == (
                record['clip'], record.get('audio_recipe'), record.get('mode')) and old['asr_status'] != 'error':
            return old
    return None


def regressions(record, before, config):
    if not before:
        return []
    notes = []
    tolerance = config['recognition']['regression_tolerance']
    if before.get('asr') and record.get('asr'):
        delta = record['asr']['error_rate'] - before['asr']['error_rate']
        if delta > tolerance:
            notes.append(f"{record['asr']['metric'].upper()} +{100 * delta:.1f} pt vs {before['run']}")
    for target, result in record.get('translation', {}).items():
        old = before.get('translation', {}).get(target)
        if (old and result.get('chrf') is not None and old.get('chrf') is not None
                and old.get('metric') == result.get('metric')):
            drop = old['chrf'] - result['chrf']
            if drop > config['translation']['chrf_regression_tolerance']:
                notes.append(f'→{target} chrF −{drop:.1f} vs {before["run"]}')
    return notes


def append(lang_dir, record):
    with (Path(lang_dir) / 'history.jsonl').open('a', encoding='utf-8') as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + '\n')


def replace_run(lang_dir, run_id, records):
    """Swap the records of one run (e.g. after re-scoring), keeping the file order."""
    by_clip = {r['clip']: r for r in records}
    kept = [by_clip.get(r['clip'], r) if r['run'] == run_id else r for r in load(lang_dir)]
    text = ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in kept)
    (Path(lang_dir) / 'history.jsonl').write_text(text, encoding='utf-8')


def _pct(value):
    return '–' if value is None else f'{100 * value:.1f}%'


def _seconds(value):
    return '–' if value is None else f'{value:.1f}s'


def render(lang_dir, lang, config, targets):
    records = load(lang_dir)
    metric = lang['metric'].upper()
    per_target = config['translation']['targets']
    retention = '、'.join(
        f"→{t} ≥ {_pct(s['retention_gate'])} 通过 / ≥ {_pct(s['retention_goal'])} 达标"
        for t, s in ((t, per_target.get(t, per_target['default'])) for t in lang['translation_targets']))
    lines = [
        f"# {lang['name']} (`{lang['id']}`) — 识别 / 翻译迭代记录",
        '',
        '由 `speech_eval/run.py` 自动生成，请勿手改；原始数据在 `history.jsonl`，每次运行的明细在 `runs/<run>/`。',
        '',
        f"目标：{metric} ≤ {_pct(targets['gate'])} 才进入翻译测试（门槛），≤ {_pct(targets['goal'])} 为达标；"
        f"翻译保持率（流水线 chrF ÷ 正确原文几种分句方式译文 chrF 的中位数）{retention}；"
        f"字幕延迟 p50 ≤ {config['lag']['p50_goal']}s、p90 ≤ {config['lag']['p90_goal']}s 为参考目标。",
        '',
    ]
    for clip, title in (('dialogue', '对话 dialogue'), ('news', '新闻 news')):
        rows = [r for r in records if r['clip'] == clip]
        lines += [f'## {title}', '']
        if not rows:
            lines += ['（尚无记录）', '']
            continue
        scored = [r for r in rows if r.get('asr')]
        if scored:
            best = min(scored, key=lambda r: r['asr']['error_rate'])
            lines += [f"最佳 {metric}: **{_pct(best['asr']['error_rate'])}**（{best['run']}，{best['commit']}）", '']
        target_ids = sorted({t for r in rows for t in r.get('translation', {})})
        header = ['运行', '提交', '备注', metric, 'Δ', '识别', '缺句', '延迟 p50/p90']
        header += [f'→{t} chrF (保持率)' for t in target_ids] + ['翻译', '回归']
        lines += ['| ' + ' | '.join(header) + ' |', '|' + '---|' * len(header)]
        for index, r in enumerate(rows):
            asr = r.get('asr') or {}
            before = previous(rows[:index], r)
            delta = '–'
            if asr and before and before.get('asr'):
                change = 100 * (asr['error_rate'] - before['asr']['error_rate'])
                delta = f'{change:+.1f}'
            cells = [
                r['run'], r['commit'] + ('*' if r.get('dirty') else ''), (r.get('note') or '').replace('|', '/'),
                _pct(asr.get('error_rate')), delta, STATUS_ICON[r['asr_status']], str(asr.get('lines_missing', '–')),
                f"{_seconds(asr.get('lag_p50'))} / {_seconds(asr.get('lag_p90'))}",
            ]
            for target in target_ids:
                t = r.get('translation', {}).get(target)
                cells.append('–' if not t or t.get('chrf') is None else f"{t['chrf']:.1f} ({_pct(t.get('retention'))})")
            cells += [STATUS_ICON[r['translation_status']], '; '.join(r.get('regressions', [])) or '']
            lines.append('| ' + ' | '.join(cells) + ' |')
        lines.append('')
    lines += ['`*` = 运行时工作区有未提交改动。Δ 只与同一音频、同一模式的上一次运行比较。', '']
    (Path(lang_dir) / 'HISTORY.md').write_text('\n'.join(lines), encoding='utf-8')


def render_summary(eval_dir, languages):
    lines = [
        '# Speech eval — 最新结果总览',
        '',
        '由 `speech_eval/run.py` 自动生成。每种语言的完整历史见 `languages/<id>/HISTORY.md`。',
        '',
        '| 语言 | 识别后端 | 指标 | 对话 | 新闻 | 翻译 (最低保持率) | 最近运行 |',
        '|---|---|---|---|---|---|---|',
    ]
    for lang_dir, lang in languages:
        records = load(lang_dir)
        latest = {}
        for r in records:
            latest[r['clip']] = r
        if not latest:
            lines.append(f"| {lang['name']} (`{lang['id']}`) | {lang['expected_backend']} | {lang['metric'].upper()} | – | – | – | – |")
            continue
        cells = []
        retentions, translation_states = [], []
        for clip in ('dialogue', 'news'):
            r = latest.get(clip)
            if not r:
                cells.append('–')
                continue
            asr = r.get('asr') or {}
            cells.append(f"{_pct(asr.get('error_rate'))} {STATUS_ICON[r['asr_status']]}")
            translation_states.append(r['translation_status'])
            retentions += [t['retention'] for t in r.get('translation', {}).values() if t.get('retention') is not None]
        backend = next((r.get('backend') for r in latest.values() if r.get('backend')), lang['expected_backend'])
        worst = min(retentions) if retentions else None
        order = ['error', 'fail', 'pass', 'goal']
        tested = [s for s in translation_states if s != 'skipped']
        state = min(tested, key=order.index) if tested else 'skipped'
        skipped = len(translation_states) - len(tested)
        note = f'（{skipped} 段未过识别门槛）' if tested and skipped else ''
        run = max(r['run'] for r in latest.values())
        lines.append(f"| {lang['name']} (`{lang['id']}`) | {backend} | {lang['metric'].upper()} | {cells[0]} | {cells[1]} | "
                     f"{_pct(worst)} {STATUS_ICON[state]}{note} | {run} |")
    lines.append('')
    (Path(eval_dir) / 'SUMMARY.md').write_text('\n'.join(lines), encoding='utf-8')
