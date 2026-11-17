#!/usr/bin/env python3
"""Pick each language's `say` rates so both clips last about a minute.

Dialogue is read at a conversational pace and news must be read at least 10%
faster (in characters per second of speech). Rates are written into each
lang.json; rerun after editing a script. Rendering is iterative because `say`
rates are only roughly proportional to speaking time.

  python3 speech_eval/calibrate_tts.py            # all languages
  python3 speech_eval/calibrate_tts.py --lang ja,ar
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speech_eval import audio  # noqa: E402

LANGUAGES = Path(__file__).resolve().parent / 'languages'
TARGET_SECONDS = 60.0
NEWS_SPEEDUP = 1.10
RATE_RANGE = (110, 340)


def measure(lang_dir, clip):
    rows = [line.split('\t') for line in (lang_dir / 'audio' / f'{clip}.timing.tsv').read_text().splitlines()[1:]]
    speech = sum(float(r[3]) - float(r[2]) for r in rows)
    characters = sum(len(r[4]) for r in rows)
    total = audio.wav_duration(lang_dir / 'audio' / f'{clip}.wav')
    return total, speech, characters / speech


def render(lang_dir, lang, clip, rate):
    lang['tts'][clip]['rate'] = int(max(RATE_RANGE[0], min(RATE_RANGE[1], rate)))
    audio.synthesize(lang_dir, lang, clip, log=lambda _: None)
    return measure(lang_dir, clip)


def fit(lang_dir, lang, clip, rate, target_total, minimum_pace=None):
    for _ in range(4):
        total, speech, pace = render(lang_dir, lang, clip, rate)
        silence = total - speech
        wanted = target_total - silence
        if minimum_pace and pace < minimum_pace:
            wanted = min(wanted, speech * pace / minimum_pace)
        if abs(speech - wanted) / wanted < 0.03 and not (minimum_pace and pace < minimum_pace):
            break
        if minimum_pace and pace < minimum_pace:
            wanted *= 0.98  # step past the tolerance band so the pace requirement is actually met
        rate = lang['tts'][clip]['rate'] * speech / wanted
    return total, pace


def calibrate(lang_dir):
    lang = json.loads((lang_dir / 'lang.json').read_text(encoding='utf-8'))
    dialogue_total, dialogue_pace = fit(lang_dir, lang, 'dialogue', lang['tts']['dialogue'].get('rate', 180), TARGET_SECONDS)
    news_total, news_pace = fit(lang_dir, lang, 'news', lang['tts']['news'].get('rate', 200), TARGET_SECONDS,
                                minimum_pace=dialogue_pace * NEWS_SPEEDUP)
    (lang_dir / 'lang.json').write_text(json.dumps(lang, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return (f"{lang['id']:8} dialogue {dialogue_total:5.1f}s @{lang['tts']['dialogue']['rate']} "
            f"news {news_total:5.1f}s @{lang['tts']['news']['rate']} pace ×{news_pace / dialogue_pace:.2f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--lang')
    args = parser.parse_args()
    dirs = [LANGUAGES / i for i in args.lang.split(',')] if args.lang else sorted(
        p for p in LANGUAGES.iterdir() if (p / 'lang.json').exists())
    with ThreadPoolExecutor(max_workers=6) as pool:
        for line in pool.map(calibrate, dirs):
            print(line, flush=True)


if __name__ == '__main__':
    main()
