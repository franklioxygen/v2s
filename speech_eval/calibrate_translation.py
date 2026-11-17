#!/usr/bin/env python3
"""Calibrate the translation score: how much does it move by chance, and how much for real damage?

Recognition is skipped: every variant translates the reference script through
the app's TranslationCoordinator, so the results only depend on the input text.

  noise variants   the exact reference words, packaged the way captions differ from
                   the script without being wrong: no sentence context, one caption
                   per sentence, commas missing, two lines merged into one caption.
                   Each one is an equally valid input, so the spread of their
                   scores is the noise floor of the metric. (Apple's model is
                   deterministic, so repeating a run adds no spread.)
  damage variants  the reference text with simulated recognition errors at a known
                   error rate, duplicated captions, or missing captions. A useful
                   metric must drop clearly below the noise floor for these.

  python3 speech_eval/calibrate_translation.py                  # all languages
  python3 speech_eval/calibrate_translation.py --lang en,it,ja
  python3 speech_eval/calibrate_translation.py --rescore <run>  # re-analyse saved output

Raw output goes to speech_eval/calibration/translation/<run>/ (not tracked); the
analysis is written to speech_eval/calibration/TRANSLATION.md.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import random
import statistics
import sys
import unicodedata

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speech_eval import harness, metrics  # noqa: E402
from speech_eval.run import (CLIPS, LANGUAGES, load_languages, packaging_items, reference_lines,  # noqa: E402
                             translation_items_from_reference)

EVAL = Path(__file__).resolve().parent
OUT = EVAL / 'calibration'

NOISE = ('ctx0', 'split', 'nocomma', 'merge')
DAMAGE = ('err5', 'err10', 'err20', 'dup3', 'drop2')


def _units(text, char_level):
    """Editable units with their spans; punctuation is never edited so sentence splitting is unchanged."""
    if char_level:
        return [(i, i + 1) for i, ch in enumerate(text) if unicodedata.category(ch)[0] in 'LN']
    spans, start = [], None
    for i, ch in enumerate(text + ' '):
        if unicodedata.category(ch)[0] in 'LNM' or ch in "'’-":
            start = i if start is None else start
        elif start is not None:
            spans.append((start, i))
            start = None
    return spans


def corrupt(lines, rate, char_level, seed):
    """Simulated recognition errors: per unit, substitute (50%), delete (30%) or insert (20%)."""
    rng = random.Random(seed)  # nosec B311 - reproducible test damage, nothing secret
    vocabulary = [line[a:b] for line in lines for a, b in _units(line, char_level)]
    out = []
    for line in lines:
        spans = _units(line, char_level)
        pieces, cursor = [], 0
        for a, b in spans:
            pieces.append(line[cursor:a])
            word = line[a:b]
            if rng.random() < rate:
                roll = rng.random()
                if roll < 0.5:
                    word = rng.choice([v for v in vocabulary if v != word] or [word])
                elif roll < 0.8:
                    word = ''
                else:
                    word = word + ('' if char_level else ' ') + rng.choice(vocabulary)
            pieces.append(word)
            cursor = b
        pieces.append(line[cursor:])
        text = ''.join(pieces)
        text = ' '.join(text.split()) if not char_level else text
        out.append(text.replace(' ,', ',').replace(' .', '.').strip() or line)
    return out


def noise_items(variant, lines, lang):
    return packaging_items(variant, lines, lang, window=0)


def damaged_items(variant, lines, lang, seed, window):
    rng = random.Random(seed)  # nosec B311 - reproducible test damage, nothing secret
    char_level = lang['metric'] == 'cer'
    if variant.startswith('err'):
        rate = int(variant[3:]) / 100
        return translation_items_from_reference(corrupt(lines, rate, char_level, seed), window)
    items = translation_items_from_reference(lines, window)
    if variant == 'dup3':
        # A caption committed again later, the way the duplicate-commit bug does it.
        for index in sorted(rng.sample(range(len(items)), 3), reverse=True):
            items.insert(index + 1, {'text': items[index]['text']})
        return items
    if variant == 'drop2':
        keep = set(rng.sample(range(len(items)), len(items) - 2))
        return [item for index, item in enumerate(items) if index in keep]
    raise ValueError(variant)


def plan_jobs(run_dir, languages, clips, config):
    window = config['translation']['context_window']
    jobs = []
    for lang_dir, lang in languages:
        for clip in clips:
            lines = reference_lines(lang_dir, clip)
            for target in lang['translation_targets']:
                base = run_dir / lang['id'] / f'{clip}.{target}'
                base.parent.mkdir(parents=True, exist_ok=True)
                seed = f"{lang['id']}/{clip}"
                jobs.append({'source': lang['id'], 'target': target, 'out': f'{base}.ctx2.jsonl',
                             'items': packaging_items('ctx2', lines, lang, window)})
                for variant in NOISE:
                    jobs.append({'source': lang['id'], 'target': target, 'out': f'{base}.{variant}.jsonl',
                                 'items': noise_items(variant, lines, lang)})
                for variant in DAMAGE:
                    jobs.append({'source': lang['id'], 'target': target, 'out': f'{base}.{variant}.jsonl',
                                 'items': damaged_items(variant, lines, lang, f'{seed}/{variant}', window)})
    return jobs


def read_translation(path):
    if not path.exists():
        return None
    rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
    if rows and rows[0].get('kind') == 'meta':
        return None
    return ' '.join(r['translation'] for r in rows)


# Candidate scores. Each maps the per-variant translations of one clip/target to retention values.
def _vs_reference(order, denominator):
    def score(texts, reference):
        raw = {v: metrics.chrf(t, reference, order=order) for v, t in texts.items()}
        base = raw['ctx2'] if denominator == 'ctx2' else statistics.median(raw[v] for v in CEILING)
        return {v: (x / base if base else 0.0) for v, x in raw.items()}
    return score


def _fidelity(order):
    """chrF against the app's own translation of the correct script (100 = identical output)."""
    return lambda texts, reference: {v: metrics.chrf(t, texts['ctx2'], order=order) / 100 for v, t in texts.items()}


