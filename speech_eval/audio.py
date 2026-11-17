"""Synthesize the test clips from each language's reference script.

Every line is rendered on its own with macOS `say`, so its exact position in
the clip is known (`<clip>.timing.tsv`); that is what the lag metric uses.
Dialogue alternates two speakers; when a language has only one installed
voice, speaker B is the same voice shifted down in pitch. News is read by one
voice at a faster rate with short pauses, like a newscast.

Clips are regenerated only when the script, voices, rates or this recipe
change (tracked by a hash in `audio/manifest.json`). A real recording can
replace a clip: put it at `audio/<clip>.wav`, write `"recorded": true` for that
clip in `audio/manifest.json`, and it will be left alone (lag is then not
reported, because line timings are unknown).
"""
import hashlib
import json
from pathlib import Path
import shutil
# Local TTS/ffmpeg only; argument lists, never a shell.
import subprocess  # nosec B404
import tempfile
import wave

RECIPE_VERSION = 1
SAMPLE_RATE = 24_000


def parse_script(path):
    """Return [(speaker, text)] from a script; speaker is 'A'/'B' or None."""
    lines = []
    for raw in Path(path).read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        speaker = None
        if len(line) > 2 and line[0] in 'AB' and line[1] == ':':
            speaker, line = line[0], line[2:].strip()
        lines.append((speaker, line))
    return lines


def _say(text, voice, rate, output):
    with tempfile.NamedTemporaryFile('w', suffix='.txt', encoding='utf-8', delete=False) as handle:
        handle.write(text)
        text_path = handle.name
    try:
        command = ['/usr/bin/say', '-v', voice, '-f', text_path, '-o', str(output),
                   '--file-format=WAVE', f'--data-format=LEI16@{SAMPLE_RATE}']
        if rate:
            command[1:1] = ['-r', str(rate)]
        subprocess.run(command, check=True, shell=False)  # nosec B603
    finally:
        Path(text_path).unlink(missing_ok=True)


def _pitch_shift(source, output, factor):
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg is required to make a second dialogue voice')
    subprocess.run([  # nosec B603
        ffmpeg, '-v', 'error', '-nostdin', '-y', '-i', str(source), '-af',
        f'asetrate={SAMPLE_RATE * factor:.0f},aresample={SAMPLE_RATE},atempo={1 / factor:.4f}',
        '-ac', '1', '-ar', str(SAMPLE_RATE), '-c:a', 'pcm_s16le', str(output),
    ], check=True, shell=False)


def _frames(path):
    with wave.open(str(path), 'rb') as handle:
        if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getframerate() != SAMPLE_RATE:
            raise SystemExit(f'Unexpected TTS format in {path}')
        return handle.readframes(handle.getnframes())


def wav_duration(path):
    with wave.open(str(path), 'rb') as handle:
        return handle.getnframes() / handle.getframerate()


def clip_recipe(lang, clip, script_text):
    tts = lang['tts'][clip]
    return {'recipe': RECIPE_VERSION, 'script_sha256': hashlib.sha256(script_text.encode()).hexdigest(), 'tts': tts}


def synthesize(lang_dir, lang, clip, force=False, log=print):
    """Make audio/<clip>.wav and its timing file; returns the wav path."""
    lang_dir = Path(lang_dir)
    script = lang_dir / f'{clip}.txt'
    audio_dir = lang_dir / 'audio'
    audio_dir.mkdir(exist_ok=True)
    output = audio_dir / f'{clip}.wav'
    manifest_path = audio_dir / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    entry = manifest.get(clip, {})
    if entry.get('recorded') and output.exists():
        return output
    recipe = clip_recipe(lang, clip, script.read_text(encoding='utf-8'))
    if not force and output.exists() and entry.get('recipe') == recipe:
        return output

    tts = lang['tts'][clip]
    gap = tts.get('gap', 0.45 if clip == 'dialogue' else 0.25)
    lines = parse_script(script)
    silence = lambda seconds: b'\0\0' * int(seconds * SAMPLE_RATE)
    pcm = bytearray(silence(0.6))
    timing = ['line\tspeaker\tstart\tend\ttext']
    with tempfile.TemporaryDirectory(prefix='v2s-tts-') as temporary:
        for index, (speaker, text) in enumerate(lines):
            voice = tts['voices'][1 if speaker == 'B' and len(tts['voices']) > 1 else 0]
            rate = tts.get('rate')
            rendered = Path(temporary) / f'{index}.wav'
            _say(text, voice, rate, rendered)
            if speaker == 'B' and tts.get('b_pitch'):
                shifted = Path(temporary) / f'{index}-b.wav'
                _pitch_shift(rendered, shifted, tts['b_pitch'])
                rendered = shifted
            start = len(pcm) / 2 / SAMPLE_RATE
            pcm += _frames(rendered)
            end = len(pcm) / 2 / SAMPLE_RATE
            timing.append(f'{index}\t{speaker or "-"}\t{start:.3f}\t{end:.3f}\t{text}')
            pcm += silence(gap)
    pcm += silence(1.0)
    with wave.open(str(output), 'wb') as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(pcm))
    (audio_dir / f'{clip}.timing.tsv').write_text('\n'.join(timing) + '\n', encoding='utf-8')
    manifest[clip] = {'recipe': recipe, 'seconds': round(wav_duration(output), 2)}
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    log(f'  synthesized {lang["id"]}/{clip}: {manifest[clip]["seconds"]} s')
    return output
