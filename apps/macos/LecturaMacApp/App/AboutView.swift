import AppKit
import MacPlatform
import SwiftUI

/// "About" panel (Story 6.4, AC1/AC2). A window of its own rather than
/// `orderFrontStandardAboutPanel(options:)`: the credits are a scrollable, selectable inventory of
/// every third-party model and library, and the standard panel's fixed-size credits area cannot
/// show that much text without turning it into a keyhole.
struct AboutView: View {
  static let windowID = "about"

  /// Read once when the window appears: the manifests come from disk, and the reader can install a
  /// model while the window stays open, so the list is refreshed on every appearance.
  @State private var credits: [ModelCredit] = []
  @State private var notice: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      identity
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          modelsSection
          noticeSection
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 640)
    .accessibilityIdentifier("about.window")
    .onAppear {
      credits = ModelCredits.credits()
      notice = Self.bundledNotice()
    }
  }

  // MARK: - Identity

  private var identity: some View {
    HStack(alignment: .top, spacing: 18) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        // `app.title` is the same string the localized `CFBundleDisplayName` carries — the
        // localization suite asserts they match — so the panel shows the name the reader sees in
        // the menu bar, in the language the interface is running in.
        Text("app.title")
          .font(.title2.weight(.semibold))
          .accessibilityIdentifier("about.name")
        LabeledContent {
          Text(Self.version).monospacedDigit()
        } label: {
          Text("about.version")
        }
        .accessibilityIdentifier("about.version")
        LabeledContent {
          Text(Self.build).monospacedDigit()
        } label: {
          Text("about.build")
        }
        .accessibilityIdentifier("about.build")
        Text("about.copyright")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Models

  private var modelsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionTitle("about.models.title")
      if credits.isEmpty {
        Text("about.models.empty")
          .foregroundStyle(.secondary)
      } else {
        ForEach(credits) { credit in
          creditCard(credit)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("about.models")
  }

  private func creditCard(_ credit: ModelCredit) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(credit.id)
            .font(.headline.monospaced())
            .textSelection(.enabled)
          Spacer(minLength: 12)
          Text(credit.isInstalled ? "about.models.installed" : "about.models.absent")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        detail("about.models.license", credit.licenseId)
        detail("about.models.authors", credit.authors.joined(separator: ", "))
        detail("about.models.revision", credit.modelRevision)
        if !credit.usageRestrictions.isEmpty {
          detail(
            "about.models.restrictions",
            credit.usageRestrictions.joined(separator: ", "))
        }
      }
      .padding(4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("about.model.\(credit.id)")
  }

  /// The value is never localized on purpose: a licence identifier, an author and a revision hash
  /// are evidence copied out of the manifest, and translating them would make them stop matching
  /// the file they came from.
  private func detail(_ label: String, _ value: String) -> some View {
    LabeledContent {
      Text(value)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text(LocalizedStringKey(label))
    }
  }

  // MARK: - Notice

  private var noticeSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("about.notice.title")
      if let notice {
        Text(notice)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("about.notice.missing")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("about.notice")
  }

  private func sectionTitle(_ key: String) -> some View {
    Text(LocalizedStringKey(key))
      .font(.headline)
      .accessibilityAddTraits(.isHeader)
  }

  // MARK: - Bundle values

  /// Showing the NOTICE file itself, instead of a list rebuilt in Swift, is what keeps the credits
  /// and the legal inventory of the repository from drifting apart.
  private static func bundledNotice() -> String? {
    guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: nil) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private static var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

  private static var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }
}

/// The menu item lives in its own view because `openWindow` is an environment value and the `App`
/// struct has no environment to read it from.
struct AboutMenuCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("about.action") { openWindow(id: AboutView.windowID) }
  }
}
