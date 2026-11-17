#!/usr/bin/env python3
"""Iterative speech recognition + translation evaluation for v2s.

For each language: synthesize (or reuse) the dialogue and news clips, replay
them in real time through the app's LiveTranscriptionSession, score the
committed captions against the reference script, and only for clips that pass
the recognition gate translate the captions through the app's
TranslationCoordinator and score them with chrF. Every run is appended to the
language's history.jsonl / HISTORY.md, and SUMMARY.md shows the latest state.

Examples:
  python3 speech_eval/run.py --lang en,ja --note "baseline"
  python3 speech_eval/run.py --lang zh-Hans --clips news
  python3 speech_eval/run.py --ref v0.3.39 --lang ja --note "release baseline"
  python3 speech_eval/run.py --report        # only regenerate HISTORY.md / SUMMARY.md
  python3 speech_eval/run.py --rescore 20261116-182549   # re-score a run's translations

A full run (27 languages) replays about 27 × 2 minutes of audio; it must not
run while the v2s app is recognizing speech, because both compete for the same
system speech service.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import statistics
# Only pgrep with a fixed argument list.
import subprocess  # nosec B404
import sys

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speech_eval import audio, harness, history, metrics  # noqa: E402

EVAL = Path(__file__).resolve().parent
LANGUAGES = EVAL / 'languages'
CLIPS = ('dialogue', 'news')


def load_languages(selection):
    found = {p.name: p for p in sorted(LANGUAGES.iterdir()) if (p / 'lang.json').exists()}
    ids = list(found) if not selection else selection.split(',')
    missing = [i for i in ids if i not in found]
    if missing:
        raise SystemExit(f'Unknown language(s): {", ".join(missing)}. Available: {", ".join(found)}')
    return [(found[i], json.loads((found[i] / 'lang.json').read_text(encoding='utf-8'))) for i in ids]


def recognition_targets(lang, config):
    targets = dict(config['recognition'][lang['metric']])
    targets.update(lang.get('targets', {}).get('recognition', {}))
    return targets


def classify(value, gate, goal, lower_is_better=True):
    if value is None:
        return 'error'
    if lower_is_better:
        return 'goal' if value <= goal else 'pass' if value <= gate else 'fail'
    return 'goal' if value >= goal else 'pass' if value >= gate else 'fail'


def read_events(path):
    if not path.exists():
        return [], {'backend': 'unavailable', 'error': 'no output'}
    events = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
    meta = next((e for e in events if e['kind'] == 'meta'), {'backend': 'unknown'})
    return events, meta


def read_timing(lang_dir, clip):
    path = lang_dir / 'audio' / f'{clip}.timing.tsv'
    if not path.exists():
        return None
    rows = [line.split('\t') for line in path.read_text(encoding='utf-8').splitlines()[1:] if line.strip()]
    return [(float(r[2]), float(r[3])) for r in rows]


def reference_lines(lang_dir, clip):
    return [text for _, text in audio.parse_script(lang_dir / f'{clip}.txt')]


def translation_items_from_captions(events):
    items = []
    for e in events:
        if e['kind'] != 'C':
            continue
        item = {'text': e['text']}
        if e.get('context'):
            item.update(context=e['context'], contextIndex=e['context_index'])
        items.append(item)
    return items


def translation_items_from_reference(lines, window):
    items = []
    for index, text in enumerate(lines):
        start = max(0, index - window)
        item = {'text': text}
        if index > start:
            item.update(context=lines[start:index + 1], contextIndex=index - start)
        items.append(item)
    return items


def split_sentences(line, char_level):
    pattern = r'(?<=[。！？!?])' if char_level else r'(?<=[.!?])\s+'
    return [part.strip() for part in re.split(pattern, line) if part.strip()]


# The correct script packaged the ways real captions differ from it without being wrong.
# Their translations are all equally valid, so the ceiling is the median of their scores
# (see calibration/TRANSLATION.md); ctx2 alone (the best case) is kept as context_gain.
CEILING_VARIANTS = ('ctx2', 'ctx0', 'split', 'nocomma', 'merge')


def packaging_items(variant, lines, lang, window=2):
    char_level = lang['metric'] == 'cer'
    if variant == 'ctx2':
        return translation_items_from_reference(lines, window)
    if variant == 'ctx0':
        return [{'text': line} for line in lines]
    if variant == 'split':
        return [{'text': part} for line in lines for part in split_sentences(line, char_level)]
    if variant == 'nocomma':
        return [{'text': re.sub(r'\s*[,，、;；]\s*', '' if char_level else ' ', line)} for line in lines]
    if variant == 'merge':
        joiner = '' if char_level else ' '
        return [{'text': joiner.join(lines[i:i + 2])} for i in range(0, len(lines), 2)]
    raise ValueError(variant)


def ceiling_path(base, variant):
    return Path(f'{base}.ceiling.jsonl' if variant == 'ctx2' else f'{base}.ceiling.{variant}.jsonl')


def translation_settings(target, config):
    t = config['translation']
    settings = {k: v for k, v in t.items() if k != 'targets'}
    settings.update(t['targets'].get(target, t['targets']['default']))
    return settings


def _translation_rows(path):
    if not path.exists():
        return None
    data = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
    return None if data and data[0].get('kind') == 'meta' else data


def score_translation(pipeline_path, ceiling_paths, reference_text, settings):
    """Retention = pipeline chrF ÷ median chrF of the correct script's packagings."""
    pipeline = _translation_rows(pipeline_path)
    ceilings = {v: _translation_rows(path) for v, path in ceiling_paths.items()}
    if pipeline is None or any(rows is None for rows in ceilings.values()):
        return {'status': 'error', 'chrf': None, 'error': 'translation model unavailable or run failed'}
    order = settings['chrf_order']

    def score(rows):
        return metrics.chrf(' '.join(r['translation'] for r in rows), reference_text, order=order)

    chrf = score(pipeline)
    ceiling_scores = {v: score(rows) for v, rows in ceilings.items()}
    ceiling = statistics.median(ceiling_scores.values())
    translated = [r for r in pipeline if r['translation'].strip() and not r.get('error')]
    coverage = len(translated) / len(pipeline) if pipeline else 0.0
    retention = round(chrf / ceiling, 4) if ceiling else None
    status = classify(retention, settings['retention_gate'], settings['retention_goal'], lower_is_better=False)
    if coverage < settings['coverage_gate'] and status != 'error':
        status = 'fail'
    times = [r['ms'] for r in pipeline if 'ms' in r]
    return {
        'metric': f'chrF{order}/median{len(ceiling_scores)}',
        'chrf': chrf, 'ceiling': round(ceiling, 2), 'ceilings': ceiling_scores, 'retention': retention,
        'context_gain': round(ceiling_scores['ctx2'] / ceiling, 4) if ceiling and 'ctx2' in ceiling_scores else None,
        'coverage': round(coverage, 4), 'median_ms': int(statistics.median(times)) if times else None,
        'context_used': sum(1 for r in pipeline if r.get('context_used')), 'captions': len(pipeline),
        'status': status,
    }


