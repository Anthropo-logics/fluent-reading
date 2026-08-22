import Foundation
import XCTest

@testable import MacPlatform

final class LFContractTests: XCTestCase {
  func testCompletedFixtureDecodesWithoutLosingContractFields() throws {
    let event = try JSONDecoder().decode(
      LFEvent.self,
      from: try fixture(named: "canary-completed")
    )

    XCTAssertEqual(event.schemaVersion, 1)
    XCTAssertEqual(event.requestID, "req_opaque")
    XCTAssertEqual(event.jobID, "job_opaque")
    XCTAssertEqual(event.sequence, 0)
    XCTAssertEqual(event.kind, .completed)
    XCTAssertEqual(event.result?.canary?.coreVersion, "0.1.0")
    XCTAssertEqual(event.result?.canary?.message, "lectura-core ready")
    XCTAssertNil(event.error)
  }

  func testErrorFixtureDecodesAsStructuredFailure() throws {
    let error = try JSONDecoder().decode(
      LFError.self,
      from: try fixture(named: "canary-error")
    )

    XCTAssertEqual(error.code, "LF_CONTRACT_INVALID_JSON")
    XCTAssertEqual(error.messageKey, "contract.invalid_json")
    XCTAssertTrue(error.details.isEmpty)
  }

  func testEngineClientConsumesTheRealRustCanary() async throws {
    let event = try await EngineClient.canary()

    XCTAssertEqual(event.kind, .completed)
    XCTAssertEqual(event.result?.canary?.coreVersion, "0.1.0")
    XCTAssertEqual(event.result?.canary?.message, "lectura-core ready")
  }

  func testDocumentOpenedResultDecodesWithoutAPath() throws {
    let event = try JSONDecoder().decode(
      LFEvent.self,
      from: Data(
        #"{"schema_version":1,"request_id":"req_open","job_id":"job_opaque","sequence":0,"kind":"completed","progress":null,"result":{"document_id":"doc_opaque","access_grant_id":"grant_opaque","page_count":2,"first_page_ms":125},"error":null,"recovery":null}"#
          .utf8
      )
    )

    XCTAssertEqual(event.result?.documentOpened?.documentID, "doc_opaque")
    XCTAssertEqual(event.result?.documentOpened?.accessGrantID, "grant_opaque")
    XCTAssertEqual(event.result?.documentOpened?.pageCount, 2)
    XCTAssertEqual(event.result?.documentOpened?.firstPageMilliseconds, 125)
  }

  func testEngineClientConsumesTheRealRustOpenDocumentContract() async throws {
    let event = try await EngineClient.openDocument(
      accessGrantID: "grant_opaque",
      documentFingerprint: Self.fingerprintA,
      pageCount: 2,
      firstPageMilliseconds: 125
    )

    XCTAssertEqual(event.kind, .completed)
    XCTAssertEqual(event.result?.documentOpened?.accessGrantID, "grant_opaque")
    XCTAssertEqual(event.result?.documentOpened?.pageCount, 2)
    XCTAssertEqual(event.result?.documentOpened?.firstPageMilliseconds, 125)
  }

