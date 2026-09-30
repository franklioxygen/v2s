import XCTest
@testable import v2s

final class LanguageCatalogTests: XCTestCase {
    // A language keeps a single locale, and the winner used to be whichever identifier
    // sorted first — which can be a variant with no on-device model.
    func testOptionsKeepPreferredLocaleForALanguage() {
        let locales = [Locale(identifier: "fr-BE"), Locale(identifier: "fr-FR")]

        let unprioritized = LanguageCatalog.options(for: locales)
        XCTAssertEqual(unprioritized.first(where: { $0.id == "fr" })?.localeIdentifier, "fr-BE")

        let prioritized = LanguageCatalog.options(for: locales, preferring: ["fr-FR"])
        XCTAssertEqual(prioritized.first(where: { $0.id == "fr" })?.localeIdentifier, "fr-FR")
    }

    func testOptionsIgnorePreferenceForOtherLanguages() {
        let options = LanguageCatalog.options(
            for: [Locale(identifier: "fr-BE"), Locale(identifier: "fr-FR"), Locale(identifier: "it-CH")],
            preferring: ["fr-FR"]
        )

        XCTAssertEqual(options.first(where: { $0.id == "it" })?.localeIdentifier, "it-CH")
        XCTAssertEqual(options.filter { $0.id == "fr" }.count, 1)
    }

    func testSpeechInputLanguagesUseSpeechAnalyzerSupportedDefaults() {
        let expectedLocaleIdentifiers: [String: String] = [
            "en": "en-US",
            "zh-Hans": "zh-CN",
            "zh-Hant": "zh-TW",
            "yue": "yue-CN",
            "es": "es-ES",
            "de": "de-DE",
            "ja": "ja-JP",
            "fr": "fr-FR",
            "it": "it-IT",
            "ko": "ko-KR",
            "pt": "pt-BR",
            "ar": "ar-SA",
            "ca": "ca-ES",
            "cs": "cs-CZ",
            "da": "da-DK",
            "fi": "fi-FI",
            "el": "el-GR",
            "he": "he-IL",
            "hi": "hi-IN",
            "hr": "hr-HR",
            "hu": "hu-HU",
            "id": "id-ID",
            "ms": "ms-MY",
            "nb": "nb-NO",
            "nl": "nl-NL",
            "pl": "pl-PL",
            "ro": "ro-RO",
            "ru": "ru-RU",
            "sk": "sk-SK",
            "sv": "sv-SE",
            "th": "th-TH",
            "tr": "tr-TR",
            "uk": "uk-UA",
            "vi": "vi-VN",
        ]

        XCTAssertEqual(
            Set(LanguageCatalog.speechInput.map(\.id)),
            Set(expectedLocaleIdentifiers.keys)
        )

        for option in LanguageCatalog.speechInput {
            XCTAssertEqual(
                LanguageCatalog.speechLocaleIdentifier(for: option.id),
                expectedLocaleIdentifiers[option.id]
            )
        }
    }

    func testTranslationCatalogIncludesAdditionalDestinationLanguages() {
        let expectedLanguageIDs = [
            "en", "zh-Hans", "zh-Hant", "es", "de", "ja", "fr", "ko", "ar", "pt", "ru",
            "it", "nl", "id", "th", "tr", "pl", "uk", "vi", "hi", "da", "nb", "sv",
        ]

        XCTAssertEqual(
            Set(LanguageCatalog.common.map(\.id)),
            Set(expectedLanguageIDs)
        )
    }

    func testTranslationLocaleIdentifiersUseStableRegionalDefaults() {
        XCTAssertEqual(LanguageCatalog.translationLocaleIdentifier(for: "zh-Hans"), "zh-CN")
        XCTAssertEqual(LanguageCatalog.translationLocaleIdentifier(for: "zh-Hant"), "zh-TW")
        XCTAssertEqual(LanguageCatalog.translationLocaleIdentifier(for: "nb"), "nb-NO")
        XCTAssertEqual(LanguageCatalog.translationLocaleIdentifier(for: "en"), "en-US")
    }

    func testRuntimeLocaleOptionsCollapseRegionsAndPreserveChineseScripts() {
        let options = LanguageCatalog.options(for: [
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
            Locale(identifier: "zh-CN"),
            Locale(identifier: "zh-TW"),
            Locale(identifier: "sr-Cyrl-RS"),
            Locale(identifier: "sr-Latn-RS"),
            Locale(identifier: "fa-IR"),
        ])

        XCTAssertEqual(options.filter { $0.id == "en" }.count, 1)
        XCTAssertNotNil(options.first(where: { $0.id == "en" })?.localeIdentifier)
        XCTAssertTrue(options.contains(where: { $0.id == "zh-Hans" }))
        XCTAssertTrue(options.contains(where: { $0.id == "zh-Hant" }))
        XCTAssertTrue(options.contains(where: { $0.id == "sr-Latn" }))
        XCTAssertTrue(options.contains(where: { $0.id == "fa" }))
    }

    func testRuntimeTranslationOptionsRetainFrameworkLocaleIdentifier() throws {
        let options = LanguageCatalog.options(for: [
            Locale.Language(identifier: "pt-BR"),
            Locale.Language(identifier: "zh-TW"),
        ])

        let portugueseIdentifier = try XCTUnwrap(
            options.first(where: { $0.id == "pt" })?.localeIdentifier
        )
        let traditionalChineseIdentifier = try XCTUnwrap(
            options.first(where: { $0.id == "zh-Hant" })?.localeIdentifier
        )
        XCTAssertTrue(
            Locale.Language(identifier: portugueseIdentifier)
                .isEquivalent(to: Locale.Language(identifier: "pt-BR"))
        )
        XCTAssertTrue(
            Locale.Language(identifier: traditionalChineseIdentifier)
                .isEquivalent(to: Locale.Language(identifier: "zh-TW"))
        )
    }

    func testUnsupportedStoredSpeechInputFallsBackToEnglish() {
        XCTAssertEqual(LanguageCatalog.supportedSpeechInputLanguageID(for: "xx"), "en")
        XCTAssertEqual(LanguageCatalog.supportedSpeechInputLanguageID(for: "it"), "it")
    }
}
