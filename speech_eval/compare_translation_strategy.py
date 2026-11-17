#!/usr/bin/env python3
"""Compare TranslationSession strategies: how fast, and how good, is each one?

macOS 26.4 added `preferredStrategy` (.lowLatency / .highFidelity) to Translation;
the app leaves it at the system default. This translates every language's reference
script, packaged as the app sends captions (each line with the two sentences
before it as context), once per strategy, through the app's TranslationCoordinator.
Recognition is skipped, so both strategies see the same words.

  quality   chrF of the whole translated clip against the parallel reference
            (chrF3 into zh-Hans, chrF6 otherwise, as run.py scores translations)
  latency   milliseconds per caption, as the coordinator returns it; the first
            caption of each clip/target pair also loads the model, so it is
            reported apart as "cold"

`preview` is not a session strategy but the app's draft path
(TranslationCoordinator.Quality.preview): the low-latency model where it is
installed, else the caption model.

The order of the strategies alternates between pairs, so a translation cache or a
model warmed by the first strategy does not favour one of them.

  python3 speech_eval/compare_translation_strategy.py                     # all languages
  python3 speech_eval/compare_translation_strategy.py --lang en,ja,de
  python3 speech_eval/compare_translation_strategy.py --strategies default,preview  # the app's draft path
  python3 speech_eval/compare_translation_strategy.py --rescore <run>     # re-analyse saved output

Raw output and each run's REPORT.md go to speech_eval/calibration/strategy/<run>/
(not tracked); a full default vs lowLatency run also writes speech_eval/calibration/STRATEGY.md.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import statistics
import sys

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speech_eval import harness, metrics  # noqa: E402
from speech_eval.run import (CLIPS, LANGUAGES, load_languages, packaging_items, reference_lines,  # noqa: E402
                             translation_settings)

EVAL = Path(__file__).resolve().parent
OUT = EVAL / 'calibration'
DEFAULT = 'default'
PREVIEW = 'preview'


def job_order(strategies, index):
    """Strategies in the order pair `index` runs them: reversed on every other pair."""
    return list(strategies) if index % 2 == 0 else list(reversed(strategies))


def read_rows(path):
    if not path.exists():
        return None
    rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
    return None if not rows or rows[0].get('kind') == 'meta' else rows


def score_group(rows, reference_text, order):
    """chrF and latency of one strategy's translation of one clip/target pair."""
    return {
        'chrf': metrics.chrf(' '.join(r['translation'] for r in rows), reference_text, order=order),
        'cold_ms': rows[0]['ms'],
        'warm_ms': [r['ms'] for r in rows[1:]],
        'errors': sum(1 for r in rows if r.get('error')),
        'error': next((error_cause(r['error']) for r in rows if r.get('error')), None),
        'strategy': rows[0].get('strategy'),
        'translations': [r['translation'] for r in rows],
    }


def error_cause(error):
    """`TranslationError(cause: ….notInstalled, …)` → `notInstalled`."""
    match = re.search(r'Cause\.(\w+)', error)
    return match.group(1) if match else error[:80]


def usable(group, strategies):
    return all(s in group['scores'] and group['scores'][s]['errors'] == 0 for s in strategies)


