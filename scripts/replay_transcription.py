#!/usr/bin/env python3
"""Replay a local audio file through the live pipeline, without microphone capture.

Example (macOS 26+, Xcode and the selected Speech model installed):
  python3 scripts/replay_transcription.py --audio /tmp/sample.wav --output /tmp/current.tsv
  python3 scripts/replay_transcription.py --ref v0.3.39 --audio /tmp/sample.wav --output /tmp/release.tsv

Runs at real playback speed, including preprocessing, VAD, recognition, timers,
and emitted captions/drafts. TSV columns are elapsed seconds, event kind (C =
caption, D = draft), and text. --ref compares a Git revision without changing the
working checkout. Local media and replay outputs are never added to the repo.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOOKS = r'''
extension LiveTranscriptionSession {
    func startReplay(
        localeIdentifier: String,
        modeConfig: ModeConfig,
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        partialHandler: @escaping @MainActor (DraftSegment?) -> Void
    ) async throws -> Bool {
        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.activeLocaleIdentifier = localeIdentifier
        self.errorHandler = { print("Replay error: \($0)") }
        self.fatalErrorHandler = { print("Replay fatal error: \($0)") }
        return try await configureModernSpeechRecognizer(localeIdentifier: localeIdentifier)
    }
    func replay(_ buffer: AVAudioPCMBuffer) {
        captureQueue.async { self.append(audioBuffer: buffer) }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--locale', default='ja_JP')
    parser.add_argument('--mode', choices=['balanced', 'follow', 'reading'], default='balanced')
    parser.add_argument('--ref', help='Git revision to compare; default: current working files')
    parser.add_argument('--tests', action='store_true', help='Also run the regular unit tests')
    args = parser.parse_args()
    audio = args.audio.resolve(strict=True)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='v2s-replay-') as temporary:
        project = Path(temporary) / 'package'
        project.mkdir()
        paths = ['Sources', 'Package.swift', 'Package.resolved']
        if args.tests:
            paths.append('Tests')
        if args.ref:
            archive = subprocess.check_output(['git', 'archive', args.ref, '--', *paths], cwd=ROOT)
            subprocess.run(['tar', '-x', '-C', str(project)], input=archive, check=True)
        else:
            for name in paths:
                source = ROOT / name
                if source.is_dir():
                    shutil.copytree(source, project / name)
                else:
                    shutil.copy2(source, project / name)
        source = project / 'Sources/V2SApp/Services/LiveTranscriptionSession.swift'
        instrumented = source.read_text()
        instrumented = instrumented.replace(
            'private func processModernRecognitionResult(_ result: SpeechTranscriber.Result) {',
            '''private func processModernRecognitionResult(_ result: SpeechTranscriber.Result) {
        let replayRecord: [String: Any] = ["final": result.isFinal, "start": result.range.start.seconds, "end": result.range.end.seconds, "text": String(result.text.characters)]
        if let data = try? JSONSerialization.data(withJSONObject: replayRecord, options: [.sortedKeys]) {
            print("V2S_RECOGNITION " + String(decoding: data, as: UTF8.self))
        }''')
        instrumented = instrumented.replace(
            'continuation.yield(AnalyzerInput(buffer: analyzerBuffer))',
            '''if case .dropped = continuation.yield(AnalyzerInput(buffer: analyzerBuffer)) {
            print("V2S_REPLAY_DROPPED_AUDIO")
        }''')
        source.write_text(instrumented + HOOKS)
        tests = project / 'Tests/V2STests'
        tests.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'scripts/support/TranscriptionReplayTests.swift', tests / 'ReplayTests.swift')
        command = [
            'xcodebuild', '-scheme', 'v2s', '-destination', 'platform=macOS',
            '-derivedDataPath', str(Path(temporary) / 'derived'), 'COREML_CODEGEN_LANGUAGE=Swift',
        ]
        if not args.tests:
            command += ['-only-testing:v2sTests/ReplayTests']
        command += ['test']
        environment = os.environ.copy()
        environment.update({
            'TEST_RUNNER_V2S_REPLAY_AUDIO': str(audio),
            'TEST_RUNNER_V2S_REPLAY_OUT': str(output),
            'TEST_RUNNER_V2S_REPLAY_LOCALE': args.locale,
            'TEST_RUNNER_V2S_REPLAY_MODE': args.mode,
        })
        log = output.with_suffix('.build.log')
        print(f'Replaying {audio.name} ({args.locale}, {args.mode}, {args.ref or "working tree"})', flush=True)
        print(f'Build/test log: {log}', flush=True)
        with log.open('w') as handle:
            result = subprocess.run(command, cwd=project, env=environment, stdout=handle, stderr=subprocess.STDOUT)
        raw = [line.split('V2S_RECOGNITION ', 1)[1] for line in log.read_text().splitlines() if 'V2S_RECOGNITION ' in line]
        output.with_suffix('.recognition.jsonl').write_text('\n'.join(raw) + '\n')
        print(f'Audio buffers dropped: {log.read_text().count("V2S_REPLAY_DROPPED_AUDIO")}')
        if result.returncode:
            raise SystemExit(f'Replay failed; see {log}')
        print(f'Captions and drafts: {output}', flush=True)
        for line in output.read_text().splitlines():
            if '\tC\t' in line:
                print(line)


if __name__ == '__main__':
    main()
