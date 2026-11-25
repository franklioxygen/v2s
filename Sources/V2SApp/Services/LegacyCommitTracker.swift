import Foundation
import Speech

/// The parts of an `SFTranscriptionSegment` that commit tracking needs.
struct LegacyTranscriptSegment: Equatable {
    var text: String
    var timestamp: TimeInterval
    var duration: TimeInterval

    init(text: String, timestamp: TimeInterval, duration: TimeInterval) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
    }

    init(_ segment: SFTranscriptionSegment) {
        self.init(text: segment.substring, timestamp: segment.timestamp, duration: segment.duration)
    }

    /// The on-device recognizer leaves timestamp and duration at 0 in almost every
    /// partial result; only the result that closes an utterance carries times.
    var isTimed: Bool { duration > 0 }
    var endTime: TimeInterval { timestamp + duration }

    /// Lowercased words without punctuation. A segment can hold several words
    /// ("A Belarusian") or none: punctuation can arrive as segments of its own that
    /// appear and vanish between results. In scripts written without spaces each
    /// character counts as a word, since the recognizer splits the same text into
    /// segments differently from one result to the next ("明天早上" or "明天", "早上").
    var words: [String] {
        var words: [String] = []
        for token in text.lowercased().split(whereSeparator: \.isWhitespace) {
            var word = String.UnicodeScalarView()
            for scalar in token.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                if Self.isWrittenWithoutSpaces(scalar) {
                    if word.isEmpty == false { words.append(String(word)) }
                    word = String.UnicodeScalarView()
                    words.append(String(scalar))
                } else {
                    word.append(scalar)
                }
            }
            if word.isEmpty == false { words.append(String(word)) }
        }
        return words
    }

    var wordCount: Int { words.count }
    var isWord: Bool { wordCount > 0 }

    /// Han, kana, Thai, Lao, Khmer and Myanmar.
    private static func isWrittenWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,  // kana
             0x0E00...0x0EFF,  // Thai, Lao
             0x1000...0x109F,  // Myanmar
             0x1780...0x17FF:  // Khmer
            return true
        default:
            return false
        }
    }
}

/// Tracks how much of the legacy recognizer's current utterance is already committed.
///
/// Every partial result repeats the utterance so far, so the committed part has to be
/// found again in each one. When the results carry audio times it is found by time;
/// otherwise by counting words. Punctuation segments that come and go, revised or
/// merged words and untimed results then never move the boundary, so text is neither
/// committed twice nor skipped.
struct LegacyCommitTracker {
    static let boundaryToleranceSec: TimeInterval = 0.08

    /// Segments of the latest result that are already committed.
    private(set) var committedSegmentCount = 0
    /// Words of this utterance that are already committed.
    private(set) var committedWordCount = 0
    /// End of the committed audio, known only when the committed segments were timed.
    private(set) var committedAudioEndTime: TimeInterval?

    mutating func reset() {
        self = LegacyCommitTracker()
    }

    /// Marks `segments[...index]` committed.
    mutating func markCommitted(through index: Int, of segments: [LegacyTranscriptSegment]) {
        let committed = segments[...index]
        committedSegmentCount = index + 1
        committedWordCount = committed.reduce(0) { $0 + $1.wordCount }
        committedAudioEndTime = committed.last(where: \.isTimed)?.endTime
    }

    /// Finds the committed part again in a new result of the same utterance.
    /// Returns whether the committed words changed, which means the draft did too.
    @discardableResult
    mutating func align(to segments: [LegacyTranscriptSegment]) -> Bool {
        let previousWordCount = committedWordCount
        if let committedAudioEndTime, segments.contains(where: \.isTimed) {
            let alignedCount = segments.prefix {
                $0.endTime <= committedAudioEndTime + Self.boundaryToleranceSec
            }.count
            committedSegmentCount = alignedCount
            committedWordCount = segments.prefix(alignedCount).reduce(0) { $0 + $1.wordCount }
        } else if committedWordCount == 0 {
            committedSegmentCount = 0
        } else {
            var index = 0
            var words = 0
            while index < segments.count, words < committedWordCount {
                words += segments[index].wordCount
                index += 1
            }
            // Punctuation right after the committed words belongs to them.
            while index < segments.count, segments[index].isWord == false {
                index += 1
            }
            committedSegmentCount = index
        }
        return committedWordCount != previousWordCount
    }

    /// Whether `current` begins a new utterance instead of revising `previous`.
    ///
    /// Without sending isFinal, the on-device recognizer starts its text over after a
    /// pause. A revision keeps most of the text and may change or drop its first word
    /// or two; a new utterance starts again from a word or two of different text.
    func startsNewUtterance(
        previous: [LegacyTranscriptSegment],
        current: [LegacyTranscriptSegment]
    ) -> Bool {
        let previousWords = previous.flatMap(\.words)
        let currentWords = current.flatMap(\.words)
        guard currentWords.count < previousWords.count,
              previousWords.count >= 3 || committedWordCount > 0 else {
            return false
        }
        if Self.opensLikeRevision(currentWords, of: previousWords) {
            // Opens the same way but most of the text is gone: a new utterance that
            // happens to start with the same word.
            return currentWords.count <= 2 && currentWords.count * 4 <= previousWords.count
        }
        return currentWords.count < committedWordCount || currentWords.count * 2 <= previousWords.count
    }

    /// Whether the first or second word of `current`, with the word after it, is found
    /// among the first words of `previous`.
    private static func opensLikeRevision(_ current: [String], of previous: [String]) -> Bool {
        let length = min(2, current.count)
        guard length > 0, previous.count >= length else { return false }
        for currentStart in 0...min(1, current.count - length) {
            let opening = current[currentStart..<currentStart + length]
            for previousStart in 0...min(3, previous.count - length)
            where previous[previousStart..<previousStart + length].elementsEqual(opening) {
                return true
            }
        }
        return false
    }
}
