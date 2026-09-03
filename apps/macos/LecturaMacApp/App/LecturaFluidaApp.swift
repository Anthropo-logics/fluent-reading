import AppKit
import MacPlatform
import SwiftUI
import os

@main
struct LecturaFluidaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @ObservedObject private var readerSurface = ReaderSurfaceCoordinator.shared

  var body: some Scene {
    WindowGroup(String(localized: "app.title")) {
      ReaderView()
    }
    .defaultSize(width: 900, height: 700)
    .commands {
      // Replacing `.appInfo` puts the panel where macOS readers already look for it — the first
      // item of the application menu — instead of adding a second entry beside the standard one
      // (Story 6.4, AC1).
      CommandGroup(replacing: .appInfo) {
        AboutMenuCommand()
      }
      // Opening a document must never depend on the reading toolbar being visible: the menu bar is
      // the one surface macOS always shows, in every reading mode and at every window size.
      CommandGroup(replacing: .newItem) {
        Button("reader.open") {
          NotificationCenter.default.post(name: .openReaderDocument, object: nil)
        }
        .keyboardShortcut("o", modifiers: .command)
      }
      CommandGroup(replacing: .help) {
        Button("help.action") {
          NotificationCenter.default.post(name: .showReaderHelp, object: nil)
        }
        .keyboardShortcut("?", modifiers: .command)
        Button("tutorial.menu.replay") {
          NotificationCenter.default.post(name: .showReaderTutorial, object: nil)
        }
      }
      // A literal here is a localization key that no catalog entry answers, so the menu title stayed
      // "Lectura" in the English and Portuguese menu bars (Story 6.3, AC6).
      CommandMenu("menu.reading") {
        Group {
          Button("reader.view.toggle") {
            NotificationCenter.default.post(name: .toggleReadingSurface, object: nil)
          }
          .keyboardShortcut("i", modifiers: [.command, .shift])
          Button("reader.processing.cancel") {
            NotificationCenter.default.post(name: .cancelReadingProcessing, object: nil)
          }
          .keyboardShortcut(.cancelAction)
          Button("reader.processing.resume") {
            NotificationCenter.default.post(name: .resumeReadingProcessing, object: nil)
          }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          Button("reader.processing.retry") {
            NotificationCenter.default.post(name: .retryReadingProcessing, object: nil)
          }
          .keyboardShortcut("t", modifiers: [.command, .shift])
          // Turning a page has to live here, in the menu bar, and not only in the ⋯ menu of the
          // toolbar. A `.keyboardShortcut` written inside the content of a SwiftUI `Menu` only draws
          // the glyph beside the item: the key equivalent is never registered, so ⌘] and ⌘[ did
          // nothing at all until the reader opened the menu and clicked (Story 6.15, QA of
          // 2026-08-21). The menu bar is the surface macOS always shows, and the one place a key
          // equivalent actually takes.
          Button("reader.rotate.clockwise") {
            NotificationCenter.default.post(name: .rotateReaderPageClockwise, object: nil)
          }
          .keyboardShortcut("]", modifiers: .command)
          Button("reader.rotate.counterclockwise") {
            NotificationCenter.default.post(name: .rotateReaderPageCounterclockwise, object: nil)
          }
          .keyboardShortcut("[", modifiers: .command)
        }
        // Story 6.24: everything below used to exist only inside the toolbar's ⋯ menu, which is a
        // pointer-only surface — the same trap the rotation commands above were pulled out of. A
        // reader working from the keyboard, or hearing the app through VoiceOver, could not reach
        // Voice, Translate, Export, Storage, the 15-second skips, the speed, the tracking unit, the
        // theme or auto-follow at all. The ⋯ menu keeps all of them; this is the second way in.
        Divider()
        Group {
          Button("voice.action") {
            NotificationCenter.default.post(name: .showReaderVoice, object: nil)
          }
          .keyboardShortcut("v", modifiers: [.command, .shift])
          Button("translation.action") {
            NotificationCenter.default.post(name: .showReaderTranslation, object: nil)
          }
          .keyboardShortcut("t", modifiers: [.command, .option])
          Button("export.action") {
            NotificationCenter.default.post(name: .showReaderExport, object: nil)
          }
          .keyboardShortcut("e", modifiers: [.command, .shift])
          Button("reader.storage") {
            NotificationCenter.default.post(name: .showReaderStorage, object: nil)
          }
          .keyboardShortcut("s", modifiers: [.command, .option])
        }
        .disabled(!readerSurface.isReading)
        Divider()
        Group {
          Button("narration.rewind") {
            NotificationCenter.default.post(name: .seekReaderNarration, object: -15.0)
          }
          .keyboardShortcut(.leftArrow, modifiers: .option)
          Button("narration.forward") {
            NotificationCenter.default.post(name: .seekReaderNarration, object: 15.0)
          }
          .keyboardShortcut(.rightArrow, modifiers: .option)
          // A rate is a choice among several, so it gets a submenu of the menu bar rather than one
          // shortcut per value. A submenu of the menu bar is a real menu: unlike the ⋯ menu, macOS
          // gives it keyboard navigation for free.
          Menu("narration.speed") {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
              Button {
                NotificationCenter.default.post(name: .setReaderNarrationRate, object: rate)
              } label: {
                Text(verbatim: rate == 1.0 ? "1×" : "\(rate.formatted())×")
              }
            }
          }
        }
        .disabled(!readerSurface.isReading)
        Divider()
        Group {
          if readerSurface.translationControlsVisible {
            Menu("translation.text.version") {
              Button("narration.source.original") {
                NotificationCenter.default.post(
                  name: .setReaderVisibleTextVersion, object: "original")
              }
              Button("narration.source.translation") {
                NotificationCenter.default.post(
                  name: .setReaderVisibleTextVersion, object: "translation")
              }
            }
          }
          Menu("narration.source") {
            Button("narration.source.original") {
              NotificationCenter.default.post(name: .setReaderNarrationSource, object: "original")
            }
            Button("narration.source.translation") {
              NotificationCenter.default.post(
                name: .setReaderNarrationSource, object: "translation")
            }
          }
          .disabled(!readerSurface.isReading)
          Menu("reader.unit") {
            Button("reader.unit.paragraph") {
              NotificationCenter.default.post(name: .setReaderTrackingUnit, object: "paragraph")
            }
            Button("reader.unit.sentence") {
              NotificationCenter.default.post(name: .setReaderTrackingUnit, object: "sentence")
            }
          }
          .disabled(!readerSurface.isReading || readerSurface.surface != .immersion)
          Menu("reader.immersion.theme") {
            // The ⋯ menu labels these from the theme's own raw value, untranslated; the same words
            // appear here rather than inventing a second, different name for the same three themes.
            ForEach(["paper", "sepia", "dark"], id: \.self) { theme in
              Button {
                NotificationCenter.default.post(name: .setReaderImmersionTheme, object: theme)
              } label: {
                Text(verbatim: theme.capitalized)
              }
            }
          }
          .disabled(!readerSurface.isReading || readerSurface.surface != .immersion)
          Button("reader.follow.resume") {
            NotificationCenter.default.post(name: .resumeReaderAutoFollow, object: nil)
          }
          .keyboardShortcut("f", modifiers: [.command, .shift])
          .disabled(
            !readerSurface.isReading || readerSurface.surface != .immersion
              || readerSurface.autoFollowEnabled)
        }
      }
    }

    // macOS wires this scene to the application menu and to ⌘, on its own (Story 6.3, AC1).
    Settings {
      SettingsView()
    }

    Window("about.title", id: AboutView.windowID) {
      AboutView()
    }
    .defaultSize(width: 620, height: 640)
  }
}

