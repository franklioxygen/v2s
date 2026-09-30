import AVFoundation
import CoreAudio
import XCTest
@testable import v2s

final class ApplicationCaptureRecoveryPolicyTests: XCTestCase {
    func testFailedRebuildsBackOffThenGiveUp() {
        var policy = ApplicationCaptureRecoveryPolicy()

        let delays = (0..<ApplicationCaptureRecoveryPolicy.failedRebuildRetryDelays.count).map { _ in
            policy.delayAfterFailedRebuild()
        }

        XCTAssertEqual(delays, ApplicationCaptureRecoveryPolicy.failedRebuildRetryDelays)
        XCTAssertNil(policy.delayAfterFailedRebuild())
    }

    func testSuccessfulRebuildRestoresRetries() {
        var policy = ApplicationCaptureRecoveryPolicy()
        _ = policy.delayAfterFailedRebuild()
        _ = policy.delayAfterFailedRebuild()

        policy.recordSuccessfulRebuild()

        XCTAssertEqual(policy.delayAfterFailedRebuild(), ApplicationCaptureRecoveryPolicy.failedRebuildRetryDelays[0])
    }

    // An app that keeps its output open without sound must not be rebuilt every few
    // seconds, so each silent capture waits longer, up to the last window.
    func testSilenceWindowGrowsWhileCapturesStaySilentAndCaps() {
        var policy = ApplicationCaptureRecoveryPolicy()
        var windows = [policy.silenceWindow]

        for _ in 0..<ApplicationCaptureRecoveryPolicy.silenceWindows.count {
            policy.recordSilentCapture()
            windows.append(policy.silenceWindow)
        }

        XCTAssertEqual(
            windows,
            ApplicationCaptureRecoveryPolicy.silenceWindows + [ApplicationCaptureRecoveryPolicy.silenceWindows.last!]
        )
    }

    func testAudibleCaptureResetsSilenceWindow() {
        var policy = ApplicationCaptureRecoveryPolicy()
        policy.recordSilentCapture()
        policy.recordSilentCapture()

        policy.recordAudibleCapture()

        XCTAssertEqual(policy.silenceWindow, ApplicationCaptureRecoveryPolicy.silenceWindows[0])
    }

    func testRebuildsAreRefusedUntilTheWindowHasRoom() {
        var policy = ApplicationCaptureRecoveryPolicy()
        fillAllowance(.recovery, of: &policy)

        // The oldest rebuild, at 0 s, leaves the window at `rebuildWindow`.
        XCTAssertEqual(policy.admitRebuild(.recovery, at: 10), ApplicationCaptureRecoveryPolicy.rebuildWindow - 10)
    }

    func testRebuildsOutsideTheWindowNoLongerCount() {
        var policy = ApplicationCaptureRecoveryPolicy()
        fillAllowance(.recovery, of: &policy)

        XCTAssertNil(policy.admitRebuild(.recovery, at: ApplicationCaptureRecoveryPolicy.rebuildWindow + 1))
    }

    // Helper processes coming and going must not use up the rebuilds that a capture
    // which stopped working needs, and the reverse.
    func testProcessChangesHaveTheirOwnAllowance() {
        var policy = ApplicationCaptureRecoveryPolicy()
        fillAllowance(.processChange, of: &policy)

        XCTAssertNotNil(policy.admitRebuild(.processChange, at: 10))
        XCTAssertNil(policy.admitRebuild(.recovery, at: 10))
    }

    private func fillAllowance(
        _ kind: ApplicationCaptureRecoveryPolicy.RebuildKind,
        of policy: inout ApplicationCaptureRecoveryPolicy
    ) {
        for second in 0..<ApplicationCaptureRecoveryPolicy.maximumRebuildsPerWindow {
            XCTAssertNil(policy.admitRebuild(kind, at: TimeInterval(second)))
        }
    }
}