  /// A document's stored data is filed under a name the document itself decides (Story 6.25).
  ///
  /// Before this, the name was a counter that restarted with the process, so the first document of
  /// one launch and the first of the next were handed the same one — and with it the same session
  /// directory, the same reported size and the same "delete processed data".
  func testTheSameDocumentKeepsItsNameAndTwoDocumentsNeverShareOne() async throws {
    let first = try await EngineClient.openDocument(
      accessGrantID: "grant_opaque", documentFingerprint: Self.fingerprintA,
      pageCount: 2, firstPageMilliseconds: 1
    ).result?.documentOpened?.documentID
    let second = try await EngineClient.openDocument(
      accessGrantID: "grant_other", documentFingerprint: Self.fingerprintB,
      pageCount: 9, firstPageMilliseconds: 7
    ).result?.documentOpened?.documentID
    let firstAgain = try await EngineClient.openDocument(
      accessGrantID: "grant_third", documentFingerprint: Self.fingerprintA,
      pageCount: 2, firstPageMilliseconds: 99
    ).result?.documentOpened?.documentID

    XCTAssertEqual(first, firstAgain)
    XCTAssertNotEqual(first, second)
    // And it must be a name the session store will accept as a directory.
    let documentID = try XCTUnwrap(first)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try LocalStateStore.prepare(documentID: documentID, root: root), .current)
  }

  /// Two real fixtures, through the real chain, land in the two directories `shasum` predicts.
  ///
  /// The names below did not come from the application: they are
  /// `"doc_" + shasum -a 256 <fixture> | cut -c1-32`, so this asserts that what the reader's
  /// document is filed under is the document itself. That is also what makes it launch-independent
  /// — a counter could not equal a digest of the bytes in any run — and the chain exercised here is
  /// the production one: `ReadAccessGrant.documentFingerprint()`, the real Rust bridge, and the
  /// real session store. Only fixtures are opened; nothing of the owner's is touched (AC5).
  @MainActor
  func testTwoRealFixturesAreFiledUnderTheirOwnDigestsAndNotUnderEachOthers() async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let expected = [
      "tests/corpus/documents/es-multi-digital.pdf": "doc_dd65484b281e51dd5a827d17a47eb881",
      "tests/corpus/documents/en-multi-digital.pdf": "doc_1ec3a40c18aad0329056538bd02e286d",
    ]
    let store = FileManager.default.temporaryDirectory
      .appendingPathComponent("named-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: store) }

    for (fixture, name) in expected {
      let url = root.appendingPathComponent(fixture)
      let grant = ReadAccessGrant(url: url)
      let fingerprint = try await grant.documentFingerprint()
      let opened = try await EngineClient.openDocument(
        accessGrantID: grant.id, documentFingerprint: fingerprint,
        pageCount: 2, firstPageMilliseconds: 1
      ).result?.documentOpened
      XCTAssertEqual(opened?.documentID, name, "\(fixture) must be filed under its own digest")
      _ = try LocalStateStore.save(
        DigitalPageResult(pageIndex: 0, status: "completed", blocks: [], errorCode: nil),
        documentID: try XCTUnwrap(opened?.documentID), root: store)
    }

    let sessions = try FileManager.default.contentsOfDirectory(
      atPath: store.appendingPathComponent("sessions").path)
    XCTAssertEqual(
      Set(sessions), Set(expected.values),
      "two documents must occupy two directories, each one its own")
  }

  private static let fingerprintA = String(repeating: "a", count: 64)
  private static let fingerprintB = String(repeating: "b", count: 63) + "c"

  func testEngineClientPlansAndCancelsIncrementalSession() async throws {
    let planned = try await EngineClient.planSession(
      documentID: "doc_opaque",
      pageCount: 4,
      visiblePageIndex: 2
    )
    let session = try XCTUnwrap(planned.result?.incrementalSession)
    XCTAssertEqual(session.visiblePageIndex, 2)
    XCTAssertEqual(session.pages[2].state, .processing)

    let cancelled = try await EngineClient.mutateSession(
      session,
      action: "cancel",
      pageIndex: nil
    )
    let result = try XCTUnwrap(cancelled.result?.incrementalSession)
    XCTAssertTrue(result.cancelled)
    XCTAssertEqual(result.pages[2].state, .pending)
  }

  func testIncrementalSessionCheckpointIsAtomicAndLocal() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let event = try await EngineClient.planSession(
      documentID: "doc_opaque",
      pageCount: 3,
      visiblePageIndex: 1)
    let session = try XCTUnwrap(event.result?.incrementalSession)
    let destination = try LocalStateStore.save(session, root: root)
    let data = try Data(contentsOf: destination)
    XCTAssertTrue(destination.path.hasPrefix(root.path))
    XCTAssertEqual(
      try JSONDecoder().decode(LFIncrementalSessionResult.self, from: data),
      session)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("path"))
  }

  func testCompletedPageCheckpointIsAtomicAndLocal() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("page-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let page = DigitalPageResult(
      pageIndex: 2,
      status: "completed",
      blocks: [
        DigitalTextBlock(
          blockID: "page-2-block-0",
          text: "contenido local",
          region: DigitalSourceRegion(
            pageIndex: 2,
            rectPDFPoints: [0, 0, 10, 10],
            pageRotationDegrees: 0,
            sourceToPageTransform: [1, 0, 0, 1, 0, 0],
            confidence: 1),
          confidence: 1)
      ],
      errorCode: nil)

    let destination = try LocalStateStore.save(page, documentID: "doc_opaque", root: root)
    let stored = try JSONDecoder().decode(
      DigitalPageResult.self, from: Data(contentsOf: destination))

    XCTAssertEqual(stored, page)
    XCTAssertTrue(destination.path.hasPrefix(root.path))
  }

  func testDerivedUsageAndDeletionPreserveSourceAndRequireCurrentSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("lifecycle-store-\(UUID().uuidString)", isDirectory: true)
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("source-\(UUID().uuidString).pdf")
    try Data("source-pdf".utf8).write(to: source)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: source)
    }
    let before = try Data(contentsOf: source)
    let page = DigitalPageResult(pageIndex: 0, status: "completed", blocks: [], errorCode: nil)
    _ = try LocalStateStore.save(page, documentID: "doc_opaque", root: root)
    let usage = try LocalStateStore.usage(documentID: "doc_opaque", root: root)

    XCTAssertGreaterThan(usage, 0)
    XCTAssertThrowsError(
      try LocalStateStore.deleteDerivedData(
        documentID: "doc_opaque", expectedBytes: usage + 1, root: root)
    ) { XCTAssertEqual($0 as? LocalStateStoreError, .storageChanged) }
    try LocalStateStore.deleteDerivedData(
      documentID: "doc_opaque", expectedBytes: usage, root: root)

    XCTAssertEqual(try LocalStateStore.usage(documentID: "doc_opaque", root: root), 0)
    XCTAssertEqual(try Data(contentsOf: source), before)
  }

  func testIncompatibleLocalSchemaIsInvalidatedBeforeRebuild() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("schema-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try LocalStateStore.prepare(documentID: "doc_opaque", root: root), .current)
    let directory = root.appendingPathComponent("sessions/doc_opaque", isDirectory: true)
    try Data(
      #"{"schema_version":0,"record_type":"document_store","writer_version":"old"}"#.utf8
    ).write(to: directory.appendingPathComponent("store.json"), options: .atomic)
    try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.json"))

    XCTAssertEqual(
      try LocalStateStore.prepare(documentID: "doc_opaque", root: root), .invalidated)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("partial.json").path))
    XCTAssertGreaterThan(try LocalStateStore.usage(documentID: "doc_opaque", root: root), 0)
  }

  /// The directories the launch counter left behind belong to no document, so they go (Story 6.25).
  ///
  /// The storage panel only ever reports and deletes the *open* document's directory, so a name
  /// nothing will claim again is derived text of the owner's documents that they can no longer see
  /// or remove. Only the old shape goes: `doc_` plus sixteen lowercase hex digits.
  func testSessionsNamedByTheOldLaunchCounterAreDiscardedAndCurrentOnesAreNot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contentNamed = "doc_" + String(repeating: "a", count: 32)
    let kept = [contentNamed, "doc_opaque", "doc_" + String(repeating: "A", count: 16), "exports"]
    let discarded = ["doc_0000000000000001", "doc_000000000000000f", "doc_00000000000000ff"]
    for name in kept + discarded {
      _ = try LocalStateStore.prepare(documentID: name, root: root)
    }

    XCTAssertEqual(LocalStateStore.discardSessionsNamedByLaunchCounter(root: root), 3)

    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    for name in kept {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: sessions.appendingPathComponent(name).path),
        "\(name) still belongs to a document")
    }
    for name in discarded {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: sessions.appendingPathComponent(name).path),
        "\(name) belongs to no document")
    }
    XCTAssertEqual(LocalStateStore.discardSessionsNamedByLaunchCounter(root: root), 0)
  }

  func testDirectBlocksNormalizeInRustBeforeAtomicCheckpoint() async throws {
    let raw = DigitalPageResult(
      pageIndex: 2,
      status: "completed",
      blocks: [
        DigitalTextBlock(
          blockID: "page-2-block-0",
          text: "Lectu-\nra fluida.",
          region: DigitalSourceRegion(
            pageIndex: 2,
            rectPDFPoints: [0, 0, 10, 10],
            pageRotationDegrees: 90,
            sourceToPageTransform: [1, 0, 0, 1, 0, 0],
            confidence: 1),
          confidence: 1)
      ],
      errorCode: nil)
    let firstEvent = try await EngineClient.normalizePage(
      raw, documentFingerprint: "abc123", generationID: "generation_abc123")
    let secondEvent = try await EngineClient.normalizePage(
      raw, documentFingerprint: "abc123", generationID: "generation_abc123")
    let sentenceEvent = try await EngineClient.normalizePage(
      raw, documentFingerprint: "abc123", generationID: "generation_abc123",
      requestedUnit: "sentence")
    let first = try XCTUnwrap(firstEvent.result?.normalizedPage)
    let second = try XCTUnwrap(secondEvent.result?.normalizedPage)

    XCTAssertEqual(first.units.first?.text, "Lectura fluida.")
    XCTAssertEqual(first.units.first?.unitID, second.units.first?.unitID)
    XCTAssertEqual(first.units.first?.sourceRegions.first?.pageRotationDegrees, 90)
    XCTAssertEqual(first.units.first?.decisionTrace.first?.rule, "join_line_end_hyphen")
    XCTAssertEqual(sentenceEvent.result?.normalizedPage?.units.first?.kind, "sentence")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("normalized-page-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try LocalStateStore.save(
      first, pageIndex: 2, documentID: "doc_opaque", root: root)
    XCTAssertEqual(
      try JSONDecoder().decode(LFNormalizedPage.self, from: Data(contentsOf: destination)), first)
  }

  private func fixture(named name: String) throws -> Data {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
  }
}
