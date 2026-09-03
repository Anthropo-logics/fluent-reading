import CryptoKit
import Foundation
import MacPlatform
import PDFKit
import XCTest

final class DocumentLayoutCorpusTests: XCTestCase {
  func testFurnitureExpectationsRequireEveryExternalFragmentInSourceAndOutsideAutomaticSpeech() {
    let source = [
      "header": "Revista Colombiana de Antropología",
      "body": "La autora analiza el desplazamiento.",
      "footer": "Published by Digital Commons",
    ]

    XCTAssertFalse(
      CorpusMissionAssertions.furnitureIsNonautomatic(
        fragments: [], sourceTextByID: source, automaticIDs: []))
    XCTAssertFalse(
      CorpusMissionAssertions.furnitureIsNonautomatic(
        fragments: ["Revista Colombiana", "fragmento ausente"], sourceTextByID: source,
        automaticIDs: []))
    XCTAssertFalse(
      CorpusMissionAssertions.furnitureIsNonautomatic(
        fragments: ["Published by", "Digital Commons"],
        sourceTextByID: ["footer": "Published by Digital Commons"], automaticIDs: []))
    XCTAssertFalse(
      CorpusMissionAssertions.furnitureIsNonautomatic(
        fragments: ["Revista Colombiana", "Digital Commons"], sourceTextByID: source,
        automaticIDs: ["header"]))
    XCTAssertTrue(
      CorpusMissionAssertions.furnitureIsNonautomatic(
        fragments: ["Revista Colombiana", "Digital Commons"], sourceTextByID: source,
        automaticIDs: []))
  }

  func testReadingOrderExpectationsRequireAtLeastTwoExternalFragmentsInOrder() {
    let reading = ["Primeira passagem do texto", "Segunda passagem do texto"]

    XCTAssertFalse(CorpusMissionAssertions.fragmentsAppearInOrder([], texts: reading))
    XCTAssertFalse(
      CorpusMissionAssertions.fragmentsAppearInOrder(["Primeira passagem"], texts: reading))
    XCTAssertFalse(
      CorpusMissionAssertions.fragmentsAppearInOrder(
        ["Segunda passagem", "Primeira passagem"], texts: reading))
    XCTAssertTrue(
      CorpusMissionAssertions.fragmentsAppearInOrder(
        ["Primeira passagem", "Segunda passagem"], texts: reading))
  }

  func testCorpusManifestDecodesExplicitSnakeCaseContractIncludingOCRFlag() throws {
    let data = Data(
      #"{"expected_case_count":1,"results":[{"id":"pt","source":"/tmp/pt.pdf","source_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","page":1,"language":"pt","minimum_source_blocks":5,"expected_furniture_fragments":[],"expected_reading_fragments":["primeiro","segundo"],"requires_ocr":true,"provenance":{"url":"https://example.test/scan.pdf","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_page":20}}]}"#
        .utf8)

    let manifest = try JSONDecoder().decode(CorpusManifest.self, from: data)

    XCTAssertEqual(manifest.expectedCaseCount, 1)
    XCTAssertEqual(manifest.results.first?.language, "pt")
    XCTAssertEqual(manifest.results.first?.minimumSourceBlocks, 5)
    XCTAssertEqual(manifest.results.first?.expectedReadingFragments, ["primeiro", "segundo"])
    XCTAssertEqual(manifest.results.first?.requiresOCR, true)
    XCTAssertEqual(manifest.results.first?.provenance?.sourcePage, 20)
  }

  func testCorpusGateRequiresExactCaseIdentityAndEveryCaseMissionKey() {
    let expected: Set<String> = [
      "alviar_toc", "alviar_notes", "mejia_es_scan_spread", "ferguson_en_scan",
      "wacquant_broken_order", "unicef_columns", "stockemer_table", "garzon_clean",
      "consorcio_toc", "saudades_pt_scan",
    ]

    XCTAssertEqual(CorpusGate.requiredCaseIDs, expected)
    XCTAssertTrue(CorpusGate.hasExactCaseIDs(Array(expected)))
    XCTAssertFalse(CorpusGate.hasExactCaseIDs(Array(expected.dropFirst())))
    XCTAssertFalse(CorpusGate.hasExactCaseIDs(Array(expected) + ["substitute_control"]))
    for id in expected {
      XCTAssertFalse(CorpusGate.requiredOutcomeKeys(for: id).isEmpty, "\(id) has no mission gate")
    }
    XCTAssertTrue(
      CorpusGate.requiredOutcomeKeys(for: "alviar_toc").isSuperset(of: [
        "expected_furniture_nonautomatic", "toc_entries_remain",
      ]))
    XCTAssertTrue(
      CorpusGate.requiredOutcomeKeys(for: "unicef_columns").contains("multicolumn_order"))
    XCTAssertTrue(
      CorpusGate.requiredOutcomeKeys(for: "mejia_es_scan_spread").contains(
        "spread_left_to_right"))
    XCTAssertTrue(
      CorpusGate.requiredOutcomeKeys(for: "ferguson_en_scan").contains(
        "ferguson_rotation_or_fallback"))
    XCTAssertTrue(
      CorpusGate.requiredOutcomeKeys(for: "saudades_pt_scan").isSuperset(of: [
        "portuguese_ocr_used", "explicit_ocr_source_is_image_only",
      ]))
  }