def summarize(groups, strategies, tolerance):
    """groups: [{'pair', 'first', 'scores': {strategy: score_group(...)}}] → overall comparison.

    Quality and speed are compared only over the pairs every strategy translated without
    an error; the others are counted per strategy and cause."""
    baseline, *others = strategies
    unavailable = {s: {} for s in strategies}
    for g in groups:
        for s in strategies:
            score = g['scores'].get(s)
            cause = 'no output' if score is None else score['error']
            if cause:
                unavailable[s].setdefault(cause, []).append(g['pair'])
    groups = [g for g in groups if usable(g, strategies)]
    summary = {'pairs': len(groups), 'resolved': {}, 'strategies': {}, 'unavailable': unavailable}
    for strategy in strategies:
        scored = [g['scores'][strategy] for g in groups]
        warm = [ms for s in scored for ms in s['warm_ms']]
        first = [ms for g in groups if g['first'] == strategy for ms in g['scores'][strategy]['warm_ms']]
        second = [ms for g in groups if g['first'] != strategy for ms in g['scores'][strategy]['warm_ms']]
        summary['resolved'][strategy] = sorted({s['strategy'] for s in scored if s['strategy']})
        summary['strategies'][strategy] = {
            'chrf_median': round(statistics.median(s['chrf'] for s in scored), 2) if scored else None,
            'warm_ms_p50': metrics.percentile(warm, 0.5), 'warm_ms_p90': metrics.percentile(warm, 0.9),
            'cold_ms_p50': metrics.percentile([s['cold_ms'] for s in scored], 0.5),
            'warm_ms_p50_run_first': metrics.percentile(first, 0.5),
            'warm_ms_p50_run_second': metrics.percentile(second, 0.5),
            'errors': sum(s['errors'] for s in scored),
        }
    for strategy in others:
        both = groups
        deltas = [g['scores'][strategy]['chrf'] - g['scores'][baseline]['chrf'] for g in both]
        summary['strategies'][strategy]['vs_' + baseline] = {
            'chrf_delta_median': round(statistics.median(deltas), 2) if deltas else None,
            'chrf_delta_min': round(min(deltas), 2) if deltas else None,
            'worse_pairs': sum(1 for d in deltas if d < -tolerance),
            'better_pairs': sum(1 for d in deltas if d > tolerance),
            'identical_pairs': sum(1 for g in both if g['scores'][strategy]['translations']
                                   == g['scores'][baseline]['translations']),
        }
    return summary


def collect(run_dir, languages, strategies, config):
    groups = []
    for lang_dir, lang in languages:
        for clip in CLIPS:
            for target in lang['translation_targets']:
                pair = f"{lang['id']}.{clip}.{target}"
                order = translation_settings(target, config)['chrf_order']
                reference = ' '.join(reference_lines(LANGUAGES / target, clip))
                scores = {}
                for strategy in strategies:
                    rows = read_rows(run_dir / f'{pair}.{strategy}.jsonl')
                    if rows:
                        scores[strategy] = score_group(rows, reference, order)
                first = next((s for s in json.loads((run_dir / f'{pair}.order.json').read_text())
                              if s in scores), None) if (run_dir / f'{pair}.order.json').exists() else None
                groups.append({'pair': pair, 'first': first, 'scores': scores})
    return groups


def translate(run_dir, languages, strategies, config):
    package = harness.prepare()
    index = 0
    for lang_dir, lang in languages:
        jobs = []
        for clip in CLIPS:
            lines = reference_lines(lang_dir, clip)
            items = packaging_items('ctx2', lines, lang, config['translation']['context_window'])
            for target in lang['translation_targets']:
                pair = f"{lang['id']}.{clip}.{target}"
                order = job_order(strategies, index)
                index += 1
                (run_dir / f'{pair}.order.json').write_text(json.dumps(order) + '\n')
                for strategy in order:
                    job = {'source': lang['id'], 'target': target, 'items': items,
                           'out': str(run_dir / f'{pair}.{strategy}.jsonl')}
                    if strategy == PREVIEW:
                        job['quality'] = 'preview'
                    elif strategy != DEFAULT:
                        job['strategy'] = strategy
                    jobs.append(job)
        print(f"  {lang['id']}: translating {len(jobs)} job(s) …", flush=True)
        if not harness.run_test(package, 'testTranslation', {'jobs': jobs}, run_dir / f"{lang['id']}.plan.json",
                                run_dir / f"{lang['id']}.build.log"):
            print(f"  ⚠ xcodebuild reported a failure; see {run_dir / (lang['id'] + '.build.log')}")


