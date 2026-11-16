import Foundation

/// A presentation-only sentence window. The complete recognizer passage remains
/// in OverlayPreviewState for revisions, contextual translation and finalization.
struct OverlayDraftPage: Equatable {
    let sourceText: String
    let translatedText: String
    let stablePrefixLength: Int
}

struct DraftSentencePager {
    private(set) var index = 0
    private(set) var isPaginated = false
    private var identity: UUID?
    private var pages: [OverlayDraftPage] = []
    private var visibleKey: [String] = []
    private var visibleSince = Date.distantPast

    var current: OverlayDraftPage? {
        isPaginated && pages.indices.contains(index) ? pages[index] : nil
    }

    enum Reading: Equatable {
        /// The pager moved past this page after its reading time.
        case finished
        /// The page on screen, visible with its current text since `since`.
        case current(OverlayDraftPage, since: Date)
    }

    /// What the reader has already seen of one sentence of this draft. A
    /// finalized sentence that no longer matches its page has not been read.
    func reading(ofSentenceAt sentenceIndex: Int, sourceText: String, in id: UUID) -> Reading? {
        guard isPaginated, identity == id, pages.indices.contains(sentenceIndex),
              SentenceTranslationContext.equivalentSource(pages[sentenceIndex].sourceText, sourceText) else { return nil }
        if sentenceIndex < index { return .finished }
        guard sentenceIndex == index, !visibleKey.isEmpty else { return nil }
        return .current(pages[sentenceIndex], since: visibleSince)
    }

    /// `firstPageVisibleSince` is when the first sentence became readable, if it
    /// was already on screen as the whole draft before a second sentence arrived.
    mutating func update(id: UUID, pages newPages: [OverlayDraftPage], paginate: Bool,
                         showsSource: Bool, showsTranslation: Bool, now: Date,
                         firstPageVisibleSince: Date? = nil,
                         readingDuration: (OverlayDraftPage) -> TimeInterval) {
        if identity != id {
            self = DraftSentencePager()
            identity = id
        }
        // A revised earlier sentence must be shown again. Appending/changing the
        // unshown tail must not restart the current sentence's reading clock.
        if let changed = zip(pages, newPages).enumerated().first(where: {
            $0.element.0.sourceText != $0.element.1.sourceText
        })?.offset, changed < index {
            index = changed
            visibleKey = []
        }
        pages = newPages
        let wasPaginated = isPaginated
        isPaginated = (isPaginated || paginate) && pages.count > 1
        guard !pages.isEmpty else { index = 0; return }
        index = min(index, pages.count - 1)
        guard isPaginated else { return }
        func key(_ page: OverlayDraftPage) -> [String] {
            [showsSource ? page.sourceText : "", showsTranslation ? page.translatedText : ""]
        }
        if !wasPaginated, index == 0 {
            visibleKey = key(pages[0])
            visibleSince = min(now, firstPageVisibleSince ?? now)
        }
        let page = pages[index]
        if visibleKey != key(page) {
            visibleKey = key(page)
            visibleSince = now
        }
        if showsTranslation && page.translatedText.isEmpty { visibleSince = now }
        guard now.timeIntervalSince(visibleSince) >= readingDuration(page),
              pages.indices.contains(index + 1),
              !showsTranslation || !pages[index + 1].translatedText.isEmpty else { return }
        index += 1
        visibleKey = key(pages[index])
        visibleSince = now
    }

    /// Only explicit sentence endings are eligible. A comma, decimal, title or
    /// unfinished clause must never turn into an extra subtitle page.
    static func sentences(in text: String) -> [String] {
        let parts = SentenceTranslationContext.splitSentences(text)
        guard parts.count > 1 else { return [text] }
        for (index, part) in parts.dropLast().enumerated() {
            let body = part.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’」』）)]}"))
            guard body.last.map({ ".。!?！？".contains($0) }) == true,
                  SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: body, followedBy: parts[index + 1]) else {
                return [text]
            }
        }
        return parts
    }
}

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

    /// Keep a provisional translation visible until the final caption has one.
    /// Its text remains draft-only: it may belong to an earlier source revision.
    var isAwaitingCommittedTranslation: Bool {
        guard hasActiveDraftLayer, let draftPromotionID,
              draftPromotionID == committedPromotionID,
              translatedText.isEmpty else { return false }
        return visibleDraftTranslatedText(for: draftSourceText ?? "", promotionID: draftPromotionID) != nil
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
