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