def render(run_id, groups, summary, strategies, tolerance):
    baseline, *others = strategies
    lines = [f'# Translation strategy comparison (run {run_id})', '',
             'Generated by `compare_translation_strategy.py`. Same input for every strategy: the reference script, '
             'each line with two sentences of context, through TranslationCoordinator. '
             f'`{DEFAULT}` is the session the app creates (no preferredStrategy).', '',
             '| strategy | resolves to | chrF median | warm ms p50 / p90 | cold ms p50 | warm p50 run first / second | errors |',
             '|---|---|---|---|---|---|---|']
    for strategy in strategies:
        s = summary['strategies'][strategy]
        lines.append(f"| {strategy} | {', '.join(summary['resolved'][strategy]) or '–'} | {s['chrf_median']} | "
                     f"{s['warm_ms_p50']} / {s['warm_ms_p90']} | {s['cold_ms_p50']} | "
                     f"{s['warm_ms_p50_run_first']} / {s['warm_ms_p50_run_second']} | {s['errors']} |")
    total = len(groups)
    for strategy in strategies:
        for cause, pairs in sorted(summary['unavailable'][strategy].items()):
            lines += ['', f"**{strategy} unavailable** ({cause}) for {len(pairs)} of {total} pairs: "
                          + ', '.join(pairs)]
    for strategy in others:
        v = summary['strategies'][strategy]['vs_' + baseline]
        lines += ['', f"**{strategy} vs {baseline}** over the {summary['pairs']} pairs both translated: chrF Δ median "
                      f"{v['chrf_delta_median']}, worst {v['chrf_delta_min']}; {v['worse_pairs']} worse and "
                      f"{v['better_pairs']} better by more than {tolerance} chrF; {v['identical_pairs']} pairs translated "
                      'word for word the same.']
    lines += ['', '| pair | ' + ' | '.join(f'{s} chrF' for s in strategies) + ' | Δ | '
              + ' | '.join(f'{s} warm ms p50' for s in strategies) + ' |',
              '|---|' + '---|' * (2 * len(strategies) + 1)]
    for g in groups:
        sc = g['scores']
        if not usable(g, strategies):
            lines.append(f"| {g['pair']} | " + ' | '.join('–' for _ in range(2 * len(strategies) + 1)) + ' |')
            continue
        delta = round(sc[others[0]]['chrf'] - sc[baseline]['chrf'], 2) if others else ''
        lines.append(f"| {g['pair']} | " + ' | '.join(str(sc[s]['chrf']) for s in strategies) + f' | {delta} | '
                     + ' | '.join(str(metrics.percentile(sc[s]['warm_ms'], 0.5)) for s in strategies) + ' |')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--lang', help='comma-separated language ids (default: all)')
    parser.add_argument('--strategies', default=f'{DEFAULT},lowLatency',
                        help=f'comma-separated; the first is the baseline (default: {DEFAULT},lowLatency)')
    parser.add_argument('--rescore', metavar='RUN', help='re-analyse a saved run without translating')
    args = parser.parse_args()
    config = json.loads((EVAL / 'config.json').read_text())
    strategies = args.strategies.split(',')
    unknown = set(strategies) - {DEFAULT, PREVIEW, 'lowLatency', 'highFidelity'}
    if unknown or len(strategies) < 2:
        parser.error(f'need two or more of {DEFAULT}, {PREVIEW}, lowLatency, highFidelity (got {args.strategies})')
    languages = load_languages(args.lang)
    run_id = args.rescore or datetime.now().strftime('%Y%m%d-%H%M%S')
    run_dir = OUT / 'strategy' / run_id
    if not args.rescore:
        run_dir.mkdir(parents=True, exist_ok=True)
        print(f'Strategy comparison {run_id}: {", ".join(strategies)} — preparing build …', flush=True)
        translate(run_dir, languages, strategies, config)
    tolerance = config['translation']['chrf_regression_tolerance']
    groups = collect(run_dir, languages, strategies, config)
    summary = summarize(groups, strategies, tolerance)
    (run_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    report = render(run_id, groups, summary, strategies, tolerance)
    path = run_dir / 'REPORT.md'
    path.write_text(report, encoding='utf-8')
    if args.strategies == parser.get_default('strategies') and not args.lang:
        path = OUT / 'STRATEGY.md'  # the tracked comparison: every language, default vs lowLatency
        path.write_text(report, encoding='utf-8')
    print(report.split('\n| pair |')[0])
    print(f'Report: {path}')


if __name__ == '__main__':
    main()
