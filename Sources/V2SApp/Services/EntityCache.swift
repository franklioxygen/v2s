import Foundation

/// Session-level cache that locks confirmed entity translations after
/// seeing the same entity translated consistently 2+ times with confidence ≥ 0.90.
actor EntityCache {
    private struct Entry {
        var translation: String
        var occurrences: Int
        var locked: Bool
    }

    private var cache: [String: Entry] = [:]
    private let lockAfterOccurrences = 2
    private let minConfidenceToLock: Float = 0.90

    func record(source: String, translation: String, confidence: Float) {
        if let existingEntry = cache[source], existingEntry.locked {
            return
        }

        var entry = cache[source] ?? Entry(translation: translation, occurrences: 0, locked: false)
        if confidence >= minConfidenceToLock {
            entry.occurrences += 1
        }
        if entry.occurrences >= lockAfterOccurrences {
            entry.locked = true
        }
        entry.translation = translation
        cache[source] = entry
    }

    func lookup(_ source: String) -> String? {
        guard let entry = cache[source], entry.locked else { return nil }
        return entry.translation
    }

    func reset() {
        cache.removeAll()
    }
}
