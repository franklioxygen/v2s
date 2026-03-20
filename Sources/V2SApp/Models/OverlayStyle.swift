import Foundation

struct OverlayStyle: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case targetDisplayID
        case topInset
        case widthRatio
        case minWidth
        case maxWidth
        case backgroundOpacity
        case usesWhiteTextOutline
        case translatedFontSize
        case sourceFontSize
        case clickThrough
        case translatedFirst
        case overlayScaleFactor
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case usesHighContrastBorder
    }

    var targetDisplayID: String?
    var topInset: Double
    var widthRatio: Double
    var minWidth: Double
    var maxWidth: Double
    var backgroundOpacity: Double
    var usesWhiteTextOutline: Bool
    var translatedFontSize: Double
    var sourceFontSize: Double
    var clickThrough: Bool
    // Retained for backwards compatibility with persisted settings.
    var translatedFirst: Bool
    var overlayScaleFactor: Double

    var scaledTranslatedFontSize: Double { translatedFontSize * overlayScaleFactor }
    var scaledSourceFontSize: Double { sourceFontSize * overlayScaleFactor }

    static let `default` = OverlayStyle(
        targetDisplayID: nil,
        topInset: 12,
        widthRatio: 0.82,
        minWidth: 720,
        maxWidth: 1440,
        backgroundOpacity: 0.32,
        usesWhiteTextOutline: false,
        translatedFontSize: 24,
        sourceFontSize: 18,
        clickThrough: true,
        translatedFirst: true,
        overlayScaleFactor: 1.0
    )

    init(
        targetDisplayID: String?,
        topInset: Double,
        widthRatio: Double,
        minWidth: Double,
        maxWidth: Double,
        backgroundOpacity: Double,
        usesWhiteTextOutline: Bool,
        translatedFontSize: Double,
        sourceFontSize: Double,
        clickThrough: Bool,
        translatedFirst: Bool,
        overlayScaleFactor: Double = 1.0
    ) {
        self.targetDisplayID = targetDisplayID
        self.topInset = topInset
        self.widthRatio = widthRatio
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.backgroundOpacity = backgroundOpacity
        self.usesWhiteTextOutline = usesWhiteTextOutline
        self.translatedFontSize = translatedFontSize
        self.sourceFontSize = sourceFontSize
        self.clickThrough = clickThrough
        self.translatedFirst = translatedFirst
        self.overlayScaleFactor = overlayScaleFactor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        targetDisplayID    = try c.decodeIfPresent(String.self, forKey: .targetDisplayID)
        topInset           = try c.decode(Double.self, forKey: .topInset)
        widthRatio         = try c.decode(Double.self, forKey: .widthRatio)
        minWidth           = try c.decode(Double.self, forKey: .minWidth)
        maxWidth           = try c.decode(Double.self, forKey: .maxWidth)
        backgroundOpacity  = try c.decode(Double.self, forKey: .backgroundOpacity)
        let legacyWhiteOutline = try legacy.decodeIfPresent(Bool.self, forKey: .usesHighContrastBorder)
        usesWhiteTextOutline = try c.decodeIfPresent(Bool.self, forKey: .usesWhiteTextOutline)
            ?? legacyWhiteOutline
            ?? false
        translatedFontSize = try c.decode(Double.self, forKey: .translatedFontSize)
        sourceFontSize     = try c.decode(Double.self, forKey: .sourceFontSize)
        clickThrough       = try c.decode(Bool.self,   forKey: .clickThrough)
        translatedFirst    = try c.decodeIfPresent(Bool.self, forKey: .translatedFirst) ?? true
        overlayScaleFactor = try c.decodeIfPresent(Double.self, forKey: .overlayScaleFactor) ?? 1.0
    }
}
