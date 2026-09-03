import XCTest

@testable import MacPlatform

/// Story 6.3: the explicit interface-language choice (AC1) and how it is stored so it survives a
/// restart (AC4).
final class InterfaceLanguageTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suite = "com.lecturafluida.tests.interface-language"

  override func setUpWithError() throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil
  }

  /// Read the suite's own storage, not `object(forKey:)`: a suite's search list also covers the
  /// global domain, where this Mac really does have an `AppleLanguages` value, so a lookup through
  /// it would report the system's language as if the app had written it.
  private func storedOverride() -> [String]? {
    defaults.persistentDomain(forName: suite)?[InterfaceLanguage.appleLanguagesKey] as? [String]
  }

  /// AC1: an explicit choice wins over the system language, whatever the system happens to be.
  func testExplicitChoiceIgnoresTheSystemLanguage() {
    let systemPreferences = ["fr-FR", "de-DE"]
    let expectations: [(InterfaceLanguage, String)] = [
      (.spanish, "es"), (.english, "en"), (.portuguese, "pt"),
    ]
    for (selection, expected) in expectations {
      XCTAssertEqual(
        InterfaceLanguage.resolvedLocalization(
          for: selection, systemPreferences: systemPreferences),
        expected)
    }
  }

  func testFollowingTheSystemMatchesRegionalVariantsAndFallsBackToTheSourceLanguage() {
    let cases: [([String], String)] = [
      (["pt-BR"], "pt"),
      (["pt-PT"], "pt"),
      (["es-419"], "es"),
      (["es-MX", "en-US"], "es"),
      (["en-GB"], "en"),
      (["fr-FR"], "en"),  // unsupported system language falls back to the source language
      ([], "en"),
    ]
    for (systemPreferences, expected) in cases {
      XCTAssertEqual(
        InterfaceLanguage.resolvedLocalization(for: .system, systemPreferences: systemPreferences),
        expected,
        "system preferences \(systemPreferences)")
    }
  }

  /// AC4: the choice is written where macOS reads it at launch, so it survives restarts.
  func testChoosingALanguageWritesTheLaunchTimeOverride() {
    InterfaceLanguage.apply(.portuguese, to: defaults)
    XCTAssertEqual(storedOverride(), ["pt"])

    InterfaceLanguage.apply(.english, to: defaults)
    XCTAssertEqual(storedOverride(), ["en"])
  }

  /// Going back to "same as the system" must clear the override, not freeze the app on whatever
  /// language the system happens to have today.
  func testFollowingTheSystemAgainClearsTheOverride() {
    InterfaceLanguage.apply(.spanish, to: defaults)
    XCTAssertEqual(storedOverride(), ["es"])

    InterfaceLanguage.apply(.system, to: defaults)
    XCTAssertNil(storedOverride())
  }

  /// The system list has to come from the global domain: the app's own override shadows it, and
  /// reading through the app domain would report the override as if it were the system language.
  func testSystemPreferencesComeFromTheGlobalDomainNotTheAppsOwnOverride() throws {
    let global =
      UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[
        InterfaceLanguage.appleLanguagesKey] as? [String]
    try XCTSkipIf(global == ["pt"], "this Mac's system language is exactly the override under test")

    InterfaceLanguage.apply(.portuguese, to: defaults)
    XCTAssertNotEqual(InterfaceLanguage.systemPreferences(defaults), ["pt"])
    XCTAssertFalse(InterfaceLanguage.systemPreferences(defaults).isEmpty)
  }

  func testEveryChoiceHasADistinctCatalogKeyAndOnlyTheSystemCaseLacksACode() {
    let keys = InterfaceLanguage.allCases.map(\.nameKey)
    XCTAssertEqual(Set(keys).count, keys.count)
    XCTAssertNil(InterfaceLanguage.system.localizationCode)
    XCTAssertEqual(
      InterfaceLanguage.allCases.compactMap(\.localizationCode).sorted(),
      InterfaceLanguage.supportedLocalizations.sorted())
  }

  func testLanguageRestartReadingStateIsValidatedAndConsumedOnce() throws {
    let state = try XCTUnwrap(
      LanguageRestartReadingState(
        documentBookmark: Data("bookmark".utf8), pageIndex: 17, unitID: "unit-42",
        readingSurface: "immersion", trackingUnit: "sentence", voiceLanguage: "es",
        voiceID: "ef_dora", narrationRate: 1.25, narrationSource: "original",
        translationTargetLanguage: "", resumesNarration: true))

    XCTAssertTrue(LanguageRestartReadingStore.save(state, defaults: defaults))
    XCTAssertEqual(LanguageRestartReadingStore.take(defaults: defaults), state)
    XCTAssertNil(LanguageRestartReadingStore.take(defaults: defaults))

    defaults.set(Data("not-json".utf8), forKey: LanguageRestartReadingStore.key)
    XCTAssertNil(LanguageRestartReadingStore.take(defaults: defaults))
    XCTAssertNil(defaults.data(forKey: LanguageRestartReadingStore.key))
    XCTAssertNil(
      LanguageRestartReadingState(
        documentBookmark: Data(), pageIndex: -1, unitID: "", readingSurface: "unknown",
        trackingUnit: "paragraph", voiceLanguage: "", voiceID: "", narrationRate: .infinity,
        narrationSource: "original", translationTargetLanguage: "", resumesNarration: false))
  }

  @MainActor
  func testMalformedBookmarkCannotRestoreAnArbitraryDocument() {
    XCTAssertNil(FileServices.restorePDF(from: Data("not-a-bookmark".utf8)))
  }
}
