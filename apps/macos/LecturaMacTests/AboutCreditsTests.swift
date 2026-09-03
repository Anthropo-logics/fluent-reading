import CryptoKit
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
    "kokoro-82m-4bit", "translategemma-4b-it-4bit",
  ]
  private static let layoutManifestID = "pp-doclayout-v3-coreml"

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
      XCTAssertEqual(credit.licenseId, manifest.licenseId, credit.id)
      XCTAssertEqual(credit.authors, manifest.authors, credit.id)
      XCTAssertEqual(credit.modelRevision, manifest.modelRevision, credit.id)
      XCTAssertEqual(credit.usageRestrictions, manifest.usageRestrictions, credit.id)
      XCTAssertEqual(credit.purpose, manifest.purpose, credit.id)
      XCTAssertFalse(credit.licenseId.isEmpty, credit.id)
      XCTAssertFalse(credit.authors.isEmpty, credit.id)
      XCTAssertFalse(credit.isInstalled, "no package exists under a directory just invented")
    }
  }

  func testLayoutCreditComesFromItsPackagingManifestAndSiblingModel() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("about-layout-credit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = root.appendingPathComponent("pp-doclayout-v3-coreml.json")
    try FileManager.default.copyItem(
      at: Self.manifestURL(Self.layoutManifestID), to: manifest)
    let model = root.appendingPathComponent("PPDocLayoutV3-fp32.mlmodelc", isDirectory: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)

    let installed = try XCTUnwrap(
      ModelCredits.credits(
        manifestURLs: [manifest], storageRoot: nil,
        containerRoot: root.appendingPathComponent("unused")
      )
      .first)
    XCTAssertEqual(installed.id, Self.layoutManifestID)
    XCTAssertEqual(installed.purpose, "document_layout")
    XCTAssertEqual(installed.authors, ["PaddlePaddle"])
    XCTAssertEqual(installed.licenseId, "Apache-2.0")
    XCTAssertEqual(installed.modelRevision, "97d101e6db2642e162a1d05392d1b0231c91033e")
    XCTAssertTrue(installed.usageRestrictions.isEmpty)
    XCTAssertTrue(installed.isInstalled)

    try FileManager.default.removeItem(at: model)
    XCTAssertEqual(
      ModelCredits.credits(
        manifestURLs: [manifest], storageRoot: nil,
        containerRoot: root.appendingPathComponent("unused")
      )
      .first?.isInstalled,
      false)
  }

  func testLayoutModelShipsItsExactApacheLicenseAndRecordsUpstreamNoticeAudit() throws {
    let data = try Data(contentsOf: Self.manifestURL(Self.layoutManifestID))
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let resource = try XCTUnwrap(manifest["license_text_resource"] as? String)
    let licenseURL = Self.repositoryRoot.appendingPathComponent("models/licenses")
      .appendingPathComponent(resource)
    let license = try Data(contentsOf: licenseURL)
    let digest = SHA256.hash(data: license).map { String(format: "%02x", $0) }.joined()

    XCTAssertEqual(resource, "PPDocLayoutV3-Apache-2.0.txt")
    XCTAssertEqual(digest, manifest["license_text_sha256"] as? String)
    XCTAssertEqual(digest, "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30")
    XCTAssertEqual(manifest["source_notice_present"] as? Bool, false)
    XCTAssertEqual(
      manifest["source_license_evidence_url"] as? String,
      "https://huggingface.co/PaddlePaddle/PP-DocLayoutV3_safetensors/blob/97d101e6db2642e162a1d05392d1b0231c91033e/README.md"
    )
    XCTAssertEqual(
      manifest["source_notice_audit_url"] as? String,
      "https://huggingface.co/api/models/PaddlePaddle/PP-DocLayoutV3_safetensors/revision/97d101e6db2642e162a1d05392d1b0231c91033e"
    )
    let text = String(decoding: license, as: UTF8.self)
    XCTAssertTrue(text.contains("Apache License"))
    XCTAssertTrue(text.contains("Version 2.0, January 2004"))
    XCTAssertTrue(text.contains("END OF TERMS AND CONDITIONS"))
    XCTAssertTrue(text.contains("APPENDIX: How to apply the Apache License to your work."))

    let project = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent(
        "apps/macos/LecturaFluida.xcodeproj/project.pbxproj"), encoding: .utf8)
    XCTAssertTrue(project.contains("PPDocLayoutV3-Apache-2.0.txt in Resources"))
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
  }

  func testLegacyLexiconsAreNotDistributedByTheMacApp() throws {
    let project = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent(
        "apps/macos/LecturaFluida.xcodeproj/project.pbxproj"), encoding: .utf8)
    XCTAssertFalse(project.contains("kokoro-ipa-lexicons-es-pt"))

    let notice = try Self.noticeText()
    XCTAssertTrue(notice.contains("kokoro-ipa-lexicons-es-pt"))
    XCTAssertTrue(notice.contains("no se distribuye ni se descarga con la aplicación"))
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

    let layout = try XCTUnwrap(
      ModelCredits.credits(
        manifestURLs: [Self.manifestURL(Self.layoutManifestID)], storageRoot: nil,
        containerRoot: URL(fileURLWithPath: NSTemporaryDirectory())
      )
      .first)
    XCTAssertTrue(notice.contains("PP-DocLayoutV3"))
    XCTAssertTrue(notice.contains(layout.authors[0]))
    XCTAssertTrue(notice.contains(layout.licenseId))
    XCTAssertTrue(notice.contains(layout.modelRevision))
  }

  /// NFR11: the phonemisation engine is GPL-3.0-or-later and `embed-runtimes.sh` copies it into the
  /// signed bundle. As long as that is true, `NOTICE` has to say so — dropping the notice while
  /// still shipping the binary is the failure this guards, and it is invisible from the running app.
  func testNoticeDeclaresTheEmbeddedPhonemisationEngine() throws {
    let manifestData = try Data(
      contentsOf: Self.manifestURL("embedded-runtimes-v1"))
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let components = try XCTUnwrap(manifest["components"] as? [[String: Any]])
    let ids = Set(components.compactMap { $0["id"] as? String })
    XCTAssertTrue(ids.contains("espeak-ng"))
    XCTAssertTrue(ids.contains("libespeak-ng"))
    XCTAssertTrue(ids.contains("libpcaudio"))

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
