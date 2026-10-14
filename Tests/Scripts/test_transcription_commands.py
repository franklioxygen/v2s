"""Exercise command boundaries without building Xcode projects or loading ASR models."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scripts import replay_transcription, transcribe_reference


class TranscriptionCommandTests(unittest.TestCase):
    def test_replay_keeps_media_paths_out_of_build_arguments(self):
        for regular_tests in (False, True):
            with self.subTest(regular_tests=regular_tests), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                audio = root / '-audio ; $(echo unsafe).wav'
                audio.touch()
                output = root / 'output with spaces.tsv'
                argv = ['replay', '--audio', str(audio), '--output', str(output)]
                if regular_tests:
                    argv.append('--tests')

                def build(command, **kwargs):
                    self.assertEqual(command[0], '/usr/bin/xcodebuild')
                    self.assertFalse(kwargs['shell'])
                    self.assertNotIn(str(audio.resolve()), command)
                    self.assertEqual(kwargs['env']['TEST_RUNNER_V2S_REPLAY_AUDIO'], str(audio.resolve()))
                    self.assertEqual('-only-testing:v2sTests/ReplayTests' in command, not regular_tests)
                    self.assertEqual(command[-1], 'test')
                    kwargs['stdout'].write('V2S_RECOGNITION {"text":"hello"}\n')
                    output.write_text('0\tC\thello\n')
                    return SimpleNamespace(returncode=0)

                with patch.object(sys, 'argv', argv), patch.object(replay_transcription.subprocess, 'run', side_effect=build) as run:
                    with contextlib.redirect_stdout(io.StringIO()):
                        replay_transcription.main()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(json.loads(output.with_suffix('.recognition.jsonl').read_text()), {'text': 'hello'})

    def test_replay_rejects_git_options_before_running_commands(self):
        for ref in ('--output=unexpected.tar', '--remote=example.com', ''):
            with self.subTest(ref=ref), patch.object(sys, 'argv', [
                'replay', '--audio', 'unused.wav', '--output', 'unused.tsv', '--ref=' + ref
            ]), patch.object(replay_transcription.subprocess, 'check_output') as archive:
                with patch.object(replay_transcription.subprocess, 'run') as run:
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                        replay_transcription.main()
                    self.assertEqual(error.exception.code, 2)
                    archive.assert_not_called()
                    run.assert_not_called()

    def test_replay_passes_git_revision_after_option_terminator(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / 'audio.wav'
            audio.touch()
            argv = ['replay', '--audio', str(audio), '--output', str(Path(directory) / 'out.tsv'), '--ref', 'HEAD~1']
            # Stop at extraction: this checks the actual CLI path up to Git/tar.
            with patch.object(sys, 'argv', argv), patch.object(replay_transcription.subprocess, 'check_output', return_value=b'archive') as archive:
                with patch.object(replay_transcription.subprocess, 'run', side_effect=RuntimeError('stop before build')) as extract:
                    with self.assertRaisesRegex(RuntimeError, 'stop before build'):
                        replay_transcription.main()
                command = archive.call_args.args[0]
                self.assertEqual(command, ['/usr/bin/git', 'archive', '--format=tar', '--', 'HEAD~1', 'Sources', 'Package.swift', 'Package.resolved'])
                self.assertFalse(archive.call_args.kwargs['shell'])
                self.assertEqual(extract.call_args.args[0][0], '/usr/bin/tar')
                self.assertFalse(extract.call_args.kwargs['shell'])
                self.assertEqual(extract.call_args.kwargs['input'], b'archive')

    def test_reference_extraction_preserves_literal_local_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            video = Path(directory) / '-video ; $(echo unsafe).mp4'
            video.touch()
            output = Path(directory) / '-output with spaces'
            argv = ['reference', '--video', str(video), '--output', str(output), '--seconds', '1', '--model', 'local/model']
            whisper = SimpleNamespace(transcribe=lambda *_args, **_kwargs: {'segments': [{'start': 0, 'end': 1, 'text': 'hello'}]})

            def extract(command, **kwargs):
                self.assertEqual(command[0], 'ffmpeg')
                self.assertEqual(command[command.index('-i') + 1], str(video.resolve()))
                self.assertEqual(command[-1], str(output.resolve() / 'audio.wav'))
                self.assertFalse(kwargs['shell'])
                self.assertTrue(kwargs['check'])
                Path(command[-1]).write_bytes(b'audio')

            with patch.object(sys, 'argv', argv), patch.dict(sys.modules, {'mlx_whisper': whisper}):
                with patch.object(transcribe_reference.subprocess, 'run', side_effect=extract) as run:
                    with patch.object(transcribe_reference.importlib.metadata, 'version', return_value='test'):
                        transcribe_reference.main()
            self.assertEqual(run.call_count, 1)
            self.assertEqual(json.loads((output / 'manifest.json').read_text())['video'], str(video.resolve()))
            self.assertIn('hello', (output / 'candidate-1.txt').read_text())

    def test_reference_rejects_non_finite_and_non_positive_duration(self):
        for seconds in ('nan', 'inf', '-inf', '0', '-1'):
            with self.subTest(seconds=seconds), patch.object(sys, 'argv', [
                'reference', '--video', 'unused.mp4', '--output', 'unused', '--seconds=' + seconds
            ]), patch.object(transcribe_reference.subprocess, 'run') as run:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    transcribe_reference.main()
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
