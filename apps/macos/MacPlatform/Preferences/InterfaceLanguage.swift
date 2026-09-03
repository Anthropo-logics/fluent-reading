import Foundation

/// The interface language the reader chose explicitly, independently of the system language
/// (Story 6.3, AC1/AC4).
///
/// macOS binds a process to a localization **once, at launch**, from the `AppleLanguages`
/// preference; no public API re-binds a running process to a different one. So a choice here is
/// stored as an `AppleLanguages` override in the app's own preference domain and takes effect on
/// the next launch — which is why the settings pane explains the restart instead of pretending the
/// switch is instant (AC3).
public enum InterfaceLanguage: String, CaseIterable, Sendable {
  /// No override: the app follows the system language, which is what a fresh install does. Without
  /// this case the picker would have to show some arbitrary language as the initial state and the
  /// reader could never get back to following the system after touching it once.
  case system
  case spanish = "es"
  case english = "en"
  case portuguese = "pt"

  /// `UserDefaults` key holding the raw value; also the `@AppStorage` key, so the choice survives
  /// restarts for free (AC4).
  public static let preferenceKey = "interface.language"

  /// The key macOS itself reads at launch to pick a localization.
  public static let appleLanguagesKey = "AppleLanguages"

  /// The localizations the app actually ships — `knownRegions` in the Xcode project, and the three
  /// languages of `Localizable.xcstrings`. The first one is the source language and the fallback.
  public static let supportedLocalizations = ["en", "es", "pt"]

  /// `nil` for `.system`, which is an absence of preference rather than a language.
  public var localizationCode: String? {
    self == .system ? nil : rawValue
  }

  /// Catalog key of the name shown in the picker. Language names stay as endonyms so a reader can
  /// find their own language even when the interface is currently in one they do not read.
  public var nameKey: String {
    switch self {
    case .system: "settings.language.system"
    case .spanish: "settings.language.es"
    case .english: "settings.language.en"
    case .portuguese: "settings.language.pt"
    }
  }

  /// Which shipped localization macOS would resolve this choice to, using the same matching rules
  /// it applies at launch (so `pt-BR` resolves to `pt`, and an unsupported system language falls
  /// back to the source language instead of leaving the app blank).
  public static func resolvedLocalization(
    for selection: InterfaceLanguage,
    systemPreferences: [String]
  ) -> String {
    let preferences = selection.localizationCode.map { [$0] } ?? systemPreferences
    return Bundle.preferredLocalizations(
      from: supportedLocalizations, forPreferences: preferences
    ).first ?? supportedLocalizations[0]
  }

  /// Writes (or clears) the launch-time override. `.system` *removes* the key rather than writing
  /// today's resolved code: writing it would silently freeze the app on whatever language the
  /// system happens to have right now, which is the opposite of "follow the system".
  public static func apply(_ selection: InterfaceLanguage, to defaults: UserDefaults) {
    if let code = selection.localizationCode {
      defaults.set([code], forKey: appleLanguagesKey)
    } else {
      defaults.removeObject(forKey: appleLanguagesKey)
    }
  }

  /// The system's own language order. Read from the global domain on purpose: the app's override
  /// lives in the app domain and shadows the system list, so `Locale.preferredLanguages` would
  /// return the override right after one is written and `.system` would look like it changed
  /// nothing.
  public static func systemPreferences(_ defaults: UserDefaults = .standard) -> [String] {
    let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)
    return (global?[appleLanguagesKey] as? [String]) ?? Locale.preferredLanguages
  }
}

/// One-shot state carried across the process restart required by an interface-language change.
/// It deliberately lives beside `InterfaceLanguage`: ordinary launches must not reopen a document.
public struct LanguageRestartReadingState: Codable, Equatable, Sendable {
  public let documentBookmark: Data
  public let pageIndex: Int
  public let unitID: String?
  public let readingSurface: String
  public let trackingUnit: String
  public let voiceLanguage: String
  public let voiceID: String
  public let narrationRate: Double
  public let narrationSource: String
  public let translationTargetLanguage: String
  public let resumesNarration: Bool

  public init?(
    documentBookmark: Data, pageIndex: Int, unitID: String?, readingSurface: String,
    trackingUnit: String, voiceLanguage: String, voiceID: String, narrationRate: Double,
    narrationSource: String, translationTargetLanguage: String, resumesNarration: Bool
  ) {
    guard !documentBookmark.isEmpty, pageIndex >= 0,
      unitID.map({ !$0.isEmpty }) ?? true,
      ["pdf", "immersion"].contains(readingSurface),
      ["paragraph", "sentence"].contains(trackingUnit),
      narrationRate.isFinite, (0.5...3).contains(narrationRate),
      ["original", "translation"].contains(narrationSource)
    else { return nil }
    self.documentBookmark = documentBookmark
    self.pageIndex = pageIndex
    self.unitID = unitID
    self.readingSurface = readingSurface
    self.trackingUnit = trackingUnit
    self.voiceLanguage = voiceLanguage
    self.voiceID = voiceID
    self.narrationRate = narrationRate
    self.narrationSource = narrationSource
    self.translationTargetLanguage = translationTargetLanguage
    self.resumesNarration = resumesNarration
  }
}

/// The persisted value is consumed before decoding so corrupt or stale data cannot create a launch
/// loop. A normal quit never writes it; a language restart is the only producer.
public enum LanguageRestartReadingStore {
  public static let key = "interface.language.restart-reading-state"

  @discardableResult
  public static func save(
    _ state: LanguageRestartReadingState, defaults: UserDefaults = .standard
  ) -> Bool {
    guard let data = try? JSONEncoder().encode(state) else { return false }
    defaults.set(data, forKey: key)
    return true
  }

  public static func take(defaults: UserDefaults = .standard) -> LanguageRestartReadingState? {
    guard let data = defaults.data(forKey: key) else { return nil }
    defaults.removeObject(forKey: key)
    return try? JSONDecoder().decode(LanguageRestartReadingState.self, from: data)
  }

  public static func clear(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
  }
}
