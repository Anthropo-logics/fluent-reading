import MacPlatform
import XCTest

/// Story 6.4: the credits the About panel shows, and the `NOTICE` file the repository ships, must
/// both keep saying what the real manifests say. A licence transcribed by hand is exactly the
/// failure AC2 forbids, and it fails silently — nothing breaks, the panel simply starts lying.
final class AboutCreditsTests: XCTestCase {
  /// Manifests of the packages the application actually distributes, as opposed to the candidates
  /// evaluated and discarded in Stories 1.6 and 5.1, which keep a manifest as evidence but are
  /// never bundled or downloaded by the app.
  private static let distributedManifestIDs = [
    "kokoro-82m-4bit", "translategemma-4b-it-4bit", "kokoro-ipa-lexicons-es-pt",
  ]

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LecturaMacTests
      .deletingLastPathComponent()  // apps/macos
      .deletingLastPathComponent()  // apps
      .deletingLastPathComponent()  // repository root
  }

  private static func manifestURL(_ id: String) -> URL {
    repositoryRoot.appendingPathComponent("models/manifests/\(id).json")
  }

  private static func noticeText() throws -> String {
    try String(contentsOf: repositoryRoot.appendingPathComponent("NOTICE"), encoding: .utf8)
  }

  /// AC2: every credit carries the licence, provenance and revision of the real manifest — read
  /// from the file, never restated in Swift.
  func testCreditsCarryTheLicenceDeclaredByTheRealManifest() throws {
    let urls = Self.distributedManifestIDs.map(Self.manifestURL)
    let container = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("about-credits-\(UUID().uuidString)", isDirectory: true)

    let credits = ModelCredits.credits(
      manifestURLs: urls, storageRoot: nil, containerRoot: container)

    XCTAssertEqual(Set(credits.map(\.id)), Set(Self.distributedManifestIDs))
    for credit in credits {
      let data = try Data(contentsOf: Self.manifestURL(credit.id))
      let manifest = try ModelPackageInstaller.decodeManifest(data)
      XCTAssertEqual(credit.manifest.licenseId, manifest.licenseId, credit.id)
      XCTAssertEqual(credit.manifest.authors, manifest.authors, credit.id)
      XCTAssertEqual(credit.manifest.modelRevision, manifest.modelRevision, credit.id)
      XCTAssertEqual(credit.manifest.usageRestrictions, manifest.usageRestrictions, credit.id)
      XCTAssertFalse(credit.manifest.licenseId.isEmpty, credit.id)
      XCTAssertFalse(credit.manifest.authors.isEmpty, credit.id)
      XCTAssertFalse(credit.isInstalled, "no package exists under a directory just invented")
    }
  }

  /// A JSON resource that is not a model manifest — a contract fixture, say — must not turn into a
  /// credit entry with empty fields.
  func testNonManifestResourcesAreNotCredited() throws {
    let fixture = Self.repositoryRoot
      .appendingPathComponent("contracts/lf-v1/fixtures/canary-completed.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), "fixture moved")

    let credits = ModelCredits.credits(
      manifestURLs: [fixture, Self.manifestURL("kokoro-82m-4bit")],
      storageRoot: nil,
      containerRoot: URL(fileURLWithPath: NSTemporaryDirectory()))

    XCTAssertEqual(credits.map(\.id), ["kokoro-82m-4bit"])
  }

  /// A package present on disk is reported as installed, whichever of the two shapes it has: the
  /// managed container the installer writes, or the verified package under the folder the reader
  /// chose. The folder is the reader's choice, so the test builds its own instead of assuming one.
  func testInstalledStateFollowsThePackagesPresentOnDisk() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("about-credits-\(UUID().uuidString)", isDirectory: true)
    let container = root.appendingPathComponent("container", isDirectory: true)
    let storage = root.appendingPathComponent("storage", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: container.appendingPathComponent("installed/kokoro-82m-4bit", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: storage.appendingPathComponent(
        "verified-packages/translategemma-4b-it-4bit", isDirectory: true),
      withIntermediateDirectories: true)

    let credits = ModelCredits.credits(
      manifestURLs: Self.distributedManifestIDs.map(Self.manifestURL),
      storageRoot: storage,
      containerRoot: container)
    let installed = Dictionary(uniqueKeysWithValues: credits.map { ($0.id, $0.isInstalled) })

    XCTAssertEqual(installed["kokoro-82m-4bit"], true)
    XCTAssertEqual(installed["translategemma-4b-it-4bit"], true)
    XCTAssertEqual(installed["kokoro-ipa-lexicons-es-pt"], false)
  }

  /// AC2/AC3: `NOTICE` names every distributed model with the licence its manifest declares. If a
  /// manifest is ever re-licensed and `NOTICE` is not updated with it, this fails.
  func testNoticeMatchesTheLicenceOfEveryDistributedManifest() throws {
    let notice = try Self.noticeText()

    for id in Self.distributedManifestIDs {
      let manifest = try ModelPackageInstaller.decodeManifest(
        try Data(contentsOf: Self.manifestURL(id)))
      XCTAssertTrue(notice.contains(id), "NOTICE does not mention the model \(id)")
      XCTAssertTrue(
        notice.contains(manifest.licenseId),
        "NOTICE does not state the licence \(manifest.licenseId) of \(id)")
      XCTAssertTrue(
        notice.contains(manifest.modelRevision),
        "NOTICE does not state the pinned revision of \(id)")
      for restriction in manifest.usageRestrictions {
        XCTAssertTrue(
          notice.contains(restriction),
          "NOTICE omits the declared restriction \(restriction) of \(id)")
      }
    }
  }

  /// NFR11: the phonemisation engine is GPL-3.0-or-later and `embed-runtimes.sh` copies it into the
  /// signed bundle. As long as that is true, `NOTICE` has to say so — dropping the notice while
  /// still shipping the binary is the failure this guards, and it is invisible from the running app.
  func testNoticeDeclaresTheEmbeddedPhonemisationEngine() throws {
    let script = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent("scripts/embed-runtimes.sh"),
      encoding: .utf8)
    try XCTSkipUnless(script.contains("embed_espeak"), "the build no longer embeds eSpeak NG")

    let notice = try Self.noticeText()
    XCTAssertTrue(notice.contains("eSpeak NG"), "NOTICE does not credit eSpeak NG")
    XCTAssertTrue(notice.contains("GPL-3.0-or-later"), "NOTICE does not state the GPL obligation")
    XCTAssertTrue(notice.contains("pcaudiolib"), "NOTICE does not credit pcaudiolib")
  }

  /// AC3: the project ships the verbatim GPLv3 text. The bundle embeds eSpeak NG and pcaudiolib,
  /// both GPL-3.0-or-later, so a licence change to anything weaker — permissive or proprietary —
  /// would make the application undistributable without anything failing to build. This is the
  /// check that would catch it.
  func testLicenseIsTheVerbatimGPLv3RequiredByTheEmbeddedEngines() throws {
    let license = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
    XCTAssertTrue(
      license.contains("GNU GENERAL PUBLIC LICENSE"), "LICENSE is not the GNU GPL text")
    XCTAssertTrue(
      license.contains("Version 3, 29 June 2007"), "LICENSE is not version 3 of the GPL")

    let notice = try Self.noticeText()
    XCTAssertTrue(
      notice.contains("GPL-3.0-or-later"),
      "NOTICE does not state the licence of the project's own code")
    let readme = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
    XCTAssertTrue(readme.contains("GPL-3.0-or-later"), "README does not state the licence")
  }

  /// TEST-001 from the QA gate: the previous check only proved the three *names* eSpeak NG,
  /// pcaudiolib and "GPL-3.0-or-later" survive — deleting the section that spells out the actual
  /// GPLv3 obligations (source offer, licence text, App Store exclusion) left it passing. Anchor to
  /// the obligation itself, not just to the names.
  func testNoticeStatesTheActualGPLv3ObligationsNotJustTheComponentNames() throws {
    let notice = try Self.noticeText()
    XCTAssertTrue(
      notice.contains("código fuente correspondiente"),
      "NOTICE does not state the GPLv3 source-offer obligation")
    XCTAssertTrue(
      notice.contains("Mac App Store"),
      "NOTICE does not state the App Store distribution consequence of embedding GPL components")
  }
}