CANDIDATES = {
    'chrF6 ÷ ctx2 (previous)': _vs_reference(6, 'ctx2'),
    'chrF3 ÷ ctx2': _vs_reference(3, 'ctx2'),
    'chrF6 ÷ median5': _vs_reference(6, 'median'),
    'chrF3 ÷ median5': _vs_reference(3, 'median'),
    'fidelity chrF6 (vs app\'s own ctx2 output)': _fidelity(6),
}
CEILING = ('ctx2',) + NOISE
VARIANTS = CEILING + DAMAGE


def analyse(run_dir, languages, clips):
    rows = []
    for _, lang in languages:
        for clip in clips:
            for target in lang['translation_targets']:
                base = run_dir / lang['id'] / f'{clip}.{target}'
                texts = {v: read_translation(Path(f'{base}.{v}.jsonl')) for v in VARIANTS}
                row = {'lang': lang['id'], 'clip': clip, 'target': target}
                if any(t is None for t in texts.values()):
                    rows.append(dict(row, missing=True))
                    continue
                reference = ' '.join(reference_lines(LANGUAGES / target, clip))
                row['ceiling_chrf'] = metrics.chrf(texts['ctx2'], reference)
                row['scores'] = {name: {v: round(x, 4) for v, x in score(texts, reference).items()}
                                 for name, score in CANDIDATES.items()}
                rows.append(row)
    return rows


def _band(values):
    values = sorted(values)
    return f'{min(values):.3f} / {statistics.median(values):.3f} / {max(values):.3f}' if values else '–'


def summarize(subset, name):
    """Gate = lowest correct-word score (a perfect pipeline never fails); goal = 5th percentile."""
    values = [r['scores'][name] for r in subset]
    # ctx2 is the denominator itself for the ÷ ctx2 and fidelity scores, so it adds no information there.
    variants = CEILING if 'median' in name else NOISE
    noise = sorted(x[v] for x in values for v in variants)
    gate = int(noise[0] * 100) / 100
    goal = int(noise[int(0.05 * len(noise))] * 100) / 100
    caught = {v: sum(x[v] < gate for x in values) / len(values) for v in DAMAGE}
    return {'values': values, 'noise': noise, 'gate': gate, 'goal': goal, 'caught': caught,
            'power': (caught['err10'] + caught['drop2']) / 2}


