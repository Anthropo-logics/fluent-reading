import AppKit
import MacPlatform
import SwiftUI

/// Explicit interface-language switcher (Story 6.3). It lives in the standard `Settings` scene, so
/// macOS itself puts it under the application menu with ⌘, and gives the picker keyboard focus and
/// VoiceOver labels without anything wired by hand (AC1/AC5).
struct SettingsView: View {
  /// The localization this process was actually launched with, captured once before any change can
  /// be written: `Bundle.main.preferredLocalizations` starts reflecting a new `AppleLanguages`
  /// override as soon as it is set, so comparing against it later would answer "no restart needed"
  /// immediately after the reader asked for a different language.
  private static let launchLocalization =
    Bundle.main.preferredLocalizations.first ?? InterfaceLanguage.supportedLocalizations[0]

  @AppStorage(InterfaceLanguage.preferenceKey)
  private var storedLanguage = InterfaceLanguage.system.rawValue
  @State private var restartPostponed = false

  private var selection: InterfaceLanguage {
    InterfaceLanguage(rawValue: storedLanguage) ?? .system
  }

  /// True only when the choice would actually show a different language than the one on screen —
  /// picking "Español" on a Spanish system must not nag about a restart that changes nothing.
  private var needsRestart: Bool {
    InterfaceLanguage.resolvedLocalization(
      for: selection, systemPreferences: InterfaceLanguage.systemPreferences())
      != Self.launchLocalization
  }

  var body: some View {
    Form {
      Picker(selection: $storedLanguage) {
        ForEach(InterfaceLanguage.allCases, id: \.rawValue) { language in
          Text(LocalizedStringKey(language.nameKey)).tag(language.rawValue)
        }
      } label: {
        Text("settings.language.title")
      }
      .accessibilityIdentifier("settings.language")
      .onChange(of: storedLanguage) { _, newValue in
        InterfaceLanguage.apply(InterfaceLanguage(rawValue: newValue) ?? .system, to: .standard)
        restartPostponed = false
      }

      if needsRestart && !restartPostponed {
        restartNotice
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    // Without this the settings window keeps SwiftUI's default height and shows a screenful of
    // empty grey under a single row.
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      // Keeps the stored choice and the override in step if the preference was ever written
      // without going through the picker (a restored backup, `defaults write`).
      InterfaceLanguage.apply(selection, to: .standard)
    }
  }

  /// AC3: the platform limit is stated instead of hidden, together with what a restart costs, so
  /// the reader can finish the current reading first.
  private var restartNotice: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text("settings.relaunch.title")
          .font(.headline)
        Text("settings.relaunch.message")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("settings.relaunch.later") { restartPostponed = true }
            .accessibilityIdentifier("settings.relaunch.later")
          Spacer()
          Button("settings.relaunch.now") { restartIntoSelectedLanguage() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("settings.relaunch.now")
        }
      }
      .padding(4)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.relaunch")
  }

  private func restartIntoSelectedLanguage() {
    // `NSApp.terminate` rather than exiting outright, so the existing quit guard still runs and an
    // export in flight gets its chance to pause and persist before the process goes away (AC3).
    // The delegate opens the replacement only once that guard has agreed to terminate.
    //
    // Story 6.19: this used to be written through `NSApp.delegate as? AppDelegate`, which is `nil`
    // — SwiftUI's `@NSApplicationDelegateAdaptor` keeps its own object in `NSApp.delegate` and
    // forwards to yours. The optional chain wrote to nothing, so the quit guard read `false` and
    // took the ordinary quit: the app closed and never came back. Measured on both a Debug build
    // and a Release build in `/Applications`; the log now says which delegate answered.
    AppDelegate.terminationLog.notice("restart requested by the reader")
    NotificationCenter.default.post(name: .prepareReaderLanguageRestart, object: nil)
    RestartCoordinator.shared.restartsAfterTermination = true
    NSApp.terminate(nil)
  }
}
