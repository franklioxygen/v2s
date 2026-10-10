#!/usr/bin/env python3
"""Compare a live replay with timestamped, reviewed reference passages.

Reference TSV: start, end (audio seconds), status, text. Only status=agreed
passages of at least four normalized characters are scored. They are still a
machine reference unless somebody has listened and checked them. This measures
retention of reference words, NOT human-verified ASR accuracy or false positives.
Each passage is aligned to the best contiguous substring of captions delivered
between start-3 and end+30 seconds; punctuation and whitespace are ignored.
The 30-second allowance accommodates delayed finalization, not missing words.
"""
import argparse
import csv
import json
from pathlib import Path
import unicodedata


def normalize(text):
    text = unicodedata.normalize('NFKC', text)
    # Only orthographic equivalents in the reference; do not hide missing words.
    for a, b in [('舞', 'まい'), ('マイ', 'まい'), ('分か', 'わか'), ('綺麗', 'きれい'), ('頃', 'ころ')]:
        text = text.replace(a, b)
    return ''.join(c for c in text if unicodedata.category(c)[0] not in 'PZS')


def substring_distance(reference, hypothesis):
    """Levenshtein distance to any contiguous substring (free outer context)."""
    previous = [0] * (len(hypothesis) + 1)
    for i, a in enumerate(reference, 1):
        current = [i]
        for j, b in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = current
    return min(previous)


def read_hypothesis(path):
    if path.suffix == '.jsonl':
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        return [(r['end'], r['text']) for r in rows if r['final']]
    rows = [line.split('\t', 2) for line in path.read_text().splitlines()]
    feed_start = next((float(t) for t, kind, _ in rows if kind == 'S'), 0)
    return [(float(t) - feed_start, text) for t, kind, text in rows if kind == 'C']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--hypothesis', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    references = list(csv.DictReader(args.reference.open(), delimiter='\t'))
    captions = read_hypothesis(args.hypothesis)
    scored = []
    for r in references:
        reference = normalize(r['text'])
        if r['status'] != 'agreed' or len(reference) < 4:
            continue
        nearby = ''.join(text for t, text in captions if float(r['start']) - 3 <= t <= float(r['end']) + 30)
        distance = substring_distance(reference, normalize(nearby))
        scored.append({**r, 'characters': len(reference), 'edits': distance, 'exact': distance == 0, 'nearby_captions': nearby})
    total = sum(r['characters'] for r in scored)
    edits = sum(r['edits'] for r in scored)
    result = {
        'hypothesis': str(args.hypothesis),
        'metric': 'reference-word retention; best substring edit distance, not full CER',
        'reference_passages': len(scored), 'reference_characters': total,
        'edits': edits, 'reference_word_error_percent': round(100 * edits / total, 2) if total else None,
        'exact_passages': sum(r['exact'] for r in scored),
        'caption_count': len(captions),
        'caption_characters': sum(len(normalize(t)) for _, t in captions),
        'passages': scored,
    }
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'passages'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
