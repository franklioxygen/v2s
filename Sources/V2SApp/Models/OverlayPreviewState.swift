import Foundation

struct OverlayHistoryEntry: Identifiable, Equatable {
    let id: UUID
    var translatedText: String
    var sourceText: String

    init(id: UUID = UUID(), translatedText: String, sourceText: String) {
        self.id = id
        self.translatedText = translatedText
        self.sourceText = sourceText
    }
}

struct OverlayPreviewState: Equatable {
    // MARK: Committed caption (main display)
    var translatedText: String
    var sourceText: String
    var sourceName: String

    // MARK: Draft layer — partial ASR, shown below committed
    var draftSourceText: String? = nil
    var draftStablePrefixLength: Int = 0
    /// Incremental translation of the current draft text (updates as stable prefix grows).
    var draftTranslatedText: String? = nil
    var draftPromotionID: UUID? = nil

    // MARK: History layer — committed captions the user can scroll back through
    var history: [OverlayHistoryEntry] = []

    // MARK: Caption epoch — increments on each new committed sentence (drives slide-in transition)
    var captionEpoch: Int = 0
    var committedPromotionID: UUID? = nil

    /// When true, the committed layer should appear instantly (no fade-in) because
    /// a draft translation was already visible and is being directly replaced.
    var skipCommittedFadeIn: Bool = false

    // MARK: Derived helpers

    var hasActiveDraftLayer: Bool {
        draftSourceText?.isEmpty == false
    }

    var hasHistory: Bool {
        history.isEmpty == false
    }
}