  func testCorpusPerformanceGateRequiresThreeWarmSamplesAndAllDeclaredLimits() {
    let ordinary = WarmLayoutMeasurement(
      id: "ordinary", physicalPageCount: 1, samplesMilliseconds: [300, 200, 250],
      rssBytes: 500 * 1_024 * 1_024)
    let split = WarmLayoutMeasurement(
      id: "mejia_es_scan_spread", physicalPageCount: 2,
      samplesMilliseconds: [1_500, 1_200, 1_400], rssBytes: 600 * 1_024 * 1_024)

    XCTAssertTrue(CorpusGate.performanceErrors([ordinary, split]).isEmpty)
    XCTAssertFalse(
      CorpusGate.performanceErrors([
        WarmLayoutMeasurement(
          id: "short", physicalPageCount: 1, samplesMilliseconds: [100, 110],
          rssBytes: ordinary.rssBytes)
      ]).isEmpty)
    XCTAssertFalse(
      CorpusGate.performanceErrors([
        WarmLayoutMeasurement(
          id: "slow", physicalPageCount: 1, samplesMilliseconds: [751, 760, 770],
          rssBytes: ordinary.rssBytes)
      ]).isEmpty)
    XCTAssertFalse(
      CorpusGate.performanceErrors([
        WarmLayoutMeasurement(
          id: "slow-spread", physicalPageCount: 2,
          samplesMilliseconds: [1_601, 1_700, 1_650], rssBytes: ordinary.rssBytes)
      ]).isEmpty)
    XCTAssertFalse(
      CorpusGate.performanceErrors([
        WarmLayoutMeasurement(
          id: "memory", physicalPageCount: 1, samplesMilliseconds: [100, 110, 120],
          rssBytes: CorpusGate.memoryLimitBytes + 1)
      ]).isEmpty)
  }

  func testExplicitOCRContractRejectsUsableEmbeddedText() {
    XCTAssertTrue(CorpusMissionAssertions.explicitOCRSourceIsImageOnly(nil))
    XCTAssertTrue(CorpusMissionAssertions.explicitOCRSourceIsImageOnly(" \n\t"))
    XCTAssertFalse(CorpusMissionAssertions.explicitOCRSourceIsImageOnly("texto embebido"))
  }