def write_side_by_side(path, pipeline_path, ceiling_path, reference):
    def rows(p):
        return [json.loads(line) for line in p.read_text(encoding='utf-8').splitlines() if line.strip()] if p.exists() else []
    out = ['# Pipeline: recognized caption → app translation', '']
    out += [f"{r['text']}\n  → {r['translation']}" for r in rows(pipeline_path) if 'text' in r]
    out += ['', '# Ceiling: reference line → app translation   (reference translation)', '']
    for index, r in enumerate(row for row in rows(ceiling_path) if 'text' in row):
        ref = reference[index] if index < len(reference) else ''
        out.append(f"{r['text']}\n  → {r['translation']}\n  ≈ {ref}")
    path.write_text('\n'.join(out) + '\n', encoding='utf-8')


def translate_and_score(package, lang_dir, lang, run_dir, pending, config, records):
    """pending: (clip, target, base path, pipeline items or None to reuse the saved pipeline output)."""
    jobs = []
    for clip, target, base, items in pending:
        if items is not None:
            jobs.append({'source': lang['id'], 'target': target, 'out': f'{base}.pipeline.jsonl', 'items': items})
        lines = reference_lines(lang_dir, clip)
        for variant in CEILING_VARIANTS:
            path = ceiling_path(base, variant)
            if items is not None or not path.exists():
                jobs.append({'source': lang['id'], 'target': target, 'out': str(path),
                             'items': packaging_items(variant, lines, lang, config['translation']['context_window'])})
    if jobs:
        print(f"  translating {len(pending)} clip/target pair(s) …", flush=True)
        if not harness.run_test(package, 'testTranslation', {'jobs': jobs}, run_dir / 'translation.plan.json',
                                run_dir / 'translation.build.log'):
            print(f"  ⚠ xcodebuild reported a failure; see {run_dir / 'translation.build.log'}")
    for clip, target, base, _ in pending:
        reference = reference_lines(LANGUAGES / target, clip)
        result = score_translation(Path(f'{base}.pipeline.jsonl'), {v: ceiling_path(base, v) for v in CEILING_VARIANTS},
                                   ' '.join(reference), translation_settings(target, config))
        write_side_by_side(Path(f'{base}.translation.txt'), Path(f'{base}.pipeline.jsonl'), ceiling_path(base, 'ctx2'),
                           reference)
        records[clip]['translation'][target] = result
        print(f"  {clip} → {target}: {result.get('metric')} {result.get('chrf')} vs ceiling {result.get('ceiling')} "
              f"(retention {result.get('retention')}, context gain {result.get('context_gain')}, "
              f"coverage {result.get('coverage')}) → {history.STATUS_ICON[result['status']]}", flush=True)