/// Lets the menu bar know which reader commands have a current target without giving `.commands` a
/// reference to any particular `ReaderView`'s model. Story 6.24 put document and Immersion actions
/// in the menu bar for keyboard access; this shared state keeps those actions from staying enabled
/// when their document, surface or auto-follow target is absent.
@MainActor
final class ReaderSurfaceCoordinator: ObservableObject {
  static let shared = ReaderSurfaceCoordinator()
  @Published var isReading = false
  @Published var surface: ReadingSurface = .pdf
  @Published var autoFollowEnabled = true
  @Published var translationControlsVisible = false
}

@MainActor
final class ExportTerminationCoordinator {
  static let shared = ExportTerminationCoordinator()
  // ponytail: the MVP owns one document/export; replace with per-window jobs if multi-window arrives.
  var isExporting = false
  var pause: (() -> Void)?
}

/// Lets the app ask the reader, on the way out, whether the text recognised while reading should
/// stay inside the document (Story 6.6). Quitting is one of the two moments a document is actually
/// released — the other is opening a different one, which the reader handles on its own.
@MainActor
final class DocumentCloseCoordinator {
  static let shared = DocumentCloseCoordinator()
  /// Read before quitting so a plain quit never takes the slower path, and never risks holding the
  /// app open, when there is nothing to ask about (Story 6.8 is about exactly that risk).
  var hasRecognisedTextToKeep = false
  var confirmKeepingRecognisedText: (() -> Bool)?
  var writeRecognisedText: (() async -> Void)?
}