final class ApplicationCaptureBufferLayoutTests: XCTestCase {
    private let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: true
    )!
    private let stereoNonInterleavedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    func testTapOnlyBufferListMatches() {
        withBufferList([.init(frames: 512)]) { buffers in
            XCTAssertTrue(ApplicationCaptureBufferLayout.matches(buffers, format: monoFormat))
        }
    }

    // What the IO cycle delivered when the aggregate device included the default output:
    // a headset's microphone ahead of the tap.
    func testLeadingSubDeviceBufferDoesNotMatch() {
        withBufferList([.init(frames: 512), .init(frames: 512)]) { buffers in
            XCTAssertFalse(ApplicationCaptureBufferLayout.matches(buffers, format: monoFormat))
        }
    }

    func testChannelCountChangeDoesNotMatch() {
        withBufferList([.init(frames: 512, channels: 2)]) { buffers in
            XCTAssertFalse(ApplicationCaptureBufferLayout.matches(buffers, format: monoFormat))
        }
    }

    func testPartialFrameDoesNotMatch() {
        withBufferList([.init(frames: 512, extraBytes: 2)]) { buffers in
            XCTAssertFalse(ApplicationCaptureBufferLayout.matches(buffers, format: monoFormat))
        }
    }

    func testNonInterleavedStreamNeedsOneEqualBufferPerChannel() {
        withBufferList([.init(frames: 256), .init(frames: 256)]) { buffers in
            XCTAssertTrue(ApplicationCaptureBufferLayout.matches(buffers, format: stereoNonInterleavedFormat))
        }

        withBufferList([.init(frames: 256), .init(frames: 128)]) { buffers in
            XCTAssertFalse(ApplicationCaptureBufferLayout.matches(buffers, format: stereoNonInterleavedFormat))
        }
    }

    func testDigitalSilenceHasNoSignal() {
        withBufferList([.init(frames: 512, sample: 0)]) { buffers in
            XCTAssertFalse(ApplicationCaptureBufferLayout.containsSignal(buffers, format: monoFormat))
        }

        withBufferList([.init(frames: 512, sample: ApplicationCaptureBufferLayout.silenceThreshold / 2)]) { buffers in
            XCTAssertFalse(ApplicationCaptureBufferLayout.containsSignal(buffers, format: monoFormat))
        }
    }

    // Comfort noise in a quiet call sits around -80 dBFS and must count as signal.
    func testQuietAudioHasSignal() {
        withBufferList([.init(frames: 512, sample: 1e-4)]) { buffers in
            XCTAssertTrue(ApplicationCaptureBufferLayout.containsSignal(buffers, format: monoFormat))
        }
    }

    func testNonFloatFormatIsAssumedToHaveSignal() {
        let int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!

        withBufferList([.init(frames: 512, sample: 0)]) { buffers in
            XCTAssertTrue(ApplicationCaptureBufferLayout.containsSignal(buffers, format: int16Format))
        }
    }

    private struct BufferSpec {
        var frames: Int
        var channels: UInt32 = 1
        var extraBytes = 0
        var sample: Float = 0
    }

    private func withBufferList(_ specs: [BufferSpec], _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        let buffers = AudioBufferList.allocate(maximumBuffers: specs.count)
        var allocations: [UnsafeMutableRawPointer] = []

        for (index, spec) in specs.enumerated() {
            let sampleCount = spec.frames * Int(spec.channels)
            let byteCount = sampleCount * MemoryLayout<Float>.size + spec.extraBytes
            let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
            data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            data.bindMemory(to: Float.self, capacity: sampleCount).update(repeating: spec.sample, count: sampleCount)
            allocations.append(data)
            buffers[index] = AudioBuffer(mNumberChannels: spec.channels, mDataByteSize: UInt32(byteCount), mData: data)
        }

        defer {
            allocations.forEach { $0.deallocate() }
            free(buffers.unsafeMutablePointer)
        }

        body(buffers)
    }
}