def finish_records(records):
    order = ['error', 'fail', 'pass', 'goal']
    for record in records:
        states = [t['status'] for t in record['translation'].values()]
        record['translation_status'] = min(states, key=order.index) if states else 'skipped'


def rescore(lang_dir, lang, run_id, config, package, commit):
    """Re-score the translations of an earlier run with the current scoring, without re-recognizing."""
    run_dir = lang_dir / 'runs' / run_id
    records = [r for r in history.load(lang_dir) if r['run'] == run_id]
    pending = [(r['clip'], target, run_dir / f"{r['clip']}.{target}", None)
               for r in records for target in r.get('translation', {})
               if Path(f"{run_dir / r['clip']}.{target}.pipeline.jsonl").exists()]
    if not pending:
        return
    print(f"\n=== {lang['name']} ({lang['id']}) — re-scoring {run_id} ===", flush=True)
    if any(r['commit'] != commit for r in records):
        print(f"  ⚠ the run was on {records[0]['commit']}; new ceiling translations come from {commit}")
    translate_and_score(package, lang_dir, lang, run_dir, pending, config, {r['clip']: r for r in records})
    finish_records(records)
    everything = history.load(lang_dir)
    for record in records:
        record['regressions'] = history.regressions(
            record, history.previous([r for r in everything if r['run'] < run_id], record), config)
    history.replace_run(lang_dir, run_id, records)
    history.render(lang_dir, lang, config, recognition_targets(lang, config))