/// Whether the quit now under way is a restart into another interface language (Story 6.3, AC3).
///
/// Story 6.19: this used to be a property of `AppDelegate`, which the settings pane reached through
/// `NSApp.delegate as? AppDelegate`. That cast returns **nil**: `@NSApplicationDelegateAdaptor`
/// does not put your delegate in `NSApp.delegate`, it puts a SwiftUI object there that forwards to
/// it. So `applicationShouldTerminate` did run on the real `AppDelegate` — and read `false`, because
/// the optional chain in the settings pane had silently written to nothing. "Restart now" quit the
/// app and opened nothing, every time, on Debug and on Release alike. A shared coordinator is how
/// the other two things the quit has to know already travel from a view to the delegate.
@MainActor
final class RestartCoordinator {
  static let shared = RestartCoordinator()
  var restartsAfterTermination = false
  var launchRequestID: UUID?
}

final class AppDelegate: NSObject, NSApplicationDelegate {

  /// Story 6.8: the app was observed not exiting while a document was mid-processing when asked
  /// to terminate (an Apple-Event-based request, the same kind ⌘Q and XCUITest's `.terminate()`
  /// send) — the process id stayed identical across ten launch/terminate cycles in a test loop.
  /// This logs whether the request is even reaching this delegate method, and how long the whole
  /// call takes, so the next person does not have to re-derive that from scratch.
  static let terminationLog = Logger(
    subsystem: "com.lecturafluida.app", category: "termination")

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let requestedAt = ContinuousClock.now
    Self.terminationLog.notice(
      """
      applicationShouldTerminate: invoked, \
      restarts=\(RestartCoordinator.shared.restartsAfterTermination, privacy: .public)
      """)
    defer {
      Self.terminationLog.notice(
        "applicationShouldTerminate: returning after \(requestedAt.duration(to: .now), privacy: .public)"
      )
    }
    let coordinator = ExportTerminationCoordinator.shared
    if coordinator.isExporting {
      let alert = NSAlert()
      alert.messageText = String(localized: "export.quit.title")
      alert.informativeText = String(localized: "export.quit.message")
      alert.addButton(withTitle: String(localized: "export.quit.pause"))
      alert.addButton(withTitle: String(localized: "export.quit.cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else {
        // The reader stayed: a restart requested a moment ago must not fire on the next quit.
        RestartCoordinator.shared.restartsAfterTermination = false
        return .terminateCancel
      }
      coordinator.pause?()
    }
    // Story 6.6: quitting closes the document, and closing the document is when the reader is asked
    // whether the text recognised during the session should stay in the PDF. The question is put
    // here, the same way the export question above is; only an accepted question makes the quit
    // wait, on `.terminateLater`, for a write that cannot finish inside this call. A quit with
    // nothing to ask — every ordinary one — takes exactly the path it took before, which is what
    // keeps Story 6.8 from coming back through this door.
    let documents = DocumentCloseCoordinator.shared
    if documents.hasRecognisedTextToKeep, documents.confirmKeepingRecognisedText?() == true,
      let writeRecognisedText = documents.writeRecognisedText
    {
      Task { @MainActor in
        await writeRecognisedText()
        if RestartCoordinator.shared.restartsAfterTermination {
          self.openReplacementInstance()
        } else {
          NSApp.reply(toApplicationShouldTerminate: true)
        }
      }
      return .terminateLater
    }
    guard RestartCoordinator.shared.restartsAfterTermination else { return .terminateNow }
    openReplacementInstance()
    // Not `.terminateNow`: asking LaunchServices to open the replacement and quitting in the same
    // breath loses the request — verified, the process died and nothing came back. `.terminateLater`
    // keeps this instance alive until the new one has actually launched.
    return .terminateLater
  }

