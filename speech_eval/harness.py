"""Build a scratch copy of the package with replay hooks and run the harness tests.

The working tree (or a Git revision) is copied to speech_eval/.cache/<key>/,
LiveTranscriptionSession.swift gets the replay extension appended, and only
SpeechEvalHarness.swift is used as the test target, so builds stay incremental
between runs. The app's own sources are never modified.
"""
import json
import os
from pathlib import Path
import shutil
# Local Git/rsync/Xcode only; argument lists, never a shell.
import subprocess  # nosec B404

ROOT = Path(__file__).resolve().parents[1]
EVAL = Path(__file__).resolve().parent
SESSION = 'Sources/V2SApp/Services/LiveTranscriptionSession.swift'

HOOKS = r'''

// MARK: - speech_eval replay hooks (added only in the evaluation build)
nonisolated(unsafe) var v2sEvalDroppedAudioBuffers = 0
/// Sees every transcriber result: (final?, audio start s, audio end s, text, each run's text and audio s).
nonisolated(unsafe) var v2sEvalResultObserver: ((Bool, Double, Double, String, [(String, Double?, Double?)]) -> Void)?

extension LiveTranscriptionSession {
    /// Mirrors start(): modern SpeechAnalyzer first, else the legacy recognizer.
    func startEvalReplay(
        localeIdentifier: String,
        modeConfig: ModeConfig,
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        partialHandler: @escaping @MainActor (DraftSegment?) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.activeLocaleIdentifier = localeIdentifier
        self.interfaceLanguageID = "en"
        self.errorHandler = errorHandler
        self.fatalErrorHandler = errorHandler
        if try await configureModernSpeechRecognizer(localeIdentifier: localeIdentifier) {
            return "speech-analyzer"
        }
        // The legacy recognizer needs Speech Recognition permission. A test runner
        // may never get an answer to the request, so wait at most 15 s for one.
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
            for _ in 0..<150 where SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let authorization = SFSpeechRecognizer.authorizationStatus()
        guard authorization == .authorized else {
            throw NSError(domain: "speech_eval", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "legacy recognizer needs Speech Recognition permission for the test runner (status \(authorization.rawValue))"])
        }
        return try await runOnCaptureQueue {
            try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            return self.speechRecognizer?.supportsOnDeviceRecognition == true ? "legacy-on-device" : "legacy-server"
        }
    }

    func evalReplay(_ buffer: AVAudioPCMBuffer) {
        captureQueue.async { self.append(audioBuffer: buffer) }
    }
}
'''

YIELD = 'continuation.yield(AnalyzerInput(buffer: analyzerBuffer))'
# Optional: log transcriber results with word times, so reissued audio shows up in
# events.jsonl (finals as kind "F"; with --trace, volatile results as kind "V").
RESULT = 'private func processModernRecognitionResult(_ result: SpeechTranscriber.Result) {'
RESULT_HOOK = (RESULT + '\n        v2sEvalResultObserver?(result.isFinal, result.range.start.seconds, '
               'result.range.end.seconds, String(result.text.characters), result.text.runs.map { run in '
               '(String(result.text[run.range].characters), run.audioTimeRange?.start.seconds, '
               'run.audioTimeRange?.end.seconds) })')


def _run(command, **kwargs):
    return subprocess.run(command, shell=False, **kwargs)  # nosec B603


def git_revision(ref='HEAD'):
    return _run(['/usr/bin/git', 'rev-parse', '--short', ref, '--'], cwd=ROOT, check=True,
                capture_output=True, text=True).stdout.split()[0]


def worktree_dirty():
    status = _run(['/usr/bin/git', 'status', '--porcelain', '--', 'Sources', 'Package.swift', 'Package.resolved'],
                  cwd=ROOT, check=True, capture_output=True, text=True).stdout
    return bool(status.strip())


def _write_if_changed(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def prepare(ref=None):
    """Return the package directory ready for xcodebuild."""
    key = f'ref-{git_revision(ref)}' if ref else 'worktree'
    base = EVAL / '.cache' / key
    package = base / 'package'
    package.mkdir(parents=True, exist_ok=True)
    if ref:
        if not (package / 'Package.swift').exists():
            archive = _run(['/usr/bin/git', 'archive', '--format=tar', '--', ref, 'Sources', 'Package.swift',
                            'Package.resolved'], cwd=ROOT, check=True, capture_output=True).stdout
            _run(['/usr/bin/tar', '-x', '-C', str(package)], input=archive, check=True)
        session_source = base / 'LiveTranscriptionSession.original.swift'
        if not session_source.exists():
            shutil.copy2(package / SESSION, session_source)
        original = session_source.read_text()
    else:
        # rsync keeps timestamps, so unchanged files are not recompiled.
        for name in ('Sources', 'Package.swift', 'Package.resolved'):
            source = ROOT / name
            target = package / name
            command = ['/usr/bin/rsync', '-a', '--delete', '--exclude', Path(SESSION).name]
            if source.is_dir():
                command += [f'{source}/', f'{target}/']
            else:
                command += [str(source), str(target)]
            _run(command, check=True)
        original = (ROOT / SESSION).read_text()
    if YIELD not in original:
        raise SystemExit(f'Instrumentation anchor not found in {SESSION}: {YIELD}')
    instrumented = original.replace(
        YIELD, 'if case .dropped = ' + YIELD + ' { v2sEvalDroppedAudioBuffers += 1 }').replace(RESULT, RESULT_HOOK) + HOOKS
    _write_if_changed(package / SESSION, instrumented)
    tests = package / 'Tests/V2STests'
    tests.mkdir(parents=True, exist_ok=True)
    for stale in tests.iterdir():
        if stale.name != 'SpeechEvalHarness.swift':
            stale.unlink()
    _write_if_changed(tests / 'SpeechEvalHarness.swift', (EVAL / 'support/SpeechEvalHarness.swift').read_text())
    return package


def run_test(package, test, plan, plan_path, log_path):
    """Run one harness test with a JSON plan; returns True when xcodebuild succeeded."""
    plan_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n')
    environment = os.environ.copy()
    environment['TEST_RUNNER_V2S_EVAL_PLAN'] = str(plan_path)
    with log_path.open('w') as handle:
        result = _run(['/usr/bin/xcodebuild', '-scheme', 'v2s', '-destination', 'platform=macOS',
                       '-derivedDataPath', str(package.parent / 'derived'), 'COREML_CODEGEN_LANGUAGE=Swift',
                       f'-only-testing:v2sTests/SpeechEvalHarness/{test}', 'test'],
                      cwd=package, env=environment, stdout=handle, stderr=subprocess.STDOUT)
    return result.returncode == 0