def evaluate_language(lang_dir, lang, args, config, run_id, package, meta):
    clips = [c for c in CLIPS if c in args.clips.split(',')]
    run_dir = lang_dir / 'runs' / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n=== {lang['name']} ({lang['id']}) ===", flush=True)
    wavs = {clip: audio.synthesize(lang_dir, lang, clip, force=args.resynthesize) for clip in clips}
    manifest = json.loads((lang_dir / 'audio' / 'manifest.json').read_text())

    # 1. Recognition.
    plan = {'mode': config['mode'], 'tailSeconds': config['tail_seconds'], 'cases': [
        {'audio': str(wavs[c]), 'locale': lang['speech_locale'], 'out': str(run_dir / f'{c}.events.jsonl')} for c in clips],
        'trace': args.trace}
    print(f"  recognizing {', '.join(clips)} in real time …", flush=True)
    ok = harness.run_test(package, 'testRecognition', plan, run_dir / 'recognition.plan.json',
                          run_dir / 'recognition.build.log')
    if not ok:
        print(f"  ⚠ xcodebuild reported a failure; see {run_dir / 'recognition.build.log'}")

    targets = recognition_targets(lang, config)
    records = {}
    for clip in clips:
        events, info = read_events(run_dir / f'{clip}.events.jsonl')
        recipe = manifest.get(clip, {})
        record = {
            'run': run_id, 'time': meta['time'], 'commit': meta['commit'], 'dirty': meta['dirty'], 'ref': args.ref,
            'note': args.note, 'mode': config['mode'], 'clip': clip,
            'audio_recipe': hashlib.sha256(json.dumps(recipe.get('recipe', 'recorded'), sort_keys=True).encode()).hexdigest()[:12],
            'audio_seconds': recipe.get('seconds'), 'backend': info.get('backend'),
            'asr': None, 'asr_status': 'error', 'translation': {}, 'translation_status': 'skipped',
        }
        captions = [(e['t'], e['text']) for e in events if e['kind'] == 'C']
        if info.get('backend') in ('unavailable', 'unknown'):
            record['error'] = info.get('error', 'recognizer did not start')
            print(f"  {clip}: ⛔ recognizer unavailable ({record['error']})")
        else:
            score, diff = metrics.score_recognition(reference_lines(lang_dir, clip), captions, lang,
                                                    read_timing(lang_dir, clip))
            score['dropped_audio_buffers'] = info.get('dropped_audio_buffers')
            score['errors_reported'] = [e['text'] for e in events if e['kind'] == 'X']
            (run_dir / f'{clip}.asr.json').write_text(json.dumps(score, ensure_ascii=False, indent=2) + '\n')
            (run_dir / f'{clip}.diff.txt').write_text(diff, encoding='utf-8')
            record['asr'] = {k: v for k, v in score.items() if k != 'per_line'}
            record['asr_status'] = classify(score['error_rate'], targets['gate'], targets['goal'])
            print(f"  {clip}: {lang['metric'].upper()} {100 * score['error_rate']:.1f}% "
                  f"(S{score['substitutions']} D{score['deletions']} I{score['insertions']} / {score['reference_units']}), "
                  f"lag p50 {score['lag_p50']}s p90 {score['lag_p90']}s, backend {info.get('backend')} → "
                  f"{history.STATUS_ICON[record['asr_status']]}", flush=True)
        records[clip] = (record, events)

    # 2. Translation, only for clips that passed the recognition gate.
    pending = []
    for clip, (record, events) in records.items():
        if record['asr_status'] not in ('pass', 'goal') and not args.force_translation:
            continue
        if record['asr_status'] == 'error' or args.asr_only:
            continue
        for target in lang['translation_targets']:
            pending.append((clip, target, run_dir / f'{clip}.{target}', translation_items_from_captions(events)))
    translate_and_score(package, lang_dir, lang, run_dir, pending, config, {c: r for c, (r, _) in records.items()})

    past = history.load(lang_dir)
    finish_records([r for r, _ in records.values()])
    for clip, (record, _) in records.items():
        record['regressions'] = history.regressions(record, history.previous(past, record), config)
        for note in record['regressions']:
            print(f"  {clip}: ⚠ regression: {note}")
        history.append(lang_dir, record)
    (run_dir / 'run.json').write_text(json.dumps([r for r, _ in records.values()], ensure_ascii=False, indent=2) + '\n')
    history.render(lang_dir, lang, config, recognition_targets(lang, config))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--lang', help='comma-separated language ids (default: all)')
    parser.add_argument('--clips', default='dialogue,news')
    parser.add_argument('--note', default='', help='what changed in this iteration (shown in HISTORY.md)')
    parser.add_argument('--ref', help='evaluate a Git revision instead of the working tree')
    parser.add_argument('--asr-only', action='store_true', help='skip the translation phase')
    parser.add_argument('--force-translation', action='store_true', help='translate even when recognition fails the gate')
    parser.add_argument('--resynthesize', action='store_true', help='re-render TTS audio even if unchanged')
    parser.add_argument('--allow-running-app', action='store_true')
    parser.add_argument('--trace', action='store_true',
                        help='also log every volatile transcriber result with word times (events.jsonl kind "V")')
    parser.add_argument('--report', action='store_true', help='only regenerate HISTORY.md files and SUMMARY.md')
    parser.add_argument('--rescore', metavar='RUN',
                        help='re-score the translations of an earlier run with the current scoring (no recognition)')
    args = parser.parse_args()
    if args.ref is not None and (not args.ref or args.ref.startswith('-')):
        parser.error('--ref must be a Git revision')
    config = json.loads((EVAL / 'config.json').read_text())
    languages = load_languages(args.lang)
    if args.report:
        for lang_dir, lang in languages:
            history.render(lang_dir, lang, config, recognition_targets(lang, config))
        history.render_summary(EVAL, load_languages(None))
        return
    if args.rescore:
        # Translation only: no speech service, so the app may keep running. The ceilings
        # are translated by this build, so use --ref when the run was on another commit.
        commit = harness.git_revision(args.ref or 'HEAD')
        print(f'Re-scoring run {args.rescore} with the current scoring on {commit} — preparing build …', flush=True)
        package = harness.prepare(args.ref)
        for lang_dir, lang in languages:
            rescore(lang_dir, lang, args.rescore, config, package, commit)
        history.render_summary(EVAL, load_languages(None))
        return
    running = subprocess.run(['/usr/bin/pgrep', '-x', 'v2s'], capture_output=True, shell=False)  # nosec B603
    if running.returncode == 0 and not args.allow_running_app:
        raise SystemExit('The v2s app is running; it would compete for the speech service. Quit it or pass --allow-running-app.')
    meta = {
        'time': datetime.now().astimezone().isoformat(timespec='seconds'),
        'commit': harness.git_revision(args.ref or 'HEAD'),
        'dirty': False if args.ref else harness.worktree_dirty(),
    }
    run_id = datetime.now().strftime('%Y%m%d-%H%M%S')
    print(f"Run {run_id} on {meta['commit']}{'*' if meta['dirty'] else ''} — preparing build …", flush=True)
    package = harness.prepare(args.ref)
    for lang_dir, lang in languages:
        evaluate_language(lang_dir, lang, args, config, run_id, package, meta)
        history.render_summary(EVAL, load_languages(None))
    print(f"\nDone. Summary: {EVAL / 'SUMMARY.md'}")


if __name__ == '__main__':
    main()