  /// A process reads `AppleLanguages` only at launch, so a new language needs a new process. A
  /// *separate instance* is required because this one has not gone away yet at this point.
  @MainActor
  private func openReplacementInstance() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    let bundleURL = Bundle.main.bundleURL
    let requestID = UUID()
    RestartCoordinator.shared.launchRequestID = requestID
    // Story 6.19: "Restart now" was reported leaving the reader with no application at all, and
    // with nothing in the log to say at which of the three steps it was lost. Each step says so
    // now: the request, the answer LaunchServices gave, and the process that answered it.
    Self.terminationLog.notice("restart: asking to open \(bundleURL.path, privacy: .public)")
    NSWorkspace.shared.openApplication(
      at: bundleURL, configuration: configuration
    ) { application, error in
      let launched = application != nil
      if let application {
        Self.terminationLog.notice(
          "restart: replacement running as pid \(application.processIdentifier, privacy: .public)")
      } else {
        Self.terminationLog.error(
          "restart: no replacement — \(error as NSError?, privacy: .public); staying alive")
      }
      Task { @MainActor in
        guard RestartCoordinator.shared.launchRequestID == requestID else { return }
        RestartCoordinator.shared.launchRequestID = nil
        if launched {
          RestartCoordinator.shared.restartsAfterTermination = false
          NSApp.reply(toApplicationShouldTerminate: true)
        } else {
          Self.cancelFailedRestart()
        }
      }
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(10))
      guard RestartCoordinator.shared.launchRequestID == requestID else { return }
      Self.terminationLog.error("restart: LaunchServices timed out; staying alive")
      Self.cancelFailedRestart()
    }
  }

  @MainActor
  private static func cancelFailedRestart() {
    RestartCoordinator.shared.launchRequestID = nil
    RestartCoordinator.shared.restartsAfterTermination = false
    LanguageRestartReadingStore.clear()
    NSApp.reply(toApplicationShouldTerminate: false)
    let alert = NSAlert()
    alert.messageText = String(localized: "settings.relaunch.failed.title")
    alert.informativeText = String(localized: "settings.relaunch.failed.message")
    alert.addButton(withTitle: String(localized: "settings.relaunch.failed.dismiss"))
    alert.runModal()
  }
}

extension Notification.Name {
  static let openReaderDocument = Self("openReaderDocument")
  static let prepareReaderLanguageRestart = Self("prepareReaderLanguageRestart")
  static let toggleReadingSurface = Self("toggleReadingSurface")
  static let cancelReadingProcessing = Self("cancelReadingProcessing")
  static let resumeReadingProcessing = Self("resumeReadingProcessing")
  static let retryReadingProcessing = Self("retryReadingProcessing")
  static let rotateReaderPageClockwise = Self("rotateReaderPageClockwise")
  static let rotateReaderPageCounterclockwise = Self("rotateReaderPageCounterclockwise")
  static let showReaderHelp = Self("showReaderHelp")
  static let showReaderTutorial = Self("showReaderTutorial")
  // Story 6.24: the menu-bar half of the ⋯ menu. The ones that carry a choice pass it as the
  // notification's object — a `String` rather than the type itself, because `ImmersionTheme` is
  // private to `ReaderView` and the reading surface, not the menu, is what owns these values.
  static let showReaderVoice = Self("showReaderVoice")
  static let showReaderTranslation = Self("showReaderTranslation")
  static let showReaderExport = Self("showReaderExport")
  static let showReaderStorage = Self("showReaderStorage")
  static let seekReaderNarration = Self("seekReaderNarration")
  static let setReaderNarrationRate = Self("setReaderNarrationRate")
  static let setReaderVisibleTextVersion = Self("setReaderVisibleTextVersion")
  static let setReaderNarrationSource = Self("setReaderNarrationSource")
  static let setReaderTrackingUnit = Self("setReaderTrackingUnit")
  static let setReaderImmersionTheme = Self("setReaderImmersionTheme")
  static let resumeReaderAutoFollow = Self("resumeReaderAutoFollow")
}
