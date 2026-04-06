import Foundation

/// Tracks speech rate over a rolling 5-second window to detect fast-speech conditions.
actor SpeedMonitor {
    private struct Record {
        let chars: Int
        let timestampMs: Int
    }

    private var records: [Record] = []
    private let windowMs = 5000

    func record(chars: Int, nowMs: Int) {
        records.append(Record(chars: chars, timestampMs: nowMs))
        prune(nowMs: nowMs)
    }

    /// Characters-per-second over the last 5 s.
    func currentCPS(nowMs: Int) -> Double {
        prune(nowMs: nowMs)
        guard !records.isEmpty else { return 0.0 }
        let total = records.reduce(0) { $0 + $1.chars }
        let earliestTimestamp = records[0].timestampMs
        let spanMs = max(1, min(windowMs, nowMs - earliestTimestamp))
        return Double(total) / Double(spanMs) * 1000.0
    }

    func reset() {
        records.removeAll()
    }

    private func prune(nowMs: Int) {
        records.removeAll { nowMs - $0.timestampMs > windowMs }
    }
}
