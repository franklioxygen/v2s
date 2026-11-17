"""Scoring: recognition error rate with alignment, caption lag, and chrF.

Recognition is scored on words (WER) for space-delimited languages and on
characters (CER, whitespace ignored) for Chinese, Japanese, Korean and Thai.
Both sides are normalized the same way: NFKC, the language's orthographic
equivalents from lang.json, lower case, punctuation/symbols treated as spaces.
Normalization must never hide a wrong word, only spelling variants.
"""
from collections import Counter
import statistics
import unicodedata


def normalize(text, lang):
    rules = lang.get('normalize', {})
    text = unicodedata.normalize('NFKC', text)
    for old, new in rules.get('replace', []):
        text = text.replace(old, new)
    if rules.get('strip_marks'):
        text = ''.join(c for c in unicodedata.normalize('NFD', text) if unicodedata.category(c) != 'Mn')
        text = unicodedata.normalize('NFC', text)
    text = text.lower()
    return ''.join(' ' if unicodedata.category(c)[0] in 'PSZC' else c for c in text)


def tokens(text, lang):
    normalized = normalize(text, lang)
    if lang['metric'] == 'cer':
        return [c for c in normalized if not c.isspace()]
    return normalized.split()


def align(reference, hypothesis):
    """Levenshtein alignment: list of (op, ref_index, hyp_index), op in M/S/D/I."""
    rows, cols = len(reference) + 1, len(hypothesis) + 1
    cost = [[0] * cols for _ in range(rows)]
    for i in range(1, rows):
        cost[i][0] = i
    for j in range(1, cols):
        cost[0][j] = j
    for i in range(1, rows):
        a = reference[i - 1]
        row, previous = cost[i], cost[i - 1]
        for j in range(1, cols):
            row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a != hypothesis[j - 1]))
    ops, i, j = [], rows - 1, cols - 1
    while i or j:
        if i and j and cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            ops.append(('M' if reference[i - 1] == hypothesis[j - 1] else 'S', i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i and cost[i][j] == cost[i - 1][j] + 1:
            ops.append(('D', i - 1, None))
            i -= 1
        else:
            ops.append(('I', None, j - 1))
            j -= 1
    ops.reverse()
    return ops


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def score_recognition(reference_lines, captions, lang, timing=None):
    """reference_lines: [text]; captions: [(emit_seconds, text)]; timing: [(start, end)] per line.

    Returns the score dict and a human-readable alignment diff.
    """
    ref, ref_line = [], []
    for index, line in enumerate(reference_lines):
        units = tokens(line, lang)
        ref += units
        ref_line += [index] * len(units)
    hyp, hyp_time = [], []
    for emitted, text in captions:
        units = tokens(text, lang)
        hyp += units
        hyp_time += [emitted] * len(units)
    ops = align(ref, hyp)
    counts = Counter(op for op, _, _ in ops)
    errors = counts['S'] + counts['D'] + counts['I']
    rate = errors / len(ref) if ref else 1.0

    # Per reference line: how much of it was recognized and when it was committed.
    per_line = [{'units': 0, 'matched': 0, 'committed_at': None} for _ in reference_lines]
    for index in ref_line:
        per_line[index]['units'] += 1
    for op, r, h in ops:
        if r is None or h is None:
            continue
        line = per_line[ref_line[r]]
        if op == 'M':
            line['matched'] += 1
        line['committed_at'] = max(line['committed_at'] or 0, hyp_time[h])
    lags = []
    for index, line in enumerate(per_line):
        line['accuracy'] = round(line['matched'] / line['units'], 3) if line['units'] else None
        if timing and line['committed_at'] is not None and line['units'] and line['matched'] / line['units'] >= 0.5:
            line['lag'] = round(line['committed_at'] - timing[index][1], 2)
            lags.append(line['lag'])
    result = {
        'metric': lang['metric'], 'error_rate': round(rate, 4), 'accuracy': round(max(0.0, 1 - rate), 4),
        'substitutions': counts['S'], 'deletions': counts['D'], 'insertions': counts['I'],
        'reference_units': len(ref), 'hypothesis_units': len(hyp), 'captions': len(captions),
        'lines_missing': sum(1 for line in per_line if line['units'] and line['matched'] / line['units'] < 0.5),
        'lag_p50': round(statistics.median(lags), 2) if lags else None,
        'lag_p90': percentile(lags, 0.9),
        'per_line': per_line,
    }
    return result, render_diff(reference_lines, ref, ref_line, hyp, ops, lang)


def render_diff(reference_lines, ref, ref_line, hyp, ops, lang):
    """One block per reference line: REF / HYP with errors bracketed."""
    joiner = '' if lang['metric'] == 'cer' else ' '
    blocks = {index: ([], []) for index in range(len(reference_lines))}
    current = 0
    for op, r, h in ops:
        if r is not None:
            current = ref_line[r]
        ref_out, hyp_out = blocks[current]
        if op == 'M':
            ref_out.append(ref[r])
            hyp_out.append(hyp[h])
        elif op == 'S':
            ref_out.append(f'[{ref[r]}]')
            hyp_out.append(f'[{hyp[h]}]')
        elif op == 'D':
            ref_out.append(f'[{ref[r]}]')
            hyp_out.append('[-]')
        else:
            hyp_out.append(f'[+{hyp[h]}]')
    lines = []
    for index, text in enumerate(reference_lines):
        ref_out, hyp_out = blocks[index]
        flag = '  ' if all('[' not in unit for unit in ref_out + hyp_out) else '✗ '
        lines.append(f'{flag}#{index:02d} REF {joiner.join(ref_out)}')
        lines.append(f'     HYP {joiner.join(hyp_out)}')
    return '\n'.join(lines) + '\n'


def chrf(hypothesis, reference, order=6, beta=2.0):
    """Document-level chrF (0-100), whitespace ignored, as in sacreBLEU's chrF2."""
    hyp = ''.join(hypothesis.split())
    ref = ''.join(reference.split())
    precisions, recalls = [], []
    for n in range(1, order + 1):
        hyp_ngrams = Counter(hyp[i:i + n] for i in range(len(hyp) - n + 1))
        ref_ngrams = Counter(ref[i:i + n] for i in range(len(ref) - n + 1))
        if not hyp_ngrams or not ref_ngrams:
            continue
        overlap = sum((hyp_ngrams & ref_ngrams).values())
        precisions.append(overlap / sum(hyp_ngrams.values()))
        recalls.append(overlap / sum(ref_ngrams.values()))
    if not precisions:
        return 0.0
    precision = sum(precisions) / len(precisions)
    recall = sum(recalls) / len(recalls)
    if precision + recall == 0:
        return 0.0
    factor = beta * beta
    return round(100 * (1 + factor) * precision * recall / (factor * precision + recall), 2)