final class ApplicationCaptureRebuildScheduleTests: XCTestCase {
    func testRouteChangeSupersedesRefreshAlreadyResolvingProcesses() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let refresh = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        // The refresh has dispatched its MainActor lookup when the route changes.
        XCTAssertTrue(schedule.beginResolving(refresh))
        let rebuild = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))

        XCTAssertFalse(schedule.finish(refresh))
        XCTAssertEqual(schedule.current, rebuild)
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.finish(rebuild))
        // An invalidation from the replacement capture must not be swallowed.
        XCTAssertNotNil(schedule.schedule(onlyIfProcessesChanged: false))
    }

    func testNotificationsCoalesceUntilProcessResolutionFinishes() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let rebuild = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.finish(rebuild))
        XCTAssertNil(schedule.current)
        XCTAssertFalse(schedule.finish(rebuild))
    }

    func testStopCancelsResolutionWithoutAffectingNewSession() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let old = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        schedule.cancel()
        let next = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertFalse(schedule.finish(old))
        XCTAssertEqual(schedule.current, next)
        XCTAssertTrue(schedule.finish(next))
    }

    func testFailedAttemptCanReserveRetryAndIgnoreProcessChurn() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let attempt = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertTrue(schedule.finish(attempt))
        let retry = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertEqual(schedule.current, retry)
    }

    // A process that registers after the lookup took its snapshot would otherwise stay
    // untapped until some later process-list change.
    func testProcessChangeDuringResolutionRequestsFollowUpRefresh() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let refresh = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.beginResolving(refresh))

        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.finish(refresh))

        XCTAssertTrue(schedule.takeFollowUpRefresh())
        XCTAssertFalse(schedule.takeFollowUpRefresh())
    }

    func testProcessChangeBeforeResolutionIsCoveredByThePendingLookup() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let refresh = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))

        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.beginResolving(refresh))
        XCTAssertTrue(schedule.finish(refresh))

        XCTAssertFalse(schedule.takeFollowUpRefresh())
    }

    // The rebuild that supersedes a resolving refresh looks the processes up afterwards,
    // so the refresh's missed change is already covered.
    func testRebuildSupersedingAResolvingRefreshDropsItsFollowUp() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let refresh = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.beginResolving(refresh))
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))

        let rebuild = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))

        XCTAssertFalse(schedule.beginResolving(refresh))
        XCTAssertTrue(schedule.beginResolving(rebuild))
        XCTAssertTrue(schedule.finish(rebuild))
        XCTAssertFalse(schedule.takeFollowUpRefresh())
    }

    // A new capture always schedules a reconciliation after installing its listeners.
    // A real route failure must still supersede that pending reconciliation immediately.
    func testPostStartRefreshDoesNotDelayRecovery() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let replacement = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertTrue(schedule.beginResolving(replacement))
        XCTAssertTrue(schedule.finish(replacement))

        let reconciliation = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        let recovery = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertFalse(schedule.beginResolving(reconciliation))
        XCTAssertFalse(schedule.finish(reconciliation))
        XCTAssertEqual(schedule.current, recovery)
        XCTAssertTrue(schedule.beginResolving(recovery))
        XCTAssertTrue(schedule.finish(recovery))
    }

    func testObsoleteCompletionDoesNotConsumeNewRequestsFollowUp() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let oldRefresh = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.beginResolving(oldRefresh))
        let recovery = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: false))
        XCTAssertTrue(schedule.beginResolving(recovery))
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))

        XCTAssertFalse(schedule.finish(oldRefresh))
        XCTAssertTrue(schedule.needsFollowUpRefresh)
        XCTAssertTrue(schedule.finish(recovery))
        XCTAssertTrue(schedule.takeFollowUpRefresh())
        XCTAssertFalse(schedule.takeFollowUpRefresh())
    }

    func testCancelDropsPendingFollowUp() throws {
        var schedule = ApplicationCaptureRebuildSchedule()
        let refresh = try XCTUnwrap(schedule.schedule(onlyIfProcessesChanged: true))
        XCTAssertTrue(schedule.beginResolving(refresh))
        XCTAssertNil(schedule.schedule(onlyIfProcessesChanged: true))

        schedule.cancel()

        XCTAssertFalse(schedule.takeFollowUpRefresh())
        XCTAssertNotNil(schedule.schedule(onlyIfProcessesChanged: true))
    }
}

final class ApplicationCaptureHealthTests: XCTestCase {
    func testSignalResetsActiveTimeoutAfterLongSilentBackoff() {
        var health = ApplicationCaptureHealth(silenceWindow: 60)
        health.start(at: 0)
        XCTAssertFalse(health.recordCycle(at: 20, hasSignal: false))
        XCTAssertNil(health.check(at: 20, isAppPlaying: true))

        XCTAssertTrue(health.recordCycle(at: 21, hasSignal: true))
        XCTAssertFalse(health.recordCycle(at: 22, hasSignal: true))
        XCTAssertEqual(health.silenceWindow, baseSilenceWindow)
        let afterWindow = 22 + baseSilenceWindow + 1
        _ = health.recordCycle(at: afterWindow, hasSignal: false)
        XCTAssertEqual(health.check(at: afterWindow, isAppPlaying: true), .silentWhileAppIsPlaying)
    }

    func testIdleAppDoesNotStallOrAccumulateSilenceTime() {
        var health = ApplicationCaptureHealth(silenceWindow: baseSilenceWindow)
        health.start(at: 0)
        // Playing again at 100 s: the idle stretch before it counts for nothing.
        XCTAssertNil(health.check(at: 100, isAppPlaying: false))
        XCTAssertNil(health.check(at: 101, isAppPlaying: true))
        _ = health.recordCycle(at: 100 + baseSilenceWindow - 1, hasSignal: false)
        XCTAssertNil(health.check(at: 100 + baseSilenceWindow - 1, isAppPlaying: true))
        _ = health.recordCycle(at: 100 + baseSilenceWindow + 1, hasSignal: false)
        XCTAssertEqual(health.check(at: 100 + baseSilenceWindow + 1, isAppPlaying: true), .silentWhileAppIsPlaying)
    }

    func testPlayingAppWithoutIOStallsBeforeSilenceTimeout() {
        let stallTimeout = ApplicationCaptureHealth.stallTimeout
        var health = ApplicationCaptureHealth(silenceWindow: 60)
        health.start(at: 10)
        XCTAssertNil(health.check(at: 10 + stallTimeout, isAppPlaying: true))
        XCTAssertEqual(health.check(at: 10 + stallTimeout + 1, isAppPlaying: true), .stalled)
    }

    private var baseSilenceWindow: TimeInterval {
        ApplicationCaptureRecoveryPolicy.silenceWindows[0]
    }
}