def report(rows, run_id):
    complete = [r for r in rows if not r.get('missing')]
    missing = [r for r in rows if r.get('missing')]
    lines = [
        '# Translation score calibration',
        '',
        f'Generated by `speech_eval/calibrate_translation.py` (run {run_id}); raw output in '
        f'`calibration/translation/{run_id}/` (not tracked).',
        '',
        f'{len(complete)} clip/target pairs analysed'
        + (f', {len(missing)} skipped (translation model not installed)' if missing else '') + '. '
        'Every variant translates the reference script through the app\'s TranslationCoordinator.',
        '',
        '- **Correct words, different packaging** (the noise): ctx2 = script lines with 2 sentences of context '
        '(the previous ceiling), ctx0 = no context, split = one caption per sentence, nocomma = commas missing, '
        'merge = two lines per caption.',
        '- **Damage**: err5/10/20 = 5/10/20% of words (characters for CJK) substituted, deleted or inserted; '
        'dup3 = three captions committed twice; drop2 = two captions missing.',
        '- Denominator *ctx2* = the previous ceiling; *median5* = median over the five packagings.',
        '- *Gate* = lowest correct-word value rounded down (a perfect pipeline never fails); *goal* = 5th percentile '
        '(95% of perfect pipelines reach it). *Caught* = share of damage cases below the gate. '
        'The recommended score per target catches the most err10 + drop2 cases at its gate.',
        '',
    ]
    recommended = {}
    for target in sorted({r['target'] for r in complete}):
        subset = [r for r in complete if r['target'] == target]
        ceiling = statistics.median(r['ceiling_chrf'] for r in subset)
        lines += [f'## → {target} ({len(subset)} pairs, median ceiling chrF6 {ceiling:.1f})', '',
                  '| score | ' + ' | '.join(NOISE) + ' | gate | goal | ' + ' | '.join(DAMAGE)
                  + ' | caught err5/err10/err20/dup3/drop2 |', '|' + '---|' * (len(NOISE) + len(DAMAGE) + 4)]
        summaries = {name: summarize(subset, name) for name in CANDIDATES}
        best = max(summaries, key=lambda n: summaries[n]['power'])
        recommended[target] = (best, summaries[best])
        for name, info in summaries.items():
            cells = [f'**{name}**' if name == best else name]
            cells += [_band([x[v] for x in info['values']]) for v in NOISE]
            cells += [f"{info['gate']:.2f}", f"{info['goal']:.2f}"]
            cells += [_band([x[v] for x in info['values']]) for v in DAMAGE]
            cells.append('/'.join(f"{100 * info['caught'][v]:.0f}%" for v in DAMAGE))
            lines.append('| ' + ' | '.join(cells) + ' |')
        lines += ['', f"Recommended: **{best}**, gate {summaries[best]['gate']:.2f}, goal {summaries[best]['goal']:.2f}.", '']
    lines += ['Cells: min / median / max over all pairs. Duplicated captions barely move any chrF score; '
              'the recognition stage counts them as insertions instead.', '']
    for target, (name, _) in recommended.items():
        lines += [f'## Per pair → {target} ({name})', '',
                  '| pair | ceiling chrF6 | ' + ' | '.join(VARIANTS) + ' |', '|' + '---|' * (len(VARIANTS) + 2)]
        for r in (r for r in complete if r['target'] == target):
            s = r['scores'][name]
            lines.append(f"| {r['lang']} {r['clip']} | {r['ceiling_chrf']:.1f} | "
                         + ' | '.join(f'{s[v]:.3f}' for v in VARIANTS) + ' |')
        lines.append('')
    if missing:
        lines += ['Skipped: ' + ', '.join(f"{r['lang']} {r['clip']}→{r['target']}" for r in missing), '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--lang', help='comma-separated language ids (default: all)')
    parser.add_argument('--clips', default='dialogue,news')
    parser.add_argument('--rescore', help='re-analyse an earlier calibration run instead of translating again')
    args = parser.parse_args()
    config = json.loads((EVAL / 'config.json').read_text())
    languages = load_languages(args.lang)
    clips = [c for c in CLIPS if c in args.clips.split(',')]
    run_id = args.rescore or datetime.now().strftime('%Y%m%d-%H%M%S')
    run_dir = OUT / 'translation' / run_id
    if not args.rescore:
        run_dir.mkdir(parents=True, exist_ok=True)
        jobs = plan_jobs(run_dir, languages, clips, config)
        print(f'Calibration {run_id}: {len(jobs)} translation jobs, preparing build …', flush=True)
        package = harness.prepare()
        if not harness.run_test(package, 'testTranslation', {'jobs': jobs}, run_dir / 'plan.json', run_dir / 'build.log'):
            print(f'⚠ xcodebuild reported a failure; see {run_dir / "build.log"}')
    rows = analyse(run_dir, languages, clips)
    (run_dir / 'analysis.json').write_text(json.dumps(rows, ensure_ascii=False, indent=1) + '\n')
    text = report(rows, run_id)
    (OUT / 'TRANSLATION.md').write_text(text, encoding='utf-8')
    print(text)


if __name__ == '__main__':
    main()
