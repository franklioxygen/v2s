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
    private(set) var draftTranslatedText: String? = nil
    private(set) var draftTranslationSourceText: String? = nil
    private(set) var draftTranslationPromotionID: UUID? = nil
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

    mutating func setDraftTranslation(_ translatedText: String?, sourceText: String, promotionID: UUID?) {
        guard let translatedText, translatedText.isEmpty == false else {
            clearDraftTranslation()
            return
        }

        self.draftTranslatedText = translatedText
        self.draftTranslationSourceText = sourceText
        self.draftTranslationPromotionID = promotionID
    }

    mutating func clearDraftTranslation() {
        draftTranslatedText = nil
        draftTranslationSourceText = nil
        draftTranslationPromotionID = nil
    }

    mutating func clearDraftTranslationIfMismatched(sourceText: String, promotionID: UUID?) {
        guard draftTranslatedText != nil else {
            return
        }

        if visibleDraftTranslatedText(for: sourceText, promotionID: promotionID) == nil {
            clearDraftTranslation()
        }
    }

    func currentDraftTranslatedText(for sourceText: String, promotionID: UUID?) -> String? {
        guard let draftTranslatedText,
              draftTranslatedText.isEmpty == false,
              draftTranslationSourceText == sourceText,
              draftTranslationPromotionID == promotionID else {
            return nil
        }

        return draftTranslatedText
    }

    /// Promote only the translation belonging to this caption. For a split passage,
    /// retain its context without putting the entire paragraph on the first caption.
    func promotableDraftTranslatedText(
        for sourceText: String,
        promotionID: UUID?,
        context: SentenceTranslationContext? = nil
    ) -> String? {
        guard let promotionID, draftTranslationPromotionID == promotionID,
              let draftTranslationSourceText, let draftTranslatedText,
              !draftTranslatedText.isEmpty else { return nil }
        if let context, context.draftSegmentID == promotionID,
           context.matchesCaption(sourceText), context.matchesPassage(draftTranslationSourceText) {
            return context.translatedSentence(from: draftTranslatedText)
        }
        return SentenceTranslationContext.equivalentSource(draftTranslationSourceText, sourceText)
            ? draftTranslatedText : nil
    }

    func visibleDraftTranslatedText(for sourceText: String, promotionID: UUID?) -> String? {
        guard let draftTranslatedText,
              draftTranslatedText.isEmpty == false,
              draftTranslationPromotionID == promotionID else {
            return nil
        }

        if promotionID != nil {
            return draftTranslatedText
        }

        return draftTranslationSourceText == sourceText ? draftTranslatedText : nil
    }
}
