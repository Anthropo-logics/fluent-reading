import XCTest

/// Structural checks over the shipped string catalog: help, known limits and privacy must exist in
/// the three supported localizations, and no product text may claim clinical or guaranteed results
/// (NFR12).
final class LocalizationContentTests: XCTestCase {
  private static let languages = ["en", "es", "pt"]

  /// The name the product carries in each language — the same one its bundle declares in
  /// `<language>.lproj/InfoPlist.strings`.
  private static let productName = [
    "en": "Fluent Reading", "es": "Lectura Fluida", "pt": "Leitura Fluída",
  ]

  /// Spellings that belong to no language: the Portuguese name stripped of its accent.
  private static let strayProductNames = ["Leitura Fluida"]

  private static let helpKeys = [
    "help.action", "help.title", "help.usage.title", "help.open", "help.narrate", "help.export",
    "help.storage", "help.keyboard",
  ]

  private static let limitsKeys = [
    "limits.title", "limits.translation", "limits.languages", "limits.export_secondary",
    "limits.resources", "limits.format", "limits.content",
  ]

  private static let privacyKeys = [
    "privacy.title", "privacy.local", "privacy.network", "privacy.no_upload",
    "privacy.no_telemetry", "privacy.permissions", "privacy.storage",
  ]

  /// The title and body of every step of `tutorialSteps` (Stories 5.10 and 6.10). A step whose key
  /// is missing from the catalog does not fail to build: the card shows the raw key, which is only
  /// visible by opening the tutorial in the running app.
  private static let tutorialKeys = [
    "tutorial.welcome.title", "tutorial.welcome.body",
    "tutorial.views.title", "tutorial.views.body",
    "tutorial.start_reading.pdf.title", "tutorial.start_reading.pdf.body",
    "tutorial.start_reading.immersion.title", "tutorial.start_reading.immersion.body",
    "tutorial.transport.title", "tutorial.transport.body",
    "tutorial.voice.title", "tutorial.voice.body",
    "tutorial.translate.title", "tutorial.translate.body",
    "tutorial.export.title", "tutorial.export.body",
    "tutorial.finish.title", "tutorial.finish.body",
  ]

  /// Story 6.10 AC3 (and AC7 of Story 5.10): a step may only name controls that exist. Each pair is
  /// a tutorial body and a control it names; the body must quote that control's *own* localized
  /// label, in the same language. The English tutorial called the narration switch "Traducción",
  /// a label that only exists in Spanish — the kind of drift this pins down.
  private static let tutorialControlReferences = [
    ("tutorial.voice.body", "voice.action"),
    ("tutorial.translate.body", "translation.action"),
    ("tutorial.translate.body", "narration.source"),
    ("tutorial.translate.body", "narration.source.original"),
    ("tutorial.translate.body", "narration.source.translation"),
    ("tutorial.export.body", "export.action"),
    ("tutorial.export.body", "narration.source.original"),
    ("tutorial.export.body", "narration.source.translation"),
  ]

  /// NFR12: the product language never presents bimodal reading as a treatment, nor guarantees
  /// improvements in attention, retention or visual fatigue.
  private static let prohibitedTerms = [
    "trata", "tratar", "tratamiento", "tratamento", "terapia", "terapéutico", "terapêutico",
    "cura", "curar", "diagnóstico", "diagnostico", "diagnosticar", "garantiza", "garantizado",
    "garantido", "garante", "treat", "treats", "treatment", "therapy", "therapeutic", "cure",
    "cures", "diagnosis", "diagnose", "guarantee", "guaranteed",
  ]