  func testDeclaredSourceHashUsesActualPDFBytes() {
    XCTAssertEqual(
      CorpusMissionAssertions.sha256Hex(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testNativeLayoutOnStratifiedCorpus() async throws {
    guard let casesPath = gateEnvironment("LECTURA_LAYOUT_CASES"),
      let modelPath = gateEnvironment("LECTURA_LAYOUT_MODEL_URL"),
      let evidencePath = gateEnvironment("LECTURA_LAYOUT_EVIDENCE_PATH")
    else {
      throw XCTSkip(
        "Set LECTURA_LAYOUT_CASES, LECTURA_LAYOUT_MODEL_URL and LECTURA_LAYOUT_EVIDENCE_PATH")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      XCTFail("Explicit layout model is absent or invalid: \(modelPath)")
      return
    }

    let manifest = try JSONDecoder().decode(
      CorpusManifest.self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
    let manifestErrors = CorpusGate.manifestErrors(manifest)
    for error in manifestErrors { XCTFail(error) }
    guard manifestErrors.isEmpty else { return }
    let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
    var results = [CaseEvidence]()
    for testCase in manifest.results {
      results.append(await evaluate(testCase, modelURL: modelURL))
    }

    let evidence = CorpusEvidence(
      schemaVersion: 1, modelURL: modelPath, casesManifest: casesPath, cases: results)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let evidenceURL = URL(fileURLWithPath: evidencePath)
    try FileManager.default.createDirectory(
      at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(evidence).write(to: evidenceURL, options: .atomic)

    XCTAssertEqual(results.count, manifest.expectedCaseCount, "not every corpus case ran")
    for result in results {
      XCTAssertTrue(result.errors.isEmpty, "\(result.id): \(result.errors.joined(separator: "; "))")
      let requiredOutcomes = CorpusGate.requiredOutcomeKeys(for: result.id)
      let missingOutcomes = requiredOutcomes.subtracting(result.outcomes.keys)
      XCTAssertTrue(
        missingOutcomes.isEmpty,
        "\(result.id): missing mission outcomes: \(missingOutcomes.sorted())")
      for outcome in requiredOutcomes.sorted() {
        XCTAssertEqual(
          result.outcomes[outcome], true, "\(result.id): mission outcome failed: \(outcome)")
      }
    }
    let performanceErrors = CorpusGate.performanceErrors(results.map(\.warmLayoutMeasurement))
    for error in performanceErrors { XCTFail(error) }
  }

  func testDiagnosticPagesUseReaderRoute() async throws {
    guard let casesPath = gateEnvironment("LECTURA_LAYOUT_CASES"),
      let modelPath = gateEnvironment("LECTURA_LAYOUT_MODEL_URL"),
      let evidencePath = gateEnvironment("LECTURA_LAYOUT_EVIDENCE_PATH")
    else {
      throw XCTSkip(
        "Set LECTURA_LAYOUT_CASES, LECTURA_LAYOUT_MODEL_URL and LECTURA_LAYOUT_EVIDENCE_PATH")
    }
    let manifest = try JSONDecoder().decode(
      CorpusManifest.self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
    if CorpusGate.hasExactCaseIDs(manifest.results.map(\.id)) {
      throw XCTSkip("Use testNativeLayoutOnStratifiedCorpus for the fixed acceptance corpus")
    }
    XCTAssertFalse(manifest.results.isEmpty, "diagnostic manifest is empty")
    XCTAssertEqual(manifest.results.count, manifest.expectedCaseCount)
    guard manifest.results.count == manifest.expectedCaseCount else { return }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      XCTFail("Explicit layout model is absent or invalid: \(modelPath)")
      return
    }
    let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
    var results = [CaseEvidence]()
    for testCase in manifest.results {
      results.append(await evaluate(testCase, modelURL: modelURL))
    }
    for index in results.indices {
      results[index].source = "restricted"
      results[index].provenance = nil
    }

    let evidence = CorpusEvidence(
      schemaVersion: 1, modelURL: "restricted", casesManifest: "restricted", cases: results)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let evidenceURL = URL(fileURLWithPath: evidencePath)
    try FileManager.default.createDirectory(
      at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(evidence).write(to: evidenceURL, options: .atomic)

    for (testCase, result) in zip(manifest.results, results) {
      XCTAssertTrue(result.errors.isEmpty, "\(result.id): \(result.errors.joined(separator: "; "))")
      for outcome in [
        "no_source_block_loss", "minimum_source_cardinality", "fallback_preserves_text",
      ] {
        XCTAssertEqual(result.outcomes[outcome], true, "\(result.id): \(outcome)")
      }
      if !testCase.expectedReadingFragments.isEmpty {
        XCTAssertEqual(
          result.outcomes["expected_reading_order"], true,
          "\(result.id): expected_reading_order")
      }
    }
  }

  private func evaluate(_ testCase: CorpusCase, modelURL: URL) async -> CaseEvidence {
    let pageIndex = testCase.page - 1
    let url = URL(fileURLWithPath: testCase.source)
    guard pageIndex >= 0, FileManager.default.fileExists(atPath: url.path),
      let document = PDFDocument(url: url), let pdfPage = document.page(at: pageIndex)
    else {
      return .failed(testCase, error: "source PDF or one-based page is invalid")
    }
    if let expectedSHA256 = testCase.sourceSHA256,
      !CorpusMissionAssertions.sourceMatchesSHA256(at: url, expected: expectedSHA256)
    {
      return .failed(testCase, error: "source_sha256 does not match PDF bytes")
    }
    if testCase.requiresOCR
      && !CorpusMissionAssertions.explicitOCRSourceIsImageOnly(pdfPage.string)
    {
      return .failed(testCase, error: "requires_ocr page contains usable embedded text")
    }
    let warmLayout = await measureWarmLayout(page: pdfPage, modelURL: modelURL, id: testCase.id)
    let language = testCase.language
    let digitalStarted = DispatchTime.now().uptimeNanoseconds
    let digital = await DocumentServices.extractDigitalPage(at: url, pageIndex: pageIndex)
    let digitalElapsed = elapsedMilliseconds(since: digitalStarted)
    let fingerprint = SHA256.hash(
      data: Data("\(testCase.source)#\(testCase.page)#\(testCase.id)".utf8)
    ).map { String(format: "%02x", $0) }.joined()
    let generation = "generation_\(fingerprint.prefix(16))"
    var raw = digital
    var errors = [String]()
    var normalized = try? await EngineClient.normalizePage(
      raw, documentFingerprint: fingerprint, generationID: generation, language: language,
      route: "direct_text"
    ).result?.normalizedPage
    let fallbackActivated = normalized?.record.route == "ocr"
    let ocrActivated = fallbackActivated || testCase.requiresOCR
    var ocrLatency: UInt64 = 0
    var layoutLatency = digital.layoutElapsedMilliseconds ?? 0
    if ocrActivated {
      let ocrStarted = DispatchTime.now().uptimeNanoseconds
      raw = await DocumentServices.extractOCRPage(
        at: url, pageIndex: pageIndex, language: language)
      let ocrElapsed = elapsedMilliseconds(since: ocrStarted)
      let ocrLayout = raw.layoutElapsedMilliseconds ?? 0
      layoutLatency += ocrLayout
      ocrLatency = ocrElapsed > ocrLayout ? ocrElapsed - ocrLayout : 0
      normalized = try? await EngineClient.normalizePage(
        raw, documentFingerprint: fingerprint, generationID: generation, language: language,
        route: "ocr"
      ).result?.normalizedPage
    }
    if normalized == nil { errors.append("EngineClient normalization failed") }

    let units = normalized?.units ?? []
    let sourceIDs = Set(raw.blocks.map(\.blockID))
    let preservedIDs = Set(units.flatMap(\.sourceBlockIDs)).intersection(sourceIDs)
    let omittedIDs = Set(normalized?.omissions.flatMap(\.affectedSegments) ?? []).intersection(
      sourceIDs)
    let accountedIDs = preservedIDs.union(omittedIDs)
    let automaticIDs = Set(
      units.filter { $0.resolvedNarrationDisposition == .automatic }.flatMap(\.sourceBlockIDs))
    let regions = raw.blocks.compactMap { block -> RegionEvidence? in
      guard let role = block.layoutRole, let disposition = block.narrationDisposition,
        let order = block.layoutOrder
      else { return nil }
      return RegionEvidence(
        blockID: block.blockID, role: role.rawValue, disposition: disposition.rawValue,
        order: order, physicalPageIndex: block.physicalPageIndex)
    }
    let numberIDs = Set(raw.blocks.filter { $0.layoutRole == .number }.map(\.blockID))
    let sourceTextByID = Dictionary(uniqueKeysWithValues: raw.blocks.map { ($0.blockID, $0.text) })
    let policyCounts = Dictionary(grouping: units, by: \.resolvedNarrationDisposition)
    let fallbackPreservedText =
      !ocrActivated || (!sourceIDs.isEmpty && !preservedIDs.isEmpty)
    var outcomes = [
      "no_source_block_loss": accountedIDs.count == sourceIDs.count,
      "minimum_source_cardinality": sourceIDs.count >= testCase.minimumSourceBlocks,
      "fallback_preserves_text": fallbackPreservedText,
    ]
    if !testCase.expectedFurnitureFragments.isEmpty {
      outcomes["expected_furniture_nonautomatic"] =
        CorpusMissionAssertions.furnitureIsNonautomatic(
          fragments: testCase.expectedFurnitureFragments, sourceTextByID: sourceTextByID,
          automaticIDs: automaticIDs)
    }
    if !testCase.expectedReadingFragments.isEmpty {
      outcomes["expected_reading_order"] = CorpusMissionAssertions.fragmentsAppearInOrder(
        testCase.expectedReadingFragments, texts: units.map(\.text))
    }
    if testCase.id == "alviar_toc" {
      let tocTitleIDs = Set(
        raw.blocks.filter { $0.layoutRole == .content || $0.layoutRole == .paragraphTitle }
          .map(\.blockID))
      let tocUnits = units.filter { unit in
        !Set(unit.sourceBlockIDs).isDisjoint(with: tocTitleIDs)
      }
      outcomes["toc_entries_remain"] =
        !tocUnits.isEmpty
        && tocUnits.allSatisfy { !["formula", "note"].contains($0.contentClass) }
        && accountedIDs.count == sourceIDs.count
    }
    if testCase.id == "alviar_notes" {
      outcomes["notes_remain_nonautomatic"] = outcomes["expected_furniture_nonautomatic"]
    }
    if testCase.id == "unicef_columns" {
      outcomes["multicolumn_order"] = outcomes["expected_reading_order"]
      outcomes["unsupported_tail_visual_order"] =
        Array(units.suffix(2).flatMap(\.sourceBlockIDs))
        == ["page-5-block-46", "page-5-block-44", "page-5-block-73"]
    }
    if testCase.id == "mejia_es_scan_spread" {
      let pages = raw.blocks.compactMap(\.physicalPageIndex)
      outcomes["spread_left_to_right"] = pages == pages.sorted() && Set(pages) == [0, 1]
      outcomes["spread_folios_nonautomatic"] =
        numberIDs.count >= 2 && automaticIDs.isDisjoint(with: numberIDs)
    }
    if testCase.id == "ferguson_en_scan" {
      outcomes["ferguson_rotation_or_fallback"] =
        !regions.isEmpty
        || (fallbackPreservedText && accountedIDs.count == sourceIDs.count)
    }
    if testCase.id == "stockemer_table" {
      let tableIDs = Set(raw.blocks.filter { $0.layoutRole == .table }.map(\.blockID))
      outcomes["table_retained_on_demand"] =
        !tableIDs.isEmpty && automaticIDs.isDisjoint(with: tableIDs)
        && accountedIDs.isSuperset(of: tableIDs)
    }
    if testCase.id == "garzon_clean" {
      outcomes["clean_page_preserves_text"] = accountedIDs.count == sourceIDs.count
    }
    if testCase.id == "consorcio_toc" {
      outcomes["toc_content_remains"] = !units.isEmpty && accountedIDs.count == sourceIDs.count
    }
    if testCase.requiresOCR {
      outcomes["explicit_ocr_source_is_image_only"] =
        CorpusMissionAssertions.explicitOCRSourceIsImageOnly(pdfPage.string)
    }
    if testCase.language == "pt" {
      outcomes["portuguese_ocr_used"] = testCase.requiresOCR && ocrActivated
    }

    return CaseEvidence(
      id: testCase.id, source: testCase.source, sourceSHA256: testCase.sourceSHA256,
      provenance: testCase.provenance, oneBasedPage: testCase.page,
      zeroBasedPageIndex: pageIndex, language: language, regions: regions,
      alignedCoverage: sourceIDs.isEmpty ? 0 : Double(regions.count) / Double(sourceIDs.count),
      automaticCount: policyCounts[.automatic]?.count ?? 0,
      onDemandCount: policyCounts[.onDemand]?.count ?? 0,
      neverCount: policyCounts[.never]?.count ?? 0,
      digitalSourceBlockCount: digital.blocks.count, sourceBlockCount: sourceIDs.count,
      preservedSourceBlockCount: preservedIDs.count, omittedSourceBlockCount: omittedIDs.count,
      order: units.flatMap(\.sourceBlockIDs), layoutLatencyMilliseconds: layoutLatency,
      digitalLatencyMilliseconds: digitalElapsed, ocrLatencyMilliseconds: ocrLatency,
      rssBytes: currentRSSBytes(), fallbackActivated: fallbackActivated,
      ocrActivated: ocrActivated,
      layoutStatus: raw.layoutStatus ?? "unavailable",
      physicalPageCount: Set(raw.blocks.compactMap(\.physicalPageIndex)).count,
      warmLayoutSamplesMilliseconds: warmLayout.samplesMilliseconds,
      warmLayoutMedianMilliseconds: warmLayout.medianMilliseconds,
      warmLayoutPhysicalPageCount: warmLayout.physicalPageCount,
      normalizedRoute: normalized?.record.route ?? "not_available",
      normalizedReasonCode: normalized?.record.reasonCode ?? "not_available",
      normalizedStatus: normalized?.record.status ?? "not_available",
      normalizationElapsedMilliseconds: normalized?.record.elapsedMilliseconds ?? 0,
      unitSourceBlockCounts: units.map { $0.sourceBlockIDs.count },
      unitCharacterCounts: units.map { $0.text.count },
      visibleSpokenEqualCount: units.filter { $0.text == $0.narrationText }.count,
      firstAutomaticUnitSourceBlockCount: units.first(where: \.isNarrable)?.sourceBlockIDs.count,
      firstAutomaticUnitCharacterCount: units.first(where: \.isNarrable)?.text.count,
      contentClassCounts: Dictionary(grouping: units, by: \.contentClass).mapValues(\.count),
      decisionRuleCounts: Dictionary(grouping: units.flatMap(\.decisionTrace), by: \.rule)
        .mapValues(\.count),
      outcomes: outcomes, errors: errors)
  }

  private func measureWarmLayout(
    page: PDFPage, modelURL: URL, id: String
  ) async -> WarmLayoutMeasurement {
    let sendablePage = SendableCorpusPDFPage(value: page)
    // The first call is deliberately excluded: it loads/caches the model and is not a warm sample.
    _ = await classifyCorpusPage(sendablePage, rotation: page.rotation, modelURL: modelURL)
    var samples: [UInt64] = []
    var physicalPageCounts = Set<Int>()
    for _ in 0..<CorpusGate.warmSampleCount {
      let result = await classifyCorpusPage(
        sendablePage, rotation: page.rotation, modelURL: modelURL)
      samples.append(result.elapsedMilliseconds)
      physicalPageCounts.insert(Int(result.physicalPageCount))
    }
    return WarmLayoutMeasurement(
      id: id, physicalPageCount: physicalPageCounts.count == 1 ? physicalPageCounts.first! : 0,
      samplesMilliseconds: samples, rssBytes: currentRSSBytes())
  }

  private func elapsedMilliseconds(since started: UInt64) -> UInt64 {
    (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
  }

  private func currentRSSBytes() -> UInt64 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
    let output = Pipe()
    process.standardOutput = output
    guard (try? process.run()) != nil else { return 0 }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return UInt64(
      String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
    .map { $0 * 1_024 } ?? 0
  }

}

private struct SendableCorpusPDFPage: @unchecked Sendable {
  let value: PDFPage
}

private func classifyCorpusPage(
  _ page: SendableCorpusPDFPage, rotation: Int, modelURL: URL
) async -> DocumentLayoutResult {
  await DocumentLayoutClassifier.shared.classify(
    at: page.value, rotation: rotation, modelURL: modelURL)
}

private struct CorpusManifest: Decodable {
  let expectedCaseCount: Int
  let results: [CorpusCase]

  private enum CodingKeys: String, CodingKey {
    case expectedCaseCount = "expected_case_count"
    case results
  }
}

private struct CorpusCase: Decodable {
  let id: String
  let source: String
  let sourceSHA256: String?
  let page: Int
  let language: String
  let minimumSourceBlocks: Int
  let expectedFurnitureFragments: [String]
  let expectedReadingFragments: [String]
  let requiresOCR: Bool
  let provenance: CorpusProvenance?

  private enum CodingKeys: String, CodingKey {
    case id, source, page, language
    case sourceSHA256 = "source_sha256"
    case minimumSourceBlocks = "minimum_source_blocks"
    case expectedFurnitureFragments = "expected_furniture_fragments"
    case expectedReadingFragments = "expected_reading_fragments"
    case requiresOCR = "requires_ocr"
    case provenance
  }
}

private struct CorpusProvenance: Codable {
  let url: String
  let sha256: String
  let sourcePage: Int

  private enum CodingKeys: String, CodingKey {
    case url, sha256
    case sourcePage = "source_page"
  }
}

private struct WarmLayoutMeasurement {
  let id: String
  let physicalPageCount: Int
  let samplesMilliseconds: [UInt64]
  let rssBytes: UInt64

  var medianMilliseconds: UInt64 { CorpusGate.median(samplesMilliseconds) }
}

private enum CorpusGate {
  static let warmSampleCount = 3
  static let ordinaryMedianLimitMilliseconds: UInt64 = 750
  static let splitMedianLimitMilliseconds: UInt64 = 1_600
  // NFR5's declared ceiling for one active heavy operation.
  static let memoryLimitBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024
  static let requiredCaseIDs: Set<String> = [
    "alviar_toc", "alviar_notes", "mejia_es_scan_spread", "ferguson_en_scan",
    "wacquant_broken_order", "unicef_columns", "stockemer_table", "garzon_clean",
    "consorcio_toc", "saudades_pt_scan",
  ]

  private static let commonOutcomeKeys: Set<String> = [
    "no_source_block_loss", "minimum_source_cardinality", "fallback_preserves_text",
  ]
  private static let caseOutcomeKeys: [String: Set<String>] = [
    "alviar_toc": ["expected_furniture_nonautomatic", "toc_entries_remain"],
    "alviar_notes": ["expected_furniture_nonautomatic", "notes_remain_nonautomatic"],
    "mejia_es_scan_spread": [
      "spread_left_to_right", "spread_folios_nonautomatic",
      "explicit_ocr_source_is_image_only",
    ],
    "ferguson_en_scan": [
      "ferguson_rotation_or_fallback", "explicit_ocr_source_is_image_only",
    ],
    "wacquant_broken_order": ["expected_reading_order"],
    "unicef_columns": [
      "expected_reading_order", "multicolumn_order", "unsupported_tail_visual_order",
    ],
    "stockemer_table": ["table_retained_on_demand"],
    "garzon_clean": ["clean_page_preserves_text"],
    "consorcio_toc": ["toc_content_remains"],
    "saudades_pt_scan": [
      "expected_reading_order", "portuguese_ocr_used", "explicit_ocr_source_is_image_only",
    ],
  ]

  static func hasExactCaseIDs(_ ids: [String]) -> Bool {
    ids.count == requiredCaseIDs.count && Set(ids) == requiredCaseIDs
  }

  static func requiredOutcomeKeys(for id: String) -> Set<String> {
    guard let specific = caseOutcomeKeys[id] else { return [] }
    return commonOutcomeKeys.union(specific)
  }

  static func manifestErrors(_ manifest: CorpusManifest) -> [String] {
    var errors: [String] = []
    if manifest.expectedCaseCount != requiredCaseIDs.count {
      errors.append("expected_case_count must equal \(requiredCaseIDs.count)")
    }
    if !hasExactCaseIDs(manifest.results.map(\.id)) {
      errors.append("manifest must contain each exact required corpus case once")
    }
    if Set(manifest.results.map(\.language)) != ["es", "en", "pt"] {
      errors.append("manifest must exercise es, en and pt")
    }
    if !manifest.results.allSatisfy({ $0.minimumSourceBlocks > 0 }) {
      errors.append("every case requires nonzero source cardinality")
    }
    for id in ["alviar_toc", "alviar_notes"] {
      if manifest.results.first(where: { $0.id == id })?.expectedFurnitureFragments.count ?? 0 < 2 {
        errors.append("\(id) requires two external furniture fragments")
      }
    }
    for id in ["wacquant_broken_order", "unicef_columns", "saudades_pt_scan"] {
      if manifest.results.first(where: { $0.id == id })?.expectedReadingFragments.count ?? 0 < 2 {
        errors.append("\(id) requires two external reading-order fragments")
      }
    }
    guard let portuguese = manifest.results.first(where: { $0.id == "saudades_pt_scan" }) else {
      errors.append("saudades_pt_scan is absent")
      return errors
    }
    if portuguese.language != "pt" || !portuguese.requiresOCR {
      errors.append("saudades_pt_scan must be the Portuguese OCR control")
    }
    if portuguese.sourceSHA256?.count != 64
      || portuguese.provenance?.url.hasPrefix("https://") != true
      || portuguese.provenance?.sha256.count != 64
      || (portuguese.provenance?.sourcePage ?? 0) <= 0
    {
      errors.append("saudades_pt_scan requires complete hash and archival provenance")
    }
    return errors
  }

  static func median(_ values: [UInt64]) -> UInt64 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }

  static func performanceErrors(_ measurements: [WarmLayoutMeasurement]) -> [String] {
    var errors: [String] = []
    if measurements.isEmpty { errors.append("no warm layout measurements") }
    for measurement in measurements {
      if measurement.samplesMilliseconds.count != warmSampleCount {
        errors.append("\(measurement.id): requires exactly \(warmSampleCount) warm samples")
        continue
      }
      let limit =
        measurement.physicalPageCount == 2
        ? splitMedianLimitMilliseconds : ordinaryMedianLimitMilliseconds
      if measurement.physicalPageCount != 1 && measurement.physicalPageCount != 2 {
        errors.append("\(measurement.id): inconsistent physical-page count across warm samples")
      } else if measurement.medianMilliseconds > limit {
        errors.append("\(measurement.id): warm median exceeds \(limit) ms")
      }
      if measurement.rssBytes == 0 || measurement.rssBytes > memoryLimitBytes {
        errors.append("\(measurement.id): RSS is absent or exceeds NFR5")
      }
    }
    if !measurements.contains(where: { $0.physicalPageCount == 1 }) {
      errors.append("ordinary-page warm sample is absent")
    }
    if measurements.first(where: { $0.id == "mejia_es_scan_spread" })?.physicalPageCount != 2 {
      errors.append("confirmed Mejía split-spread warm sample is absent")
    }
    return errors
  }
}

private enum CorpusMissionAssertions {
  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func sourceMatchesSHA256(at url: URL, expected: String) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
    return sha256Hex(data) == expected.lowercased()
  }

  static func explicitOCRSourceIsImageOnly(_ pageString: String?) -> Bool {
    (pageString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func furnitureIsNonautomatic(
    fragments: [String], sourceTextByID: [String: String], automaticIDs: Set<String>
  ) -> Bool {
    guard fragments.count >= 2 else { return false }
    var allMatchingIDs = Set<String>()
    for fragment in fragments {
      let normalizedFragment = normalized(fragment)
      let matchingIDs = Set(
        sourceTextByID.compactMap { id, text in
          normalized(text).contains(normalizedFragment) ? id : nil
        })
      if matchingIDs.isEmpty || !matchingIDs.isDisjoint(with: automaticIDs) { return false }
      allMatchingIDs.formUnion(matchingIDs)
    }
    return allMatchingIDs.count >= fragments.count
  }

  static func fragmentsAppearInOrder(_ fragments: [String], texts: [String]) -> Bool {
    guard fragments.count >= 2 else { return false }
    let combined = normalized(texts.joined(separator: " "))
    var remainder = combined[...]
    for fragment in fragments {
      let expected = normalized(fragment)
      guard !expected.isEmpty, let range = remainder.range(of: expected) else { return false }
      remainder = remainder[range.upperBound...]
    }
    return true
  }

  static func normalized(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")
    )
    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

private struct CorpusEvidence: Encodable {
  let schemaVersion: Int
  let modelURL: String
  let casesManifest: String
  let cases: [CaseEvidence]
}

private struct RegionEvidence: Encodable {
  let blockID: String
  let role: String
  let disposition: String
  let order: UInt32
  let physicalPageIndex: UInt8?
}

private struct CaseEvidence: Encodable {
  let id: String
  var source: String
  let sourceSHA256: String?
  var provenance: CorpusProvenance?
  let oneBasedPage: Int
  let zeroBasedPageIndex: Int
  let language: String
  let regions: [RegionEvidence]
  let alignedCoverage: Double
  let automaticCount: Int
  let onDemandCount: Int
  let neverCount: Int
  let digitalSourceBlockCount: Int
  let sourceBlockCount: Int
  let preservedSourceBlockCount: Int
  let omittedSourceBlockCount: Int
  let order: [String]
  let layoutLatencyMilliseconds: UInt64
  let digitalLatencyMilliseconds: UInt64
  let ocrLatencyMilliseconds: UInt64
  let rssBytes: UInt64
  let fallbackActivated: Bool
  let ocrActivated: Bool
  let layoutStatus: String
  let physicalPageCount: Int
  let warmLayoutSamplesMilliseconds: [UInt64]
  let warmLayoutMedianMilliseconds: UInt64
  let warmLayoutPhysicalPageCount: Int
  let normalizedRoute: String
  let normalizedReasonCode: String
  let normalizedStatus: String
  let normalizationElapsedMilliseconds: UInt64
  let unitSourceBlockCounts: [Int]
  let unitCharacterCounts: [Int]
  let visibleSpokenEqualCount: Int
  let firstAutomaticUnitSourceBlockCount: Int?
  let firstAutomaticUnitCharacterCount: Int?
  let contentClassCounts: [String: Int]
  let decisionRuleCounts: [String: Int]
  let outcomes: [String: Bool]
  let errors: [String]

  var warmLayoutMeasurement: WarmLayoutMeasurement {
    WarmLayoutMeasurement(
      id: id, physicalPageCount: warmLayoutPhysicalPageCount,
      samplesMilliseconds: warmLayoutSamplesMilliseconds, rssBytes: rssBytes)
  }

  static func failed(_ testCase: CorpusCase, error: String) -> Self {
    Self(
      id: testCase.id, source: testCase.source, sourceSHA256: testCase.sourceSHA256,
      provenance: testCase.provenance, oneBasedPage: testCase.page,
      zeroBasedPageIndex: testCase.page - 1, language: testCase.language, regions: [],
      alignedCoverage: 0,
      automaticCount: 0, onDemandCount: 0, neverCount: 0, digitalSourceBlockCount: 0,
      sourceBlockCount: 0, preservedSourceBlockCount: 0, omittedSourceBlockCount: 0, order: [],
      layoutLatencyMilliseconds: 0, digitalLatencyMilliseconds: 0, ocrLatencyMilliseconds: 0,
      rssBytes: 0, fallbackActivated: false, ocrActivated: false, layoutStatus: "unavailable",
      physicalPageCount: 0, warmLayoutSamplesMilliseconds: [],
      warmLayoutMedianMilliseconds: 0, warmLayoutPhysicalPageCount: 0,
      normalizedRoute: "not_available", normalizedReasonCode: "not_available",
      normalizedStatus: "not_available", normalizationElapsedMilliseconds: 0,
      unitSourceBlockCounts: [], unitCharacterCounts: [], visibleSpokenEqualCount: 0,
      firstAutomaticUnitSourceBlockCount: nil, firstAutomaticUnitCharacterCount: nil,
      contentClassCounts: [:], decisionRuleCounts: [:],
      outcomes: ["source_available": false], errors: [error])
  }
}
