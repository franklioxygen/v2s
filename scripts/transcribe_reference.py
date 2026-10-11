#!/usr/bin/env python3
"""Extract a video excerpt and create independent LOCAL transcription candidates.

Requires ffmpeg and optional `mlx-whisper` (install in a separate virtualenv).
No audio is uploaded. Model weights may be downloaded from Hugging Face.
These candidates require review; they are not a human-verified gold transcript.

Example:
  python scripts/transcribe_reference.py --video /path/test.mp4 --output /tmp/reference
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('--language', default='ja')
    parser.add_argument('--model', action='append', help='Local MLX model path or HF repository; repeat for cross-checks')
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    import mlx_whisper
    args.output.mkdir(parents=True, exist_ok=True)
    audio = args.output / 'audio.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-n', '-i', str(args.video),
                    '-t', str(args.seconds), '-vn', '-ac', '1', '-ar', '16000',
                    '-c:a', 'pcm_s16le', str(audio)], check=True)
    models = args.model or ['mlx-community/whisper-large-v3-turbo', 'mlx-community/whisper-large-v3-mlx']
    manifest = {
        'video': str(args.video.resolve()), 'seconds': args.seconds,
        'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest(),
        'mlx_whisper_version': importlib.metadata.version('mlx-whisper'),
        'language': args.language, 'models': models,
        'review_status': 'unreviewed_machine_candidates',
    }
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    for index, model in enumerate(models, 1):
        result = mlx_whisper.transcribe(
            str(audio), path_or_hf_repo=model, language=args.language,
            task='transcribe', word_timestamps=True, temperature=0,
            condition_on_previous_text=False, verbose=True,
        )
        (args.output / f'candidate-{index}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        lines = [f"[{s['start']:.2f}–{s['end']:.2f}] {s['text']}" for s in result['segments']]
        (args.output / f'candidate-{index}.txt').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