  /// Story 6.3 AC6: no interface string from Epics 1–5 — the tutorial of Story 5.10 included — may
  /// ship untranslated. Checking the whole catalog, not a hand-kept list of keys, is what makes
  /// this hold for keys added later too.
  func testEveryCatalogKeyIsTranslatedInEverySupportedLanguage() throws {
    let strings = try Self.catalogStrings()
    XCTAssertFalse(strings.isEmpty, "unreadable string catalog")

    for (key, entry) in strings {
      let localizations = try XCTUnwrap(
        (entry as? [String: Any])?["localizations"] as? [String: Any],
        "no localizations at all: \(key)")
      for language in Self.languages {
        let unit = try XCTUnwrap(
          (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
          "missing \(language) localization: \(key)")
        XCTAssertEqual(unit["state"] as? String, "translated", "untranslated \(language): \(key)")
        XCTAssertFalse(
          ((unit["value"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty,
          "empty \(language) value: \(key)")
      }
    }
  }

  /// Story 6.3 AC2: the visible name of the app is a translation per language, the way Preview is
  /// "Vista Previa" in Spanish — not the Spanish name repeated in the other two.
  func testApplicationNameIsLocalizedPerLanguage() throws {
    let expected = Self.productName
    let resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("LecturaMacApp/Resources")

    for language in Self.languages {
      let url = resources.appendingPathComponent("\(language).lproj/InfoPlist.strings")
      let data = try Data(contentsOf: url)
      let plist = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
        "missing or unreadable \(language).lproj/InfoPlist.strings")
      XCTAssertEqual(plist["CFBundleDisplayName"], expected[language], "display name: \(language)")
      XCTAssertEqual(plist["CFBundleName"], expected[language], "bundle name: \(language)")
    }

    let catalog = try Self.catalogStrings()
    let title = try XCTUnwrap(
      (catalog["app.title"] as? [String: Any])?["localizations"] as? [String: Any])
    for language in Self.languages {
      let value = ((title[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"]
      XCTAssertEqual(value as? String, expected[language], "app.title: \(language)")
    }
  }

  /// Story 6.23: a catalog of one language may not name the product the way another language does.
  /// The Help menu shipped as "Lectura Fluida Help" in English and the export error of Story 6.17
  /// as "Lectura Fluida cannot write to that destination." — the Spanish name leaking into the
  /// English and Portuguese catalogs, so the reader saw two products where there is one. Sweeping
  /// every value, rather than the four keys that were wrong, is what keeps a fifth from drifting.
  func testEveryLanguageNamesTheProductWithItsOwnName() throws {
    var mentions: [String: Int] = [:]

    for (key, value, language) in try Self.catalogValues() {
      guard Self.languages.contains(language) else { continue }
      let own = try XCTUnwrap(Self.productName[language], "no product name for \(language)")
      if value.contains(own) { mentions[language, default: 0] += 1 }

      for (otherLanguage, otherName) in Self.productName where otherLanguage != language {
        XCTAssertFalse(
          value.contains(otherName),
          "\(key) [\(language)] calls the product by its \(otherLanguage) name "
            + "\"\(otherName)\": \(value)")
      }
      for stray in Self.strayProductNames {
        XCTAssertFalse(
          value.contains(stray),
          "\(key) [\(language)] misspells the product name as \"\(stray)\": \(value)")
      }
    }

    // Without this the sweep above would also pass over a catalog that never names the product.
    for language in Self.languages {
      XCTAssertGreaterThan(
        mentions[language, default: 0], 0,
        "no \(language) value names the product: the sweep proves nothing")
    }
  }

  func testHelpLimitsAndPrivacyAreLocalizedInEverySupportedLanguage() throws {
    let strings = try Self.catalogStrings()
    let required = Self.helpKeys + Self.limitsKeys + Self.privacyKeys + Self.tutorialKeys
    XCTAssertEqual(Set(required).count, required.count)

    for key in required {
      let localizations = try XCTUnwrap(
        (strings[key] as? [String: Any])?["localizations"] as? [String: Any],
        "missing catalog entry: \(key)")
      for language in Self.languages {
        let unit = try XCTUnwrap(
          (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
          "missing \(language) localization: \(key)")
        XCTAssertEqual(unit["state"] as? String, "translated", "untranslated \(language): \(key)")
        let value = (unit["value"] as? String) ?? ""
        XCTAssertFalse(
          value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          "empty \(language) value: \(key)")
      }
    }
  }

  /// Story 6.10 AC3: every control a tutorial step names is quoted with the label that control
  /// really carries in that language.
  func testTutorialStepsNameControlsWithTheirRealLabels() throws {
    let strings = try Self.catalogStrings()

    for (bodyKey, controlKey) in Self.tutorialControlReferences {
      for language in Self.languages {
        let body = try XCTUnwrap(
          Self.value(strings, bodyKey, language), "missing \(language): \(bodyKey)")
        let label = try XCTUnwrap(
          Self.value(strings, controlKey, language), "missing \(language): \(controlKey)")
        XCTAssertTrue(
          body.contains(label),
          "\(bodyKey) [\(language)] does not name \(controlKey) as \"\(label)\": \(body)")
      }
    }
  }

  func testNoProductTextClaimsClinicalOrGuaranteedResults() throws {
    let pattern = "(?i)\\b(\(Self.prohibitedTerms.joined(separator: "|")))\\b"
    let expression = try NSRegularExpression(pattern: pattern)

    for (key, value, language) in try Self.catalogValues() {
      let range = NSRange(value.startIndex..., in: value)
      guard let match = expression.firstMatch(in: value, range: range) else { continue }
      let term = Range(match.range, in: value).map { String(value[$0]) } ?? ""
      XCTFail("NFR12 violation in \(key) [\(language)]: \"\(term)\"")
    }
  }

  private static func catalogStrings() throws -> [String: Any] {
    let catalog = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("LecturaMacApp/Resources/Localizable.xcstrings")
    let root =
      try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any] ?? [:]
    return try XCTUnwrap(root["strings"] as? [String: Any], "unreadable string catalog")
  }

  private static func value(_ strings: [String: Any], _ key: String, _ language: String) -> String?
  {
    guard let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any],
      let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    else { return nil }
    return unit["value"] as? String
  }

  private static func catalogValues() throws -> [(key: String, value: String, language: String)] {
    try catalogStrings().flatMap { key, entry -> [(String, String, String)] in
      let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
      return localizations.compactMap { language, localization in
        guard
          let value = (localization as? [String: Any]).flatMap({
            ($0["stringUnit"] as? [String: Any])?["value"] as? String
          })
        else { return nil }
        return (key, value, language)
      }
    }
  }
}
