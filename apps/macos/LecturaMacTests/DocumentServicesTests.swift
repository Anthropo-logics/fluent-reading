import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import NaturalLanguage
import PDFKit
import XCTest

@testable import MacPlatform

final class DocumentServicesTests: XCTestCase {
  @MainActor
  func testOutlineProjectionsPreserveTheirSeparateContracts() throws {
    let url = try makePDF(pageCount: 2, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)
    let firstPage = try XCTUnwrap(document.page(at: 0))
    let secondPage = try XCTUnwrap(document.page(at: 1))
    let root = PDFOutline()
    let chapter = PDFOutline()
    chapter.label = "  Chapter One  "
    chapter.destination = PDFDestination(page: firstPage, at: .zero)
    let section = PDFOutline()
    section.label = "f - 0002"
    section.destination = PDFDestination(page: secondPage, at: .zero)
    chapter.insertChild(section, at: 0)
    root.insertChild(chapter, at: 0)
    document.outlineRoot = root

    let flat = DocumentServices.outlineEntries(from: document)
    XCTAssertEqual(flat.map(\.title), ["  Chapter One  ", "f - 0002"])
    XCTAssertEqual(flat.map(\.pageIndex), [0, 1])

    let hierarchy = DocumentServices.outlineOutline(from: document)
    XCTAssertEqual(hierarchy.map(\.title), ["Chapter One", "f - 0002"])
    XCTAssertEqual(hierarchy.map(\.pageIndex), [0, 1])
    XCTAssertEqual(hierarchy.map(\.level), [0, 1])
  }

  @MainActor
  func testPDFViewReportsAUserVisiblePageChangeAndDropsThePreviousTranslation() throws {
    let url = try makePDF(pageCount: 2, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)
    let view = ReadOnlyPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
    view.document = document
    view.showTranslations(
      [
        TranslatedOverlayBlock(
          unitID: "page-0-unit", pageIndex: 0, rectPDFPoints: [20, 20, 200, 80],
          text: "Translated page zero")
      ], forPage: 0)
    var visiblePages: [Int] = []
    view.onVisiblePageChange = { visiblePages.append($0) }

    view.go(to: try XCTUnwrap(document.page(at: 1)))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    XCTAssertEqual(visiblePages.last, 1)
    XCTAssertFalse(view.hasVisibleTranslationOverlay)
  }

  func testTranslatedOverlayIdentityDistinguishesEqualTextFromDifferentUnits() {
    let first = TranslatedOverlayBlock(
      unitID: "unit-a", pageIndex: 0, rectPDFPoints: [10, 20, 100, 40], text: "Same text")
    let second = TranslatedOverlayBlock(
      unitID: "unit-b", pageIndex: 0, rectPDFPoints: [10, 20, 100, 40], text: "Same text")

    XCTAssertNotEqual(first, second)
  }

  func testLayoutEvidenceDecodesFromOldPayloadAndEncodesWithSnakeCaseKeys() throws {
    let oldPayload =
      #"{"block_id":"old","text":"text","region":{"page_index":0,"rect_pdf_points":[0,0,10,10],"page_rotation_degrees":0,"source_to_page_transform":[1,0,0,1,0,0],"confidence":1},"confidence":1}"#
    let oldBlock = try JSONDecoder().decode(DigitalTextBlock.self, from: Data(oldPayload.utf8))
    XCTAssertNil(oldBlock.layoutRole)
    XCTAssertNil(oldBlock.layoutConfidence)
    XCTAssertNil(oldBlock.layoutOrder)
    XCTAssertNil(oldBlock.narrationDisposition)
    XCTAssertNil(oldBlock.physicalPageIndex)

    let enriched = DigitalTextBlock(
      blockID: "new", text: "text", region: oldBlock.region, confidence: 1,
      layoutRole: .table, layoutConfidence: 0.7, layoutOrder: 9,
      narrationDisposition: .onDemand, physicalPageIndex: 1)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(enriched)) as? [String: Any])
    XCTAssertEqual(object["layout_role"] as? String, "table")
    XCTAssertEqual(object["layout_confidence"] as? Double, 0.7)
    XCTAssertEqual(object["layout_order"] as? Int, 9)
    XCTAssertEqual(object["narration_disposition"] as? String, "on_demand")
    XCTAssertEqual(object["physical_page_index"] as? Int, 1)
  }

  func testDigitalPageResultRetainsEveryNarrationDispositionAndOldPayloadDecodes() throws {
    let source = DigitalSourceRegion(
      pageIndex: 0, rectPDFPoints: [0, 0, 10, 10], pageRotationDegrees: 0,
      sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 1)
    let blocks = [
      DigitalTextBlock(
        blockID: "automatic", text: "automatic", region: source, confidence: 1,
        narrationDisposition: .automatic),
      DigitalTextBlock(
        blockID: "on-demand", text: "on-demand", region: source, confidence: 1,
        narrationDisposition: .onDemand),
      DigitalTextBlock(
        blockID: "never", text: "never", region: source, confidence: 1,
        narrationDisposition: .never),
    ]
    let page = DigitalPageResult(
      pageIndex: 0, status: "completed", blocks: blocks, errorCode: nil,
      layoutStatus: "completed", layoutProcessorRevision: "test",
      layoutElapsedMilliseconds: 7)

    XCTAssertEqual(page.blocks.map(\.blockID), ["automatic", "on-demand", "never"])
    XCTAssertEqual(
      page.blocks.map(\.narrationDisposition), [.automatic, .onDemand, .never])

    let oldPayload = #"{"page_index":0,"status":"completed","blocks":[],"error_code":null}"#
    let oldPage = try JSONDecoder().decode(DigitalPageResult.self, from: Data(oldPayload.utf8))
    XCTAssertNil(oldPage.layoutStatus)
    XCTAssertNil(oldPage.layoutProcessorRevision)
    XCTAssertNil(oldPage.layoutElapsedMilliseconds)
  }

  func testOCRSplitRequiresACompletedTwoPageLayoutWithRegions() {
    func layout(_ regions: [DocumentLayoutRegion]) -> DocumentLayoutResult {
      DocumentLayoutResult(
        regions: regions, physicalPageCount: 2, status: "completed", elapsedMilliseconds: 1,
        processorRevision: "test")
    }
    let region = DocumentLayoutRegion(
      role: .text, disposition: .automatic, confidence: 0.9,
      rectPDFPoints: [0, 0, 100, 100], order: 0, physicalPageIndex: 0)

    XCTAssertFalse(DocumentServices.shouldSplitOCR(for: layout([])))
    XCTAssertTrue(DocumentServices.shouldSplitOCR(for: layout([region])))
  }

  func testBridgeKeepsUnmatchedLeftSpreadProseBeforeMatchedRightProse() async throws {
    func block(_ id: String, _ rect: [Double]) -> DigitalTextBlock {
      DigitalTextBlock(
        blockID: id, text: "\(id).",
        region: DigitalSourceRegion(
          pageIndex: 0, rectPDFPoints: rect, pageRotationDegrees: 0,
          sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 1),
        confidence: 1)
    }
    func region(
      _ rect: [Double], order: UInt32, physicalPageIndex: UInt8
    ) -> DocumentLayoutRegion {
      DocumentLayoutRegion(
        role: .text, disposition: .automatic, confidence: 0.9, rectPDFPoints: rect,
        order: order, physicalPageIndex: physicalPageIndex)
    }

    let sources = [
      block("right-top", [700, 700, 100, 20]),
      block("left-unmatched", [100, 300, 100, 20]),
      block("right-bottom", [700, 100, 100, 20]),
      block("left-matched", [100, 700, 100, 20]),
    ]
    let layout = DocumentLayoutResult(
      regions: [
        region([100, 700, 100, 20], order: 0, physicalPageIndex: 0),
        region([700, 700, 100, 20], order: 1, physicalPageIndex: 1),
        region([700, 100, 100, 20], order: 2, physicalPageIndex: 1),
      ], physicalPageCount: 2, status: "completed", elapsedMilliseconds: 1,
      processorRevision: "test")
    let page = DigitalPageResult(
      pageIndex: 0, status: "completed",
      blocks: DocumentLayoutAlignment.enrich(sources, with: layout), errorCode: nil)

    let encoded = try JSONEncoder().encode(page.blocks)
    let decoded = try JSONDecoder().decode([DigitalTextBlock].self, from: encoded)
    XCTAssertEqual(decoded.first { $0.blockID == "left-unmatched" }?.physicalPageIndex, 0)

    let event = try await EngineClient.normalizePage(
      page, documentFingerprint: String(repeating: "a", count: 64),
      generationID: "generation_partial_spread", language: "en")
    let normalized = try XCTUnwrap(event.result?.normalizedPage)
    XCTAssertEqual(
      normalized.units.flatMap(\.sourceBlockIDs),
      ["left-matched", "left-unmatched", "right-top", "right-bottom"])
  }

  func testSplitSpreadRetriesOnlyTheEmptyPrimaryHalfAndKeepsLeftToRightSourceOrder() throws {
    func block(_ id: String, _ text: String, x: Double) -> DigitalTextBlock {
      DigitalTextBlock(
        blockID: id, text: text,
        region: DigitalSourceRegion(
          pageIndex: 0, rectPDFPoints: [x, 100, 80, 20], pageRotationDegrees: 0,
          sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 0.9),
        confidence: 0.9)
    }

    let primaryLeft = block("page-0-ocr-left-0", "Texto izquierdo primario", x: 20)
    let fallbackRight = block("page-0-ocr-right-0", "Texto derecho recuperado", x: 320)
    var fallbackIndexes: [Int] = []

    let resolution = DocumentServices.resolveOCRHalfBlocks(primary: [[primaryLeft], []]) {
      halfIndex in
      fallbackIndexes.append(halfIndex)
      return halfIndex == 1 ? [fallbackRight] : []
    }

    XCTAssertEqual(fallbackIndexes, [1], "the successful primary half must not be rendered twice")
    XCTAssertFalse(resolution.hasUnresolvedHalf)
    XCTAssertEqual(resolution.blocks.map(\.blockID), [primaryLeft.blockID, fallbackRight.blockID])
    XCTAssertEqual(
      resolution.blocks.map(\.text), ["Texto izquierdo primario", "Texto derecho recuperado"])
    XCTAssertEqual(resolution.blocks[0].region.rectPDFPoints, primaryLeft.region.rectPDFPoints)
    XCTAssertEqual(resolution.blocks[1].region.rectPDFPoints, fallbackRight.region.rectPDFPoints)
  }

  func testSplitSpreadPreservesPrimaryHalfWhenFallbackRasterIsUnavailable() {
    let primaryLeft = DigitalTextBlock(
      blockID: "page-0-ocr-left-0", text: "Texto izquierdo primario",
      region: DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: [20, 100, 80, 20], pageRotationDegrees: 0,
        sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 0.9),
      confidence: 0.9)

    let resolution = DocumentServices.resolveOCRHalfBlocks(
      primary: [[primaryLeft], []], fallback: nil)

    XCTAssertEqual(resolution.blocks.map(\.blockID), [primaryLeft.blockID])
    XCTAssertTrue(resolution.hasUnresolvedHalf)
    XCTAssertEqual(
      DocumentServices.ocrResultStatus(
        blocks: resolution.blocks, hasUnresolvedHalf: resolution.hasUnresolvedHalf,
        renderedBelowTargetScale: false),
      "degraded")
  }

  func testSplitSpreadPreservesPrimaryHalfWhenFallbackRecognitionIsEmpty() {
    let primaryLeft = DigitalTextBlock(
      blockID: "page-0-ocr-left-0", text: "Texto izquierdo primario",
      region: DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: [20, 100, 80, 20], pageRotationDegrees: 0,
        sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 0.9),
      confidence: 0.9)

    let resolution = DocumentServices.resolveOCRHalfBlocks(primary: [[primaryLeft], []]) { _ in [] }

    XCTAssertEqual(resolution.blocks.map(\.blockID), [primaryLeft.blockID])
    XCTAssertTrue(resolution.hasUnresolvedHalf)
    XCTAssertEqual(
      DocumentServices.ocrResultStatus(
        blocks: resolution.blocks, hasUnresolvedHalf: resolution.hasUnresolvedHalf,
        renderedBelowTargetScale: false),
      "degraded")
  }

  @MainActor
  func testOpensRealPDFWithoutChangingPageGeometryRotationOrSource() throws {
    let url = try makePDF(pageCount: 2, rotation: 90)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)
    let reference = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))

    let opened = try DocumentServices.openReadOnly(at: url)

    XCTAssertEqual(opened.pageCount, 2)
    let first = try XCTUnwrap(opened.page(at: 0))
    XCTAssertEqual(first.rotation, 90)
    XCTAssertEqual(first.bounds(for: .cropBox), CGRect(x: 0, y: 0, width: 320, height: 480))
    let expectedColor = try centerColor(of: reference)
    let color = try centerColor(of: first)
    XCTAssertEqual(color.redComponent, expectedColor.redComponent, accuracy: 0.06)
    XCTAssertEqual(color.greenComponent, expectedColor.greenComponent, accuracy: 0.06)
    XCTAssertEqual(color.blueComponent, expectedColor.blueComponent, accuracy: 0.06)
    XCTAssertEqual(try digest(url), before)
  }

  @MainActor
  func testRejectsDamagedPDFWithoutChangingSource() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    try Data("not a pdf".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)

    XCTAssertThrowsError(try DocumentServices.openReadOnly(at: url)) { error in
      XCTAssertEqual(error as? DocumentOpenError, .unreadable)
    }
    XCTAssertEqual(try digest(url), before)
  }

  @MainActor
  func testRejectsEncryptedPDFWithoutChangingSource() throws {
    let document = PDFDocument()
    let image = NSImage(size: NSSize(width: 100, height: 100))
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: 100)).fill()
    image.unlockFocus()
    document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertTrue(
      document.write(
        to: url,
        withOptions: [
          PDFDocumentWriteOption.userPasswordOption: "reader",
          PDFDocumentWriteOption.ownerPasswordOption: "owner",
        ]
      )
    )
    let before = try digest(url)

    XCTAssertThrowsError(try DocumentServices.openReadOnly(at: url)) { error in
      XCTAssertEqual(error as? DocumentOpenError, .encrypted)
    }
    XCTAssertEqual(try digest(url), before)
  }

  @MainActor
  func testEmbeddedGoToActionIsInert() throws {
    let url = try makePDF(pageCount: 2, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)
    let document = try DocumentServices.openReadOnly(at: url)
    let first = try XCTUnwrap(document.page(at: 0))
    let second = try XCTUnwrap(document.page(at: 1))
    let view = ReadOnlyPDFView()
    view.document = document
    view.go(to: first)

    view.perform(PDFActionGoTo(destination: PDFDestination(page: second, at: .zero)))

    XCTAssertTrue(view.currentPage === first)
    XCTAssertEqual(try digest(url), before)
  }

  @MainActor
  func testSourceRegionUsesPreciseOutlineOnlyForReliableGeometry() throws {
    let url = try makePDF(pageCount: 1, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)
    let view = ReadOnlyPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    view.document = document
    view.layoutSubtreeIfNeeded()

    view.show(
      DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: [40, 80, 120, 30], pageRotationDegrees: 0,
        sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 1),
      in: document)
    XCTAssertGreaterThan(view.sourceIndicatorBounds.width, 4)

    view.show(
      DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: [], pageRotationDegrees: 0,
        sourceToPageTransform: [], confidence: 0),
      in: document)
    XCTAssertEqual(view.sourceIndicatorBounds.width, 4)
  }

  /// AC7 of Story 5.6: an uncertain source region must keep using the fallback marker even while a
  /// translation is on screen, and never be replaced by a precise-looking indicator it cannot back up.
  @MainActor
  func testUncertainGeometryFallbackSurvivesAlongsideATranslationOverlay() throws {
    let url = try makePDF(pageCount: 1, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)
    let view = ReadOnlyPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    view.document = document
    view.layoutSubtreeIfNeeded()

    view.showTranslations(
      [
        TranslatedOverlayBlock(
          unitID: "translated-unit", pageIndex: 0, rectPDFPoints: [40, 700, 500, 40],
          text: "Translated.")
      ],
      forPage: 0)
    view.show(
      DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: [], pageRotationDegrees: 0,
        sourceToPageTransform: [], confidence: 0),
      in: document)

    XCTAssertEqual(
      view.sourceIndicatorBounds.width, 4,
      "geometría incierta debe seguir usando el indicador de respaldo, no simular precisión")
  }

  @MainActor
  func testExtractsDigitalLinesWithGeometryAndPreservesFailedPagesAndSource() throws {
    let url = try makeTextPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)
    let document = try DocumentServices.openReadOnly(at: url)

    let pages = DocumentServices.extractDigitalPages(from: document)

    XCTAssertEqual(pages.count, 2)
    XCTAssertEqual(pages[0].status, "completed")
    XCTAssertEqual(pages[0].blocks.map(\.text), ["Primera línea", "Segunda línea"])
    XCTAssertEqual(pages[0].blocks[0].region.pageRotationDegrees, 90)
    XCTAssertEqual(pages[0].blocks[0].region.sourceToPageTransform, [1, 0, 0, 1, 0, 0])
    XCTAssertGreaterThan(pages[0].blocks[0].region.rectPDFPoints[2], 0)
    XCTAssertEqual(pages[1].status, "failed")
    XCTAssertEqual(pages[1].errorCode, "LF_PDF_PAGE_NO_TEXT")
    XCTAssertEqual(try digest(url), before)
  }

  /// Story 6.14. Every line of the page is read, including the ones the margins do not touch.
  ///
  /// The extraction used to ask for the text between the two corners of the page
  /// (`PDFDocument.selection(from:at:to:at:)`), which selects the run between the characters
  /// *nearest those two points*, not the rectangle they span. A centred title is further from the
  /// top-left corner than the body line below it, and a centred closing note is further from the
  /// bottom-right corner than the body line above it, so both fell outside the run and the reader
  /// never heard them — no error, no indication, just a page missing its first and last line.
  ///
  /// The page below is that shape, and it is the shape of real documents: measured over the
  /// owner's 818 PDFs, 2,333 pages of 67,197 lost more than a tenth of their letters this way and
  /// one page of 2,081 letters came back with 183.
  @MainActor
  func testExtractsLinesTheMarginsDoNotTouch() throws {
    let url = try makeOffCentreLinesPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)
    let document = try DocumentServices.openReadOnly(at: url)

    let pages = DocumentServices.extractDigitalPages(from: document)

    XCTAssertEqual(
      pages[0].blocks.map(\.text),
      [
        "Título centrado", "Primera línea", "Segunda línea", "Cierre del cuerpo hasta el margen",
        "Nota final",
      ],
      "ni el título centrado ni la nota final tocan los márgenes, y aun así se leen")
    // The recovered lines carry usable geometry, which is what the reading marker and "read from
    // here" point at: each box sits where its line was drawn.
    let title = try XCTUnwrap(pages[0].blocks.first).region.rectPDFPoints
    XCTAssertEqual(title[0], 110, accuracy: 6)
    XCTAssertEqual(title[1], 440, accuracy: 6)
    XCTAssertGreaterThan(title[2], 0)
    XCTAssertGreaterThan(title[3], 0)
    let note = try XCTUnwrap(pages[0].blocks.last).region.rectPDFPoints
    XCTAssertEqual(note[0], 120, accuracy: 6)
    XCTAssertEqual(note[1], 40, accuracy: 6)
    XCTAssertEqual(try digest(url), before)
  }

  /// A page with a single character still has to come back as a page with a single character:
  /// asking for a character range is only safe if its ends are right.
  @MainActor
  func testExtractsAPageHoldingOneCharacter() throws {
    let url = try makeLinesPDF([("7", CGPoint(x: 160, y: 240))])
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)

    let pages = DocumentServices.extractDigitalPages(from: document)

    XCTAssertEqual(pages[0].status, "completed")
    XCTAssertEqual(pages[0].blocks.map(\.text), ["7"])
  }

  @MainActor
  func testMatchedSuperscriptCalloutStaysVisibleButNeverReachesTheSpokenPlan() async throws {
    let url = try makeFootnoteCalloutPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)

    let page = DocumentServices.extractDigitalPages(from: document)[0]
    let body = try XCTUnwrap(page.blocks.first(where: { $0.text.contains("fuente1") }))

    XCTAssertEqual(body.text, "En 2011 hubo 20 casos; la fuente1 confirmó 59.1%.")
    XCTAssertEqual(body.spokenText, "En 2011 hubo 20 casos; la fuente confirmó 59.1%.")

    let folio = DigitalTextBlock(
      blockID: "folio-46", text: "46",
      region: DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: [240, 15, 20, 10], pageRotationDegrees: 0,
        sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 1),
      confidence: 1, layoutRole: .number, layoutConfidence: 1,
      layoutOrder: UInt32(page.blocks.count), narrationDisposition: .never,
      physicalPageIndex: 0)
    let bridgedPage = DigitalPageResult(
      pageIndex: page.pageIndex, status: page.status, blocks: page.blocks + [folio], errorCode: nil)
    let encodedBlocks = String(
      decoding: try JSONEncoder().encode(bridgedPage.blocks), as: UTF8.self)
    XCTAssertTrue(encodedBlocks.contains(#""spoken_text""#))
    XCTAssertTrue(encodedBlocks.contains(#""narration_disposition":"never""#))

    let normalization = try await EngineClient.normalizePage(
      bridgedPage, documentFingerprint: String(repeating: "f", count: 64),
      generationID: "generation_footnote", language: "es")
    let normalized = try XCTUnwrap(normalization.result?.normalizedPage)
    let normalizedBody = try XCTUnwrap(
      normalized.units.first(where: { $0.sourceBlockIDs.contains(body.blockID) }))
    XCTAssertTrue(normalizedBody.text.contains("fuente1"), "el marcador sigue visible")
    XCTAssertTrue(normalizedBody.narrationText.contains("fuente confirmó"))
    XCTAssertFalse(normalizedBody.narrationText.contains("fuente1"))

    let normalizedFolio = try XCTUnwrap(
      normalized.units.first(where: { $0.sourceBlockIDs.contains(folio.blockID) }))
    XCTAssertEqual(normalizedFolio.text, "46", "el folio también conserva evidencia visible")
    XCTAssertEqual(normalizedFolio.resolvedNarrationDisposition, .never)
    let automatic = normalized.units.filter { $0.resolvedNarrationDisposition == .automatic }
    XCTAssertFalse(automatic.flatMap(\.sourceBlockIDs).contains(folio.blockID))
    let plans = try automatic.map {
      try EngineClient.spokenPlan(text: $0.narrationText, language: "es")
    }
    let plannedSpeech = plans.map(\.normalizedText).joined(separator: " ")
    XCTAssertTrue(plannedSpeech.contains("fuente confirmó"))
    XCTAssertFalse(plannedSpeech.contains("fuente1"), "el dígito elevado no llega a la voz")
    XCTAssertFalse(plannedSpeech.split(whereSeparator: \.isWhitespace).contains("46"))
  }

  func testFootnoteDigitScanRejectsUnicodeSurrogatesWithoutCrashing() throws {
    let one = try XCTUnwrap("1".utf16.first)
    XCTAssertTrue(DocumentServices.isDecimalDigit(one))
    XCTAssertTrue("😀".utf16.allSatisfy { !DocumentServices.isDecimalDigit($0) })
  }

  @MainActor
  func testDigitalExtractionHonorsPageLimit() throws {
    let url = try makeTextPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)

    let pages = DocumentServices.extractDigitalPages(from: document, pageLimit: 1)

    XCTAssertEqual(pages.map(\.pageIndex), [0])
  }

  @MainActor
  func testAsyncDigitalExtractionProcessesOnlyRequestedPage() async throws {
    let url = try makeTextPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)

    let page = await DocumentServices.extractDigitalPage(at: url, pageIndex: 0)

    XCTAssertEqual(page.pageIndex, 0)
    XCTAssertEqual(page.status, "completed")
    XCTAssertEqual(page.blocks.map(\.text), ["Primera línea", "Segunda línea"])
    XCTAssertEqual(try digest(url), before)
  }

  func testOCRRepairsOnlySuspiciousGlyphRunsAndPreservesLegitimateHashAndDigits() {
    func block(_ id: String, _ text: String, _ rect: [Double], confidence: Double = 1)
      -> DigitalTextBlock
    {
      DigitalTextBlock(
        blockID: id, text: text,
        region: DigitalSourceRegion(
          pageIndex: 0, rectPDFPoints: rect, pageRotationDegrees: 0,
          sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: confidence),
        confidence: confidence)
    }
    let direct = DigitalPageResult(
      pageIndex: 0, status: "completed",
      blocks: [
        block("word", "All children received su#-", [68, 320, 294, 12]),
        block("word-continuation", "cient nutrition.", [68, 307, 294, 12]),
        block("parenthetical-a", "ICBF, because of its service’!", [68, 280, 201, 12]),
        block("parenthetical-b", "– i.e. child protection!", [269, 280, 89, 12]),
        block("parenthetical-c", "–", [358, 280, 5, 12]),
        block("code", "C# is a legitimate identifier.", [68, 250, 294, 12]),
        block("letter", "porque no se extendio la relacion sa!arial", [68, 238, 294, 12]),
        block("note", "Domestic law8 as integral protection:!", [68, 225, 230, 12]),
        block("note-marker", "9 this included education.", [298, 225, 65, 12]),
      ], errorCode: nil)
    let recognized = DigitalPageResult(
      pageIndex: 0, status: "completed",
      blocks: [
        block("ocr-word", "All children received suffi-", [68, 320, 294, 12], confidence: 0.98),
        block("ocr-word-continuation", "cient nutrition.", [68, 307, 294, 12], confidence: 0.98),
        block(
          "ocr-parenthetical", "ICBF, because of its service’ – i.e. child protection –",
          [68, 280, 295, 12], confidence: 0.98),
        block("ocr-code", "C# is a legitimate identifier.", [68, 250, 294, 12], confidence: 0.98),
        block(
          "ocr-letter", "porque no se extendio la relacion salarial", [68, 238, 294, 12],
          confidence: 0.98),
        block(
          "ocr-note", "Domestic law as integral protection: ' this included education.",
          [68, 225, 295, 12], confidence: 0.98),
      ], errorCode: nil)

    let repaired = DocumentServices.repairDigitalText(direct, with: recognized)
    let text = repaired.blocks.map(\.text).joined(separator: "\n")

    XCTAssertTrue(text.contains("suffi-\ncient"), text)
    XCTAssertTrue(text.contains("service’ – i.e. child protection –"), text)
    XCTAssertTrue(text.contains("C# is a legitimate identifier"), text)
    XCTAssertTrue(text.contains("relacion salarial"), text)
    XCTAssertTrue(text.contains("law8 as integral protection: 9 this included"), text)
    XCTAssertFalse(text.contains("su#"), text)
    XCTAssertFalse(text.contains(":!"), text)
  }

  func testAsyncDigitalExtractionAutomaticallyRepairsBordaWithVisionEvidence() async throws {
    guard let path = gateEnvironment("LECTURA_REAL_BOOK_PDF") else {
      throw XCTSkip("Set LECTURA_REAL_BOOK_PDF for the real damaged-character-map regression")
    }
    let page = await DocumentServices.extractDigitalPage(
      at: URL(fileURLWithPath: path), pageIndex: 9)
    let text = page.blocks.map(\.text).joined(separator: " ")

    XCTAssertTrue(text.contains("service’ – i.e. child protection –"), text)
    XCTAssertFalse(text.contains(":!"), text)
    XCTAssertTrue(text.contains("institution.20"), text)
    let pageTenEvent = try await EngineClient.normalizePage(
      page, documentFingerprint: "borda-regression", generationID: "generation-borda",
      language: "en", route: "direct_text")
    let pageTen = try XCTUnwrap(pageTenEvent.result?.normalizedPage)
    XCTAssertFalse(pageTen.units.contains { $0.contentClass == "formula" })
    let pageTenSpoken = pageTen.units.map(\.narrationText).joined(separator: " ")
    XCTAssertFalse(pageTenSpoken.contains("institution.20"), pageTenSpoken)
    XCTAssertFalse(pageTenSpoken.contains("contract.21"), pageTenSpoken)
    XCTAssertTrue(pageTenSpoken.contains("1979"), pageTenSpoken)
    XCTAssertTrue(
      pageTen.units.contains {
        $0.text.contains("An exceptional administrative contract")
          && $0.text.contains("can enact this type of contract.21")
      }, pageTen.units.map(\.text).joined(separator: "\n---\n"))

    let earlier = await DocumentServices.extractDigitalPage(
      at: URL(fileURLWithPath: path), pageIndex: 6)
    let event = try await EngineClient.normalizePage(
      earlier, documentFingerprint: "borda-regression", generationID: "generation-borda",
      language: "en", route: "direct_text")
    let normalized = try XCTUnwrap(event.result?.normalizedPage)
    let visible = normalized.units.map(\.text).joined(separator: " ")
    let spoken = normalized.units.map(\.narrationText).joined(separator: " ")
    XCTAssertTrue(visible.contains("sufficient nutrition"), visible)
    XCTAssertTrue(visible.contains("the state"), visible)
    XCTAssertTrue(visible.contains("care.7"), visible)
    XCTAssertTrue(visible.contains("law8"), visible)
    XCTAssertFalse(spoken.contains("care.7"), spoken)
    XCTAssertFalse(spoken.contains("law8"), spoken)
    XCTAssertTrue(spoken.contains("1979"), spoken)
  }

  func testOCRRepairGeneralizesAcrossRealCorpusWithoutChangingLegitimateHashes() async throws {
    guard let root = corpusRoot else { throw XCTSkip("LECTURA_PDF_CORPUS no configurada") }
    let relatives = try FileManager.default.subpathsOfDirectory(atPath: root.path)
    func pdf(_ name: String) throws -> URL {
      try XCTUnwrap(
        relatives.first { URL(fileURLWithPath: $0).lastPathComponent == name }
          .map(root.appendingPathComponent), "No se encontró \(name) en el corpus")
    }
    func extract(_ name: String, page: Int, language: String) async throws -> DigitalPageResult {
      let extracted = await DocumentServices.extractDigitalPage(
        at: try pdf(name), pageIndex: page - 1, language: language)
      XCTAssertEqual(extracted.status, "completed", "\(name) p\(page)")
      return extracted
    }
    func content(_ page: DigitalPageResult) -> String {
      page.blocks.map(\.text).joined(separator: " ")
    }

    let bordaSevenPage = try await extract(
      "BordaCarulla2018-fulltext.pdf", page: 7, language: "en")
    let bordaTenPage = try await extract(
      "BordaCarulla2018-fulltext.pdf", page: 10, language: "en")
    let bordaEighteenPage = try await extract(
      "BordaCarulla2018-fulltext.pdf", page: 18, language: "en")
    let bordaSeven = content(bordaSevenPage)
    let bordaTen = content(bordaTenPage)
    let bordaEighteen = content(bordaEighteenPage)
    XCTAssertTrue(bordaSeven.contains("suffi- cient nutrition"), bordaSeven)
    XCTAssertFalse(bordaSeven.contains(":!"), bordaSeven)
    XCTAssertTrue(bordaTen.contains("community homes: the law"), bordaTen)
    XCTAssertTrue(bordaEighteen.contains("16 years old"), bordaEighteen)
    XCTAssertTrue(bordaEighteen.contains("almost 30 years"), bordaEighteen)

    let vegaPage = try await extract("VegaVargas2010-fulltext.pdf", page: 45, language: "es")
    let vega = content(vegaPage)
    XCTAssertTrue(vega.contains("relacion salarial"), vega)

    for (id, page, language) in [
      ("borda-7", bordaSevenPage, "en"), ("borda-10", bordaTenPage, "en"),
      ("borda-18", bordaEighteenPage, "en"), ("vega-45", vegaPage, "es"),
    ] {
      let event = try await EngineClient.normalizePage(
        page, documentFingerprint: "glyph-corpus-\(id)", generationID: "generation-\(id)",
        language: language, route: "direct_text")
      let normalized = try XCTUnwrap(event.result?.normalizedPage)
      XCTAssertFalse(
        normalized.units.contains { $0.contentClass == "formula" },
        "\(id): \(normalized.units.filter { $0.contentClass == "formula" }.map(\.text))")
    }

    let legitimateHashes = [
      content(try await extract("Carrillo2014-fulltext.pdf", page: 50, language: "en")),
      content(try await extract("Carrillo2014-fulltext.pdf", page: 363, language: "en")),
      content(try await extract("SubdireccionGeneral2023-fulltext.pdf", page: 87, language: "es")),
      content(try await extract("AlviarGarcia2011-fulltext.pdf", page: 3, language: "en")),
    ].joined(separator: "\n")
    for fragment in ["#91", ".html#top", ".pdf#page=2", "#twoj_fragment1-3"] {
      XCTAssertTrue(
        legitimateHashes.contains(fragment), "Se alteró \(fragment): \(legitimateHashes)")
    }
  }

  @MainActor
  func testExtractsScannedPageWithVisionAndPreservesSource() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = root.appendingPathComponent("tests/corpus/documents/en-single-scanned.pdf")
    let before = try digest(url)
    let document = try DocumentServices.openReadOnly(at: url)

    let pages = DocumentServices.extractOCRPages(
      from: document, pageIndexes: [0], language: "en")

    XCTAssertEqual(pages.count, 1)
    XCTAssertEqual(pages[0].status, "degraded")
    XCTAssertEqual(pages[0].blocks.map(\.text), ["READING IN ENGLISH 1"])
    XCTAssertGreaterThan(pages[0].blocks[0].confidence, 0.9)
    XCTAssertGreaterThan(pages[0].blocks[0].region.rectPDFPoints[2], 0)
    XCTAssertEqual(try digest(url), before)
  }

  func testAsyncOCRProcessesOnlyRequestedPageOffTheMainActor() async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = root.appendingPathComponent("tests/corpus/documents/en-single-scanned.pdf")
    let before = try digest(url)

    let page = await DocumentServices.extractOCRPage(at: url, pageIndex: 0, language: "en")

    XCTAssertEqual(page.pageIndex, 0)
    XCTAssertFalse(page.blocks.isEmpty)
    XCTAssertGreaterThan(page.blocks[0].confidence, 0.9)
    XCTAssertGreaterThan(page.blocks[0].region.rectPDFPoints[2], 0)
    XCTAssertEqual(try digest(url), before)
  }

  func testNativePDFRasterKeepsInkAtTheRequestedPixelSize() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = root.appendingPathComponent("tests/corpus/documents/en-single-scanned.pdf")
    let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))

    let image = try XCTUnwrap(
      PDFPageRasterizer.image(of: page, pixelSize: CGSize(width: 320, height: 240)))

    XCTAssertEqual(image.width, 320)
    XCTAssertEqual(image.height, 240)
    let bitmap = NSBitmapImageRep(cgImage: image)
    let ink = stride(from: 0, to: image.height, by: 4).reduce(into: 0) { count, y in
      for x in stride(from: 0, to: image.width, by: 4) {
        guard
          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { continue }
        if color.redComponent + color.greenComponent + color.blueComponent < 2.85 {
          count += 1
        }
      }
    }
    XCTAssertGreaterThan(ink, 10, "the scanned page rendered as an empty white bitmap")
  }

  func testDigitalExtractionReportsRasterContentWithoutRunningOCR() async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let mixed = root.appendingPathComponent("tests/corpus/documents/es-mixed.pdf")
    let digital = root.appendingPathComponent("tests/corpus/documents/es-single-digital.pdf")

    let mixedPage = await DocumentServices.extractDigitalPage(at: mixed, pageIndex: 0)
    let digitalPage = await DocumentServices.extractDigitalPage(at: digital, pageIndex: 0)

    XCTAssertEqual(mixedPage.rasterContentDetected, true)
    XCTAssertEqual(digitalPage.rasterContentDetected, false)
    XCTAssertEqual(mixedPage.blocks.count, 1, "raster detection must not perform OCR itself")
  }

  func testOCRRenderUsesDisplayedAxesForQuarterTurnedPages() {
    let bounds = CGRect(x: 10, y: 20, width: 831, height: 584)

    XCTAssertEqual(
      DocumentServices.ocrRenderSize(pageBounds: bounds, rotation: 0, scale: 2),
      CGSize(width: 1_662, height: 1_168))
    for rotation in [90, 270] {
      XCTAssertEqual(
        DocumentServices.ocrRenderSize(pageBounds: bounds, rotation: rotation, scale: 2),
        CGSize(width: 1_168, height: 1_662))
    }
  }

  /// A page turned by the reader is read along the axis the reader chose (Story 6.15).
  ///
  /// Some pages are printed sideways and the file says nothing about it, so PDFKit has nothing to
  /// correct: 84 pages of 25 documents in the reference corpus of 818 PDFs. The reader turns the
  /// page, and the same orientation is handed to extraction so the narration follows.
  ///
  /// What makes this exact rather than clever is that PDFKit's line rectangles do not depend on
  /// `rotation` at all: the boxes come back to the hundredth of a point identical at all four
  /// quarter turns, so the words keep their place on the page and only the axis they are read
  /// along changes. That invariance is asserted here, because the whole mechanism rests on it.
  func testAReaderChosenRotationChangesTheReadingAxisAndNothingElse() async throws {
    let url = try makeLinesPDF([
      ("Primera línea", CGPoint(x: 20, y: 410)),
      ("Segunda línea", CGPoint(x: 20, y: 390)),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)

    let upright = await DocumentServices.extractDigitalPage(at: url, pageIndex: 0)
    XCTAssertEqual(upright.blocks.first?.region.pageRotationDegrees, 0)

    for rotation in [90, 180, 270] {
      let turned = await DocumentServices.extractDigitalPage(
        at: url, pageIndex: 0, rotation: rotation)
      XCTAssertEqual(
        turned.blocks.map(\.text), upright.blocks.map(\.text), "rotation \(rotation): text moved")
      XCTAssertEqual(
        turned.blocks.map(\.region.rectPDFPoints), upright.blocks.map(\.region.rectPDFPoints),
        "rotation \(rotation): the rectangles left the words")
      XCTAssertEqual(
        turned.blocks.map(\.region.pageRotationDegrees), turned.blocks.map { _ in rotation },
        "rotation \(rotation): the engine was not told which way to read")
    }

    // The reader's choice never reaches the file.
    XCTAssertEqual(try digest(url), before)
  }

  /// Where OCR says a line is, on a page the PDF itself tags as turned.
  ///
  /// `PDFPage.thumbnail(of:for:)` renders the page **as displayed** — rotation applied — while
  /// `bounds(for: .cropBox)` reports the box in unrotated page space. Scaling Vision's normalised
  /// box by the crop box's own width and height therefore put every recognised line of a turned
  /// page somewhere it is not, and nothing noticed: the rectangle is what highlighting, "read from
  /// here" and the engine's reading order all trust.
  ///
  /// The check is the one that cannot be satisfied by accident: the two extraction routes have to
  /// agree. The same lines are asked of the text layer and of Vision, and each OCR box has to land
  /// on the direct-text box for the same words.
  @MainActor
  func testOCRBoxesLandOnThePageWhenTheDocumentSaysItIsTurned() throws {
    for rotation in [90, 180, 270] {
      let url = try makeRotatedLinesPDF(rotation: rotation)
      defer { try? FileManager.default.removeItem(at: url) }
      let before = try digest(url)
      let document = try DocumentServices.openReadOnly(at: url)

      let direct = DocumentServices.extractDigitalPages(from: document)[0]
      let recognised = DocumentServices.extractOCRPages(
        from: document, pageIndexes: [0], language: "es")[0]

      XCTAssertFalse(direct.blocks.isEmpty, "rotation \(rotation): no text layer to compare with")
      XCTAssertFalse(recognised.blocks.isEmpty, "rotation \(rotation): Vision read nothing")

      for block in recognised.blocks {
        let words = block.text.split(separator: " ").first.map(String.init) ?? block.text
        guard
          let twin = direct.blocks.first(where: {
            $0.text.hasPrefix(words) || words.hasPrefix($0.text)
          })
        else { continue }
        let ocrRect = rect(block.region.rectPDFPoints)
        let textRect = rect(twin.region.rectPDFPoints)
        XCTAssertTrue(
          ocrRect.intersects(textRect),
          """
          rotation \(rotation): OCR put "\(block.text)" at \(ocrRect) while the page's own text           layer has it at \(textRect)
          """)
        // Both routes have to agree which way the line runs, or the engine orders them by
        // different axes and the narration interleaves the page.
        XCTAssertEqual(
          ocrRect.width > ocrRect.height, textRect.width > textRect.height,
          "rotation \(rotation): the two routes disagree about the axis of \"\(block.text)\"")
      }
      XCTAssertEqual(try digest(url), before)
    }
  }

  /// An upright page keeps the mapping it always had: the quarter turn is the identity there, and
  /// the overwhelming majority of real pages are upright.
  @MainActor
  func testOCRBoxesOnAnUprightPageAreUnchanged() throws {
    let url = try makeLinesPDF([
      ("Primera linea de la pagina", CGPoint(x: 20, y: 410)),
      ("Segunda linea mas abajo", CGPoint(x: 20, y: 380)),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentServices.openReadOnly(at: url)
    let page = try XCTUnwrap(document.page(at: 0))
    let bounds = page.bounds(for: .cropBox)

    let recognised = DocumentServices.extractOCRPages(
      from: document, pageIndexes: [0], language: "es")[0]

    XCTAssertFalse(recognised.blocks.isEmpty)
    for block in recognised.blocks {
      let box = rect(block.region.rectPDFPoints)
      XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(box), "\(box) escaped \(bounds)")
      XCTAssertGreaterThan(box.width, box.height, "a line of upright type is wider than it is tall")
    }
  }

  private func rect(_ values: [Double]) -> CGRect {
    CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }

  /// The lines fixture, re-saved with the page tagged as turned. The ink is drawn exactly as for an
  /// upright page — only the `/Rotate` entry changes — which is precisely the case that matters:
  /// the text layer reports page space and the render applies the rotation.
  private func makeRotatedLinesPDF(rotation: Int) throws -> URL {
    let flat = try makeLinesPDF([
      ("Primera linea de la pagina", CGPoint(x: 20, y: 410)),
      ("Segunda linea mas abajo", CGPoint(x: 20, y: 380)),
      ("Tercera linea del cuerpo", CGPoint(x: 20, y: 350)),
    ])
    defer { try? FileManager.default.removeItem(at: flat) }
    let document = try XCTUnwrap(PDFDocument(url: flat))
    document.page(at: 0)?.rotation = rotation
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    XCTAssertTrue(document.write(to: url))
    return url
  }

  /// A page whose ink is printed sideways and whose file says nothing about it — the case the
  /// manual rotation control exists for.
  ///
  /// The type is drawn with the quarter turn on the coordinate system, so the lines run *up* the
  /// page, and then flattened into a picture: the page carries no text layer at all, like the
  /// photographed sheets it stands in for. `/Rotate` stays 0, which is the whole point — nothing in
  /// the file says the page is sideways, so only the reader can.
  private func makeSidewaysImagePDF() throws -> URL {
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 480)
    let scale = 3.0
    let bitmap = try XCTUnwrap(
      CGContext(
        data: nil, width: Int(mediaBox.width * scale), height: Int(mediaBox.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: mediaBox.width * scale, height: mediaBox.height * scale))
    bitmap.scaleBy(x: scale, y: scale)
    bitmap.setFillColor(gray: 0, alpha: 1)
    bitmap.translateBy(x: 140, y: 60)
    bitmap.rotate(by: .pi / 2)
    for (text, across) in [
      ("La experiencia vivida del negro", 0.0),
      ("Piel negra y mascaras blancas", -50.0),
      ("Un libro sobre el hombre y su mundo", -100.0),
    ] {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
      bitmap.textPosition = CGPoint(x: 0, y: across)
      CTLineDraw(line, bitmap)
    }
    let picture = try XCTUnwrap(bitmap.makeImage())

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    // No flip: `draw(_:in:)` already puts the first row of the picture at the top of the rectangle,
    // which is where PDF wants it (lecciones-operativas §3.2).
    context.draw(picture, in: mediaBox)
    context.endPDFPage()
    context.closePDF()
    return url
  }

  private func makePDF(pageCount: Int, rotation: Int) throws -> URL {
    let rawURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    defer { try? FileManager.default.removeItem(at: rawURL) }
    let consumer = try XCTUnwrap(CGDataConsumer(url: rawURL as CFURL))
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 480)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    for _ in 0..<pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 0.18, green: 0.32, blue: 0.72, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
      context.endPDFPage()
    }
    context.closePDF()
    let document = try XCTUnwrap(PDFDocument(url: rawURL))
    document.page(at: 0)?.rotation = rotation
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    XCTAssertTrue(document.write(to: url))
    return url
  }

  /// A page whose first and last lines are centred, so neither of them is the character nearest a
  /// corner of the page (Story 6.14).
  private func makeOffCentreLinesPDF() throws -> URL {
    try makeLinesPDF([
      ("Título centrado", CGPoint(x: 110, y: 440)),
      ("Primera línea", CGPoint(x: 20, y: 410)),
      ("Segunda línea", CGPoint(x: 20, y: 390)),
      ("Cierre del cuerpo hasta el margen", CGPoint(x: 20, y: 60)),
      ("Nota final", CGPoint(x: 120, y: 40)),
    ])
  }

  private func makeLinesPDF(_ lines: [(String, CGPoint)]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 480)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    for (text, origin) in lines {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
      context.textPosition = origin
      CTLineDraw(line, context)
    }
    context.endPDFPage()
    context.closePDF()
    return url
  }

  private func makeFootnoteCalloutPDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
    var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)

    let body = NSMutableAttributedString(
      string: "En 2011 hubo 20 casos; la fuente1 confirmó 59.1%.",
      attributes: [.font: NSFont.systemFont(ofSize: 14)])
    let source = (body.string as NSString).range(of: "fuente1")
    let callout = NSRange(location: NSMaxRange(source) - 1, length: 1)
    body.addAttributes(
      [.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 5], range: callout)
    context.textPosition = CGPoint(x: 50, y: 600)
    CTLineDraw(CTLineCreateWithAttributedString(body), context)

    let note = NSAttributedString(
      string: "1. Referencia bibliográfica de control.",
      attributes: [.font: NSFont.systemFont(ofSize: 9)])
    context.textPosition = CGPoint(x: 50, y: 60)
    CTLineDraw(CTLineCreateWithAttributedString(note), context)
    context.endPDFPage()
    context.closePDF()
    return url
  }

  private func makeTextPDF() throws -> URL {
    let rawURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    defer { try? FileManager.default.removeItem(at: rawURL) }
    let consumer = try XCTUnwrap(CGDataConsumer(url: rawURL as CFURL))
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 480)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    for (text, y) in [("Primera línea", 400.0), ("Segunda línea", 360.0)] {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text,
          attributes: [.font: NSFont.systemFont(ofSize: 18)]
        ))
      context.textPosition = CGPoint(x: 30, y: y)
      CTLineDraw(line, context)
    }
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    let document = try XCTUnwrap(PDFDocument(url: rawURL))
    document.page(at: 0)?.rotation = 90
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    XCTAssertTrue(document.write(to: url))
    return url
  }

  private func digest(_ url: URL) throws -> SHA256.Digest {
    SHA256.hash(data: try Data(contentsOf: url))
  }

  private func centerColor(of page: PDFPage) throws -> NSColor {
    let thumbnail = page.thumbnail(of: NSSize(width: 100, height: 100), for: .cropBox)
    let bitmap = try XCTUnwrap(
      thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    )
    let sampled = try XCTUnwrap(
      bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
    )
    return try XCTUnwrap(sampled.usingColorSpace(.deviceRGB))
  }
}

/// Text-layer prescan of the table of contents. These tests run against the user's own PDF corpus,
/// pointed to by environment variables, because the behaviour under test is precisely how real
/// scanned and born-digital books are typeset — a synthetic PDF proves nothing here.
extension DocumentServicesTests {
  private var corpusRoot: URL? {
    gateEnvironment("LECTURA_PDF_CORPUS").map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
  }

  @MainActor
  func testPrescanRecoversFullChapterStructureFromScannedBookWithoutOCR() throws {
    guard let path = gateEnvironment("LECTURA_SCANNED_BOOK_PDF") else {
      throw XCTSkip("LECTURA_SCANNED_BOOK_PDF no configurada")
    }
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))

    let started = Date()
    let headings = DocumentServices.prescanHeadings(from: document)
    let elapsed = Date().timeIntervalSince(started)

    // The whole point is that navigation is ready before OCR has processed anything.
    XCTAssertLessThan(elapsed, 15, "el preindexado debe costar segundos, no minutos")
    // Seven Fanon chapters plus six appendix chapters, all set in the largest face.
    let chapters = headings.filter { $0.level == 0 }
    XCTAssertEqual(chapters.count, 13, "faltan capítulos: \(chapters.map(\.title))")
    XCTAssertTrue(
      headings.contains { $0.title.lowercased().contains("experiencia vivida") },
      "el capítulo V se pierde si se exige inicial mayúscula: la capa lo codifica como «v»")
    XCTAssertTrue(headings.contains { $0.title.lowercased().hasPrefix("prefacio") })
    // Multi-line titles must arrive whole, not truncated at the first line.
    XCTAssertTrue(
      headings.contains { $0.title.lowercased().contains("psicopatolog") },
      "los títulos de dos renglones deben unirse")
  }

  @MainActor
  func testPrescanNeverProducesARunningHeadOrAnUnusablyLongNavigator() throws {
    guard let root = corpusRoot else { throw XCTSkip("LECTURA_PDF_CORPUS no configurada") }
    let pdfs = try FileManager.default
      .subpathsOfDirectory(atPath: root.path)
      .filter { $0.hasSuffix(".pdf") }
      .sorted()
      .prefix(25)
    try XCTSkipIf(pdfs.isEmpty, "corpus vacío")

    var checked = 0
    for relative in pdfs {
      guard let document = PDFDocument(url: root.appendingPathComponent(relative)),
        document.pageCount > 0
      else { continue }
      checked += 1
      let headings = DocumentServices.prescanHeadings(from: document)

      // A navigator longer than the book itself is noise; the prescan must bail out instead.
      XCTAssertLessThanOrEqual(
        headings.count, max(4, document.pageCount * 3 / 5),
        "\(relative) devuelve un índice más largo que el propio documento")

      // A running head repeats on many pages; no title may appear on three or more.
      var pages: [String: Set<Int>] = [:]
      for heading in headings {
        pages[heading.title.lowercased(), default: []].insert(heading.pageIndex)
      }
      for (title, appearances) in pages {
        XCTAssertLessThan(
          appearances.count, 3, "\(relative): «\(title)» es un encabezado de página, no un título")
      }

      for heading in headings {
        XCTAssertFalse(heading.title.isEmpty)
        XCTAssertGreaterThanOrEqual(heading.title.filter(\.isLetter).count, 3, "\(relative)")
        XCTAssertTrue(
          (0..<document.pageCount).contains(heading.pageIndex),
          "\(relative): página fuera de rango")
      }
    }
    XCTAssertGreaterThan(checked, 10, "no se pudo abrir suficiente corpus para una prueba real")
  }
}

extension DocumentServicesTests {
  @MainActor
  func testKeptTextIsReadableWithoutChangingHowThePageLooks() throws {
    let url = try makePDF(pageCount: 1, rotation: 90)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
    let appearance = try centerColor(of: original)
    let crop = original.bounds(for: .cropBox)

    try OCRTextLayer.embed(
      [
        0: recognisedPage([
          "Piel negra, máscaras blancas": CGRect(x: 40, y: 300, width: 200, height: 20)
        ])
      ],
      into: url)

    let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
    XCTAssertTrue(
      (page.string ?? "").contains("máscaras"),
      "el texto reconocido no quedó legible en el documento")
    XCTAssertEqual(page.rotation, 90, "la página quedó girada de otra forma")
    XCTAssertEqual(page.bounds(for: .cropBox), crop, "cambió el área visible de la página")

    // AC3: the layer is invisible, so the page renders exactly as it did.
    let after = try centerColor(of: page)
    XCTAssertEqual(after.redComponent, appearance.redComponent, accuracy: 0.02)
    XCTAssertEqual(after.greenComponent, appearance.greenComponent, accuracy: 0.02)
    XCTAssertEqual(after.blueComponent, appearance.blueComponent, accuracy: 0.02)
  }

  /// Story 6.18: the same write, to a document that lives on another volume.
  ///
  /// Every other test here writes to a document under `FileManager.temporaryDirectory`, which is on
  /// the boot volume — the same volume `embed` used to stage its replacement on, so the last step
  /// was a rename inside one filesystem and always worked. The reader's documents are not there:
  /// this project keeps books and models on an external disk on purpose, and that is where keeping
  /// the recognised text failed, with the interface saying only that it could not be kept.
  ///
  /// Gated on a directory the caller says is on another volume; skipped, not failed, when there
  /// is none, and skipped as meaningless if it turns out to be the same volume after all.
  @MainActor
  func testKeepsTheRecognisedTextInADocumentOnAnotherVolume() throws {
    guard let root = gateEnvironment("LECTURA_EXTERNAL_VOLUME_DIR") else {
      throw XCTSkip("sin LECTURA_EXTERNAL_VOLUME_DIR")
    }
    let directory = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("ocr-embed-6.18-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func volume(_ url: URL) -> (any NSObjectProtocol)? {
      (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        as? any NSObjectProtocol
    }
    let staging = try XCTUnwrap(volume(FileManager.default.temporaryDirectory))
    let target = try XCTUnwrap(volume(directory))
    try XCTSkipIf(
      staging.isEqual(target),
      "LECTURA_EXTERNAL_VOLUME_DIR está en el mismo volumen que el temporal: no prueba nada")

    let source = try makePDF(pageCount: 1, rotation: 0)
    defer { try? FileManager.default.removeItem(at: source) }
    let url = directory.appendingPathComponent("libro.pdf")
    try FileManager.default.copyItem(at: source, to: url)

    let box = CGRect(x: 40, y: 300, width: 220, height: 18)
    try OCRTextLayer.embed([0: recognisedPage(["La experiencia vivida del negro": box])], into: url)

    let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
    XCTAssertTrue(
      (page.string ?? "").contains("experiencia vivida"),
      "el texto reconocido no quedó en un documento de otro volumen")
  }

  /// AC5 and AC6: reopening finds the kept text on the ordinary text-layer route, positioned where
  /// the words are, so nothing is recognised a second time.
  @MainActor
  func testReopeningReadsKeptTextAsAnOrdinaryTextLayer() async throws {
    let url = try makePDF(pageCount: 1, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let box = CGRect(x: 40, y: 300, width: 220, height: 18)
    try OCRTextLayer.embed([0: recognisedPage(["La experiencia vivida del negro": box])], into: url)

    let extracted = await DocumentServices.extractDigitalPage(at: url, pageIndex: 0)

    XCTAssertEqual(extracted.status, "completed")
    XCTAssertNil(extracted.errorCode)
    let text = extracted.blocks.map(\.text).joined(separator: " ")
    XCTAssertTrue(text.contains("experiencia vivida"), "texto recuperado: «\(text)»")
    let rect = try XCTUnwrap(extracted.blocks.first?.region.rectPDFPoints)
    XCTAssertEqual(
      rect[0], box.minX, accuracy: 6, "el marcador de lectura caería fuera del renglón")
    XCTAssertEqual(rect[1], box.minY, accuracy: 6)
    XCTAssertEqual(rect[2], box.width, accuracy: 12)
  }

  /// The same, on a page the document itself tags as turned.
  ///
  /// A page's content stream is written in page space, which ignores `/Rotate`; on a quarter-turned
  /// page a line of type is a **tall, narrow** rectangle. Laying the kept words across it squeezed
  /// a whole sentence into the width of a word and left it crossing the visible text at a right
  /// angle — so reopening the document read back a line that no longer sat on the words, and the
  /// reading marker and "read from here" both followed it there.
  @MainActor
  func testKeptTextFollowsTheAxisOfAPageTheDocumentSaysIsTurned() async throws {
    for rotation in [90, 270] {
      let url = try makePDF(pageCount: 1, rotation: rotation)
      defer { try? FileManager.default.removeItem(at: url) }
      // Page space: the line runs *up* the page, because the viewer turns the page a quarter.
      let box = CGRect(x: 120, y: 90, width: 18, height: 220)
      try OCRTextLayer.embed(
        [0: recognisedPage(["La experiencia vivida del negro": box], rotation: rotation)],
        into: url)

      let extracted = await DocumentServices.extractDigitalPage(at: url, pageIndex: 0)

      XCTAssertEqual(extracted.status, "completed", "rotation \(rotation)")
      let text = extracted.blocks.map(\.text).joined(separator: " ")
      XCTAssertTrue(
        text.contains("experiencia vivida"), "rotation \(rotation), recovered: «\(text)»")
      let rect = try XCTUnwrap(extracted.blocks.first?.region.rectPDFPoints)
      XCTAssertEqual(rect[0], box.minX, accuracy: 8, "rotation \(rotation): x")
      XCTAssertEqual(rect[1], box.minY, accuracy: 8, "rotation \(rotation): y")
      // The decisive one: the kept line has to run along the same axis as the page's type. Laid
      // out across the box instead, this comes back wider than it is tall.
      XCTAssertGreaterThan(
        rect[3], rect[2],
        "rotation \(rotation): the kept line lies across the page instead of along it")
      XCTAssertEqual(rect[3], box.height, accuracy: 14, "rotation \(rotation): length")
    }
  }

  /// And on a page the reader turned by hand, which the file knows nothing about.
  ///
  /// `rotateCurrentPage` deliberately never touches the document: the orientation lives in
  /// `pageRotationOverrides` and is applied to the private copy every extraction opens, so the
  /// recognised rectangles come back measured against a turned page while the file on disk still
  /// reads `/Rotate 0`. `embed` reopens that file, so taking the axis from the page it finds there
  /// laid the kept line **across** the ink instead of along it — invisibly, permanently, and on
  /// exactly the pages the manual control was built for.
  ///
  /// The control is the first case below: the same words and the same rectangles, with the turn
  /// declared by the file instead of chosen by the reader. Only who declares the turn changes, so
  /// the two have to write the same line.
  @MainActor
  func testKeptTextFollowsTheTurnTheReaderChoseWhenTheFileDeclaresNone() async throws {
    // Page space: a page printed sideways has its lines running *up* it, whatever `/Rotate` says.
    let box = CGRect(x: 120, y: 90, width: 18, height: 220)
    let sentence = "La experiencia vivida del negro"

    func keptLine(fileRotation: Int, measuredAt: Int) async throws -> [Double] {
      let url = try makePDF(pageCount: 1, rotation: fileRotation)
      defer { try? FileManager.default.removeItem(at: url) }
      try OCRTextLayer.embed(
        [0: recognisedPage([sentence: box], rotation: measuredAt)], into: url)
      let extracted = await DocumentServices.extractDigitalPage(at: url, pageIndex: 0)
      XCTAssertEqual(extracted.status, "completed", "archivo \(fileRotation)°")
      XCTAssertTrue(
        extracted.blocks.map(\.text).joined(separator: " ").contains("experiencia vivida"),
        "la capa no llegó a escribirse (archivo \(fileRotation)°, medida \(measuredAt)°)")
      return try XCTUnwrap(extracted.blocks.first?.region.rectPDFPoints)
    }

    let control = try await keptLine(fileRotation: 90, measuredAt: 90)
    let chosen = try await keptLine(fileRotation: 0, measuredAt: 90)

    // Nothing about the drawing differs between the two, so neither may the geometry PDFKit reads
    // back: the rectangle is what the reading marker and "read from here" follow.
    for axis in 0..<4 {
      XCTAssertEqual(
        chosen[axis], control[axis], accuracy: 0.5,
        "la capa incrustada no coincide con el control: \(chosen) frente a \(control)")
    }
    XCTAssertEqual(chosen[3], box.height, accuracy: 14, "la línea guardada no cubre el renglón")
  }

  /// The same defect through the whole chain the reader walks, with Vision doing the reading.
  ///
  /// An image-only page printed sideways whose file claims `/Rotate 0` — `Spivak1999` is 35 of
  /// them — turned by hand, recognised, and kept. Both halves of the comparison hand Vision exactly
  /// the same pixels (the page turned a quarter), so the recognised rectangles are the same and the
  /// only thing under test is what `embed` does with them.
  @MainActor
  func testKeptTextOfAnImagePageTheReaderTurnedLandsWhereTheControlPutsIt() async throws {
    let sideways = try makeSidewaysImagePDF()
    defer { try? FileManager.default.removeItem(at: sideways) }

    /// `fileRotation` is what the document declares; `chosen` is what the reader asked for.
    func keptBand(fileRotation: Int, chosen: Int?) async throws -> CGRect {
      let url = try workingCopy(of: sideways)
      defer { try? FileManager.default.removeItem(at: url) }
      if fileRotation != 0 {
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 0)?.rotation = fileRotation
        XCTAssertTrue(document.write(to: url))
      }
      let recognised = await DocumentServices.extractOCRPage(
        at: url, pageIndex: 0, language: "es", rotation: chosen)
      XCTAssertEqual(recognised.status, "completed", "archivo \(fileRotation)°")
      XCTAssertFalse(
        recognised.blocks.isEmpty, "Vision no leyó nada en la página de lado (\(fileRotation)°)")
      // The orientation the rectangles were measured against travels with them.
      XCTAssertEqual(
        Set(recognised.blocks.map(\.region.pageRotationDegrees)), [90],
        "la extracción no registró la orientación con la que midió")
      let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
      XCTAssertTrue(
        OCRTextLayer.canEmbed(recognised, into: page),
        "esta página debería poder conservar su texto")

      try OCRTextLayer.embed([0: recognised], into: url)
      let read = await DocumentServices.extractDigitalPage(at: url, pageIndex: 0)
      XCTAssertFalse(read.blocks.isEmpty, "la capa no llegó a escribirse (\(fileRotation)°)")
      return read.blocks.map { block -> CGRect in
        let points = block.region.rectPDFPoints
        return CGRect(x: points[0], y: points[1], width: points[2], height: points[3])
      }.reduce(CGRect.null) { $0.union($1) }
    }

    let control = try await keptBand(fileRotation: 90, chosen: nil)
    let chosen = try await keptBand(fileRotation: 0, chosen: 90)

    XCTAssertEqual(chosen.minX, control.minX, accuracy: 1, "\(chosen) frente a \(control)")
    XCTAssertEqual(chosen.minY, control.minY, accuracy: 1, "\(chosen) frente a \(control)")
    XCTAssertEqual(chosen.width, control.width, accuracy: 1, "\(chosen) frente a \(control)")
    XCTAssertEqual(chosen.height, control.height, accuracy: 1, "\(chosen) frente a \(control)")
  }

  /// Story 6.15, QA of 2026-08-21: the recognition of the page the reader was *looking at* was
  /// never kept, and a page turned by hand kept the recognition from **before** the turn.
  ///
  /// Both had one cause. Whether to keep a recognition was decided by asking `PDFPage.string` of
  /// the copy on screen, and PDFKit runs its own recognition over image-only pages it displays:
  /// from then on that page answers with words that are nowhere in the file, `route` reads them as
  /// a text layer the recognised words would interleave with, and the answer is "no". Measured with
  /// a bare `PDFView` and no app around it, on a three-page image-only document: all three pages
  /// answer `nil` before, and seconds after the document is laid out page 0 answers with 1,216
  /// characters and page 1 — merely the neighbour PDFKit renders ahead — with 3,183. The first
  /// pass only ever succeeded on pages the reader had not reached; a re-read, which by definition
  /// happens on the page in front of the reader, never did.
  ///
  /// So the question goes to the file, which is what `embed` will ask when the reader accepts. What
  /// this pins down is that the answer tracks the file and nothing else: yes while the page carries
  /// no text of its own, no once the layer is in it.
  ///
  /// (The lie itself is not asserted here: reproducing it needs a `PDFView` laid out inside a live
  /// app, and this bundle has no `NSApplication` — a window put here crashed the run and laying out
  /// without one hung it. The trap is recorded in `lecciones-operativas.md` §3.7, and the app was
  /// driven by hand to verify the fix.)
  @MainActor
  func testWhetherARecognitionIsKeptIsDecidedByTheFile() async throws {
    let url = try makeSidewaysImagePDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let recognised = await DocumentServices.extractOCRPage(
      at: url, pageIndex: 0, language: "es", rotation: nil)
    XCTAssertFalse(recognised.blocks.isEmpty, "Vision no leyó nada en la página de imagen")
    // Sin letras, que es la premisa: una página de sólo imagen puede devolver `nil` o —como este
    // fixture— un único espacio, y lo que `route` mira son las letras.
    let ownText = PDFDocument(url: url)?.page(at: 0)?.string ?? ""
    XCTAssertEqual(
      ownText.filter(\.isLetter).count, 0,
      "la página de imagen no trae texto propio, que es la premisa de esta prueba")

    XCTAssertTrue(
      OCRTextLayer.canEmbed(recognised, atPageIndex: 0, of: url),
      "una página sin texto propio sí puede conservar el reconocido")
    let grant = ReadAccessGrant(url: url)
    let offered = await grant.canKeepRecognisedText(recognised, pageIndex: 0)
    XCTAssertTrue(offered, "la aplicación tiene que ofrecer conservar esta página")
    let missing = await grant.canKeepRecognisedText(recognised, pageIndex: 7)
    XCTAssertFalse(missing, "una página que no existe no puede conservar nada")

    try OCRTextLayer.embed([0: recognised], into: url)
    let again = await grant.canKeepRecognisedText(recognised, pageIndex: 0)
    XCTAssertFalse(
      again, "la respuesta tiene que seguir al archivo: la capa ya está escrita en él")
  }

  /// AC1 and AC4: a page that already reads well keeps its own text — adding a second layer would
  /// interleave the two — and a request that lands on no page at all leaves the file untouched.
  @MainActor
  func testDocumentWithItsOwnTextLayerIsLeftByteForByteUntouched() throws {
    let url = try makeTextPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)
    let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
    let recognised = recognisedPage(["Primera línea": CGRect(x: 30, y: 400, width: 120, height: 16)]
    )

    XCTAssertFalse(OCRTextLayer.canEmbed(recognised, into: page))
    XCTAssertThrowsError(try OCRTextLayer.embed([0: recognised], into: url)) { error in
      XCTAssertEqual(error as? OCRTextLayerError, .nothingToEmbed)
    }
    XCTAssertEqual(try digest(url), before, "el documento del lector se modificó sin necesidad")
  }

  /// AC7 and AC4: cancelling mid-way is the same guarantee as failing mid-way — the reader's file
  /// is only ever replaced once the whole new document exists.
  @MainActor
  func testCancellingLeavesTheOriginalExactlyAsItWas() async throws {
    let url = try makePDF(pageCount: 3, rotation: 0)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try digest(url)
    let pages = (0..<3).reduce(into: [UInt32: DigitalPageResult]()) { pages, index in
      pages[UInt32(index)] = recognisedPage(
        ["Página \(index) con texto reconocido": CGRect(x: 40, y: 300, width: 200, height: 18)],
        pageIndex: index)
    }

    let task = Task.detached { try OCRTextLayer.embed(pages, into: url) }
    task.cancel()
    let result = await task.result

    if case .success = result { XCTFail("la cancelación no interrumpió la escritura") }
    XCTAssertEqual(try digest(url), before, "quedó un documento a medio escribir")
  }

  /// AC8: the kept layer must not reach the navigator's prescan. Its type size comes from the box
  /// Vision drew, not from the page's typography, so letting it vote would invent titles and would
  /// move the body-size median that decides what is a title on the pages that do have real type.
  @MainActor
  func testKeptTextDoesNotFeedTheHeadingPrescan() throws {
    let url = try makeTextPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))
    let expected = DocumentServices.prescanHeadings(from: document)

    // The second page of this fixture carries no text of its own, so it can take the layer.
    try OCRTextLayer.embed(
      [
        1: recognisedPage(
          [
            "Un renglón que parecería un título por su caja": CGRect(
              x: 20, y: 420, width: 280, height: 44)
          ], pageIndex: 1)
      ], into: url)

    let reopened = try XCTUnwrap(PDFDocument(url: url))
    XCTAssertTrue(
      (reopened.page(at: 1)?.string ?? "").contains("parecería"), "la capa no llegó a escribirse")
    XCTAssertEqual(
      DocumentServices.prescanHeadings(from: reopened).map(\.title), expected.map(\.title),
      "el índice de navegación cambió al guardar el texto reconocido")
  }

  private func recognisedPage(
    _ lines: KeyValuePairs<String, CGRect>, pageIndex: Int = 0, rotation: Int = 0
  ) -> DigitalPageResult {
    DigitalPageResult(
      pageIndex: UInt32(pageIndex),
      status: "completed",
      blocks: lines.enumerated().map { index, line in
        DigitalTextBlock(
          blockID: "page-\(pageIndex)-ocr-\(index)",
          text: line.key,
          region: DigitalSourceRegion(
            pageIndex: UInt32(pageIndex),
            rectPDFPoints: [
              line.value.minX, line.value.minY, line.value.width, line.value.height,
            ],
            pageRotationDegrees: rotation,
            sourceToPageTransform: [1, 0, 0, 1, 0, 0],
            confidence: 0.9),
          confidence: 0.9)
      },
      errorCode: nil)
  }
}

/// Keeping the recognised text on pages whose own text layer cannot spell (Story 6.9). These run
/// against the reader's real books: the behaviour under test is what scanning software does to a
/// page, which no synthetic fixture reproduces. Every one of them works on a throwaway copy — the
/// originals are never given to a method that writes.
extension DocumentServicesTests {
  private var scannedBook: URL? {
    gateEnvironment("LECTURA_SCANNED_BOOK_PDF").map { URL(fileURLWithPath: $0) }
  }

  private var imageOnlyBook: URL? {
    gateEnvironment("LECTURA_IMAGE_ONLY_PDF").map { URL(fileURLWithPath: $0) }
  }

  private func workingCopy(of source: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    try FileManager.default.copyItem(at: source, to: url)
    return url
  }

  /// AC1, AC2, AC3, AC5 and AC8: the page keeps its ink, loses its unreadable text, gains the
  /// recognised one, and the file stays the size a book of vectors is.
  @MainActor
  func testBrokenTextLayerIsReplacedWithoutChangingThePageOrInflatingTheFile() async throws {
    guard let source = scannedBook else {
      throw XCTSkip("LECTURA_SCANNED_BOOK_PDF no configurada")
    }
    let copy = try workingCopy(of: source)
    defer { try? FileManager.default.removeItem(at: copy) }
    let indexes = [40, 41, 60, 100, 150, 200]
    let working = try XCTUnwrap(PDFDocument(url: copy))
    var recognised: [UInt32: DigitalPageResult] = [:]
    for index in indexes {
      recognised[UInt32(index)] =
        DocumentServices.extractOCRPages(
          from: working, pageIndexes: [index], language: "es"
        ).first
    }

    // AC1: this is the route the story adds, not the one Story 6.6 already had.
    for index in indexes {
      let page = try XCTUnwrap(working.page(at: index))
      let result = try XCTUnwrap(recognised[UInt32(index)])
      XCTAssertEqual(
        OCRTextLayer.route(for: result, page: page), .replacingBrokenText,
        "la página \(index) de este libro debe entrar por el camino nuevo")
    }

    let before = try Data(contentsOf: copy).count
    try OCRTextLayer.embed(recognised, into: copy)
    let after = try Data(contentsOf: copy).count

    // AC1 and AC8: vectors, not a photograph. Rasterising this book multiplied it by 29 to 56.
    XCTAssertLessThan(
      after, before * 2, "el archivo creció más de lo que un redibujado vectorial puede justificar")

    let reference = try XCTUnwrap(PDFDocument(url: source))
    let reopened = try XCTUnwrap(PDFDocument(url: copy))
    for index in indexes {
      let original = try XCTUnwrap(reference.page(at: index))
      let page = try XCTUnwrap(reopened.page(at: index))
      // AC3.
      XCTAssertTrue(
        OCRTextLayer.matchesVisually(original, page), "la página \(index) cambió de aspecto")
      XCTAssertEqual(page.rotation, original.rotation, "la página \(index) quedó girada")
      XCTAssertEqual(
        page.bounds(for: .cropBox), original.bounds(for: .cropBox),
        "cambió el área visible de la página \(index)")

      // AC5: nothing of the old layer survives to interleave with the new one. Glyphs drawn by id
      // come back as private-use characters until the document is written; after it, as nothing.
      let text = page.string ?? ""
      XCTAssertFalse(
        text.unicodeScalars.contains { $0.properties.generalCategory == .privateUse },
        "quedaron glifos sin texto en la página \(index)")
      XCTAssertTrue(
        text.contains { $0.isLetter && !$0.isASCII },
        "el texto guardado en la página \(index) sigue sin acentos: «\(text.prefix(80))»")
    }

    // AC5 again, through the route the reading itself uses.
    let extracted = await DocumentServices.extractDigitalPage(at: copy, pageIndex: 41)
    XCTAssertEqual(extracted.status, "completed")
    let read = extracted.blocks.map(\.text).joined(separator: " ")
    XCTAssertTrue(read.contains("quiere el hombre"), "texto recuperado: «\(read.prefix(120))»")
    XCTAssertTrue(read.contains("é") || read.contains("ó"), "la lectura perdió los acentos")

    // AC9: the navigator reads titles off type size, which a redrawn page no longer has. The
    // chapters have to survive the change.
    let outline = DocumentServices.outlineOutline(from: reopened)
    XCTAssertGreaterThanOrEqual(
      outline.filter { $0.level == 0 }.count, 10,
      "el índice de capítulos se perdió al guardar el texto reconocido")
  }

  /// AC6: a page with no text layer at all keeps the Story 6.6 route exactly — its own drawing is
  /// not interpreted, and the result is what it was before this story existed.
  @MainActor
  func testPagesWithNoTextLayerKeepTheRouteAndResultOfStory66() throws {
    guard let source = imageOnlyBook else {
      throw XCTSkip("LECTURA_IMAGE_ONLY_PDF no configurada")
    }
    let copy = try workingCopy(of: source)
    defer { try? FileManager.default.removeItem(at: copy) }
    let working = try XCTUnwrap(PDFDocument(url: copy))
    var recognised: [UInt32: DigitalPageResult] = [:]
    var indexes: [Int] = []
    for index in 0..<min(4, working.pageCount) {
      guard
        let result = DocumentServices.extractOCRPages(
          from: working, pageIndexes: [index], language: "es"
        ).first,
        // A blank verso recognises as nothing and takes no layer at all, by either route.
        result.blocks.contains(where: { $0.text.contains(where: \.isLetter) })
      else { continue }
      recognised[UInt32(index)] = result
      indexes.append(index)
    }
    XCTAssertGreaterThanOrEqual(indexes.count, 2, "el fixture no dio páginas con texto reconocible")

    for index in indexes {
      let page = try XCTUnwrap(working.page(at: index))
      let result = try XCTUnwrap(recognised[UInt32(index)])
      XCTAssertEqual(
        OCRTextLayer.route(for: result, page: page), .overOwnDrawing,
        "la página \(index) no tiene capa de texto: debe seguir el camino de la Story 6.6")
    }

    let before = try Data(contentsOf: copy).count
    try OCRTextLayer.embed(recognised, into: copy)
    let after = try Data(contentsOf: copy).count
    XCTAssertLessThan(after, before * 2)

    let reference = try XCTUnwrap(PDFDocument(url: source))
    let reopened = try XCTUnwrap(PDFDocument(url: copy))
    for index in indexes {
      let original = try XCTUnwrap(reference.page(at: index))
      let page = try XCTUnwrap(reopened.page(at: index))
      XCTAssertTrue(OCRTextLayer.matchesVisually(original, page), "cambió la página \(index)")
      XCTAssertTrue(
        (page.string ?? "").contains(where: \.isLetter), "la página \(index) no guardó el texto")
    }
    // Story 6.6 leaves these pages without an outline of their own; nothing here should invent one.
    XCTAssertTrue(DocumentServices.outlineOutline(from: reopened).isEmpty)
  }

  /// AC4: a page drawn with something this story does not reproduce is refused, not guessed at —
  /// while the pages it was written for are reproduced.
  @MainActor
  func testPageDrawnWithSomethingUnsupportedIsRefusedRatherThanApproximated() throws {
    let shaded = try makeReplayFixture(withGradient: true)
    defer { try? FileManager.default.removeItem(at: shaded) }
    XCTAssertNotNil(
      try replayRefusal(of: shaded), "una página con un degradado debe quedarse como está")

    guard let source = scannedBook else {
      throw XCTSkip("LECTURA_SCANNED_BOOK_PDF no configurada")
    }
    XCTAssertNil(
      try replayRefusal(of: source, page: 42),
      "la página del libro de referencia sí tiene que poder redibujarse")
  }

  /// AC1: what tells a layer that cannot spell from one that simply reads well.
  @MainActor
  func testOnlyALayerThatCannotSpellCountsAsBroken() {
    // Copied from the reference book, where the layer holds as many letters as the recognition
    // finds and not one of them accented.
    let broken =
      "Introducci6n. Yo hablo de millones de hombres a quienes sabiamente se les ha "
      + "inculcado el miedo, el complejo de inferioridad, el temblor, la genuflexion, la "
      + "desesperacion, el servilismo. Disculpe, seiior, podria indicarme el vagon restaurante, "
      + "por favor? Ella no sabia lo que habia vuelto loca a esa mujer, y se nego a responder."
    let recognised =
      "Introducción. Yo hablo de millones de hombres a quienes sabiamente se les ha "
      + "inculcado el miedo, el complejo de inferioridad, el temblor, la genuflexión, la "
      + "desesperación, el servilismo. ¿Disculpe, señor, podría indicarme el vagón restaurante, "
      + "por favor? Ella no sabía lo que había vuelto loca a esa mujer, y se negó a responder."
    XCTAssertTrue(OCRTextLayer.isBrokenTextLayer(broken, against: recognised))

    // A layer that spells as well as the recognition does is left alone.
    XCTAssertFalse(OCRTextLayer.isBrokenTextLayer(recognised, against: recognised))

    // And a recognition that is not reading this page cannot be written over it.
    XCTAssertFalse(
      OCRTextLayer.isBrokenTextLayer(
        broken,
        against: "otra página distinta con sus propias palabras acentuadas: canción, además, "
          + "también, jamás, según, corazón, avión, reunión"))
  }

  /// AC3 and AC4 over whatever real documents the reader points at: every page of every book is
  /// either refused outright or comes back looking exactly like itself. A page reproduced *and*
  /// changed is the one outcome this story must never have, and the only way to know it does not
  /// happen is to try it on books nobody wrote a fixture for.
  ///
  /// No recognition runs here, so the sweep costs seconds per book instead of minutes, and nothing
  /// is written: the pages are drawn into memory and compared.
  @MainActor
  func testEveryPageOfTheCorpusIsEitherRefusedOrReproducedExactly() throws {
    guard let root = corpusRoot else { throw XCTSkip("LECTURA_PDF_CORPUS no configurada") }
    let pdfs = try FileManager.default
      .subpathsOfDirectory(atPath: root.path)
      .filter { $0.hasSuffix(".pdf") }
      .sorted()
      .prefix(15)
    try XCTSkipIf(pdfs.isEmpty, "corpus vacío")

    var checked = 0
    for relative in pdfs {
      let url = root.appendingPathComponent(relative)
      guard let pdf = PDFDocument(url: url), let cg = CGPDFDocument(url as CFURL) else { continue }
      checked += 1
      let cache = PDFGlyphReplay.FontCache()
      for index in 0..<pdf.pageCount {
        guard let original = pdf.page(at: index), let cgPage = cg.page(at: index + 1) else {
          continue
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { continue }
        var box = original.bounds(for: .mediaBox)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { continue }
        context.beginPDFPage(nil)
        context.saveGState()
        let outcome = PDFGlyphReplay.replay(page: cgPage, into: context, fonts: cache)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        guard outcome.succeeded, let copy = PDFDocument(data: data as Data)?.page(at: 0) else {
          continue
        }
        copy.rotation = original.rotation
        copy.setBounds(original.bounds(for: .cropBox), for: .cropBox)
        XCTAssertTrue(
          OCRTextLayer.matchesVisually(original, copy),
          "\(relative) página \(index): se redibujó y cambió de aspecto")
      }
    }
    XCTAssertGreaterThan(checked, 0, "no se pudo abrir ningún documento del corpus")
  }

  private func replayRefusal(of url: URL, page number: Int = 1) throws -> String? {
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
    let page = try XCTUnwrap(document.page(at: number))
    var box = page.getBoxRect(.mediaBox)
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let outcome = PDFGlyphReplay.replay(
      page: page, into: context, fonts: PDFGlyphReplay.FontCache())
    context.endPDFPage()
    context.closePDF()
    return outcome.refusal
  }

  private func makeReplayFixture(withGradient: Bool) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 480)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.setLineWidth(0.6)
    context.move(to: CGPoint(x: 40, y: 200))
    context.addLine(to: CGPoint(x: 120, y: 200))
    context.strokePath()
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "Página redibujable", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
    context.textPosition = CGPoint(x: 30, y: 400)
    CTLineDraw(line, context)
    if withGradient {
      let space = CGColorSpaceCreateDeviceRGB()
      let gradient = try XCTUnwrap(
        CGGradient(
          colorsSpace: space,
          colors: [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(gray: 1, alpha: 1)]
            as CFArray, locations: [0, 1]))
      context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 320, y: 480), options: [])
    }
    context.endPDFPage()
    context.closePDF()
    return url
  }
}

/// Identification of the language a document is written in (Story 6.11).
///
/// The prose below is written for these tests rather than taken from the corpus on purpose: the
/// corpus fixtures carry between 13 and 47 letters each — «LECTURA EN ESPANOL 1», and the Spanish
/// and English multi-column ones both end in the English words «COLUMN TWO» — far less than any
/// recogniser can decide a language from. Those fixtures are still exercised here, as the documents
/// that must fall back rather than guess.
final class DocumentLanguageTests: XCTestCase {
  private static let spanish = """
    La lectura en voz alta cambia el ritmo de un libro. Quien escucha no puede volver atrás con la
    mirada, así que cada frase tiene que sostenerse sola, y el que narra aprende muy pronto a
    respetar las pausas que el autor dejó escritas. En los primeros años esa costumbre se practicaba
    en la cocina de la casa, mientras alguien preparaba la cena y los demás escuchaban sin mirar el
    libro. Nadie llamaba a eso una técnica, pero lo era: se elegía el pasaje, se medía la voz y se
    dejaba que la historia ocupara la habitación entera hasta que la última página quedaba dicha.
    """
  private static let english = """
    Reading aloud changes the pace of a book. The listener cannot glance backwards over a sentence,
    so every line has to stand on its own, and whoever narrates learns quickly to respect the pauses
    the author wrote down. For years that habit was practised in the kitchen, while somebody made
    dinner and the rest of the household listened without looking at the page. Nobody called it a
    technique, but a technique is what it was: the passage was chosen, the voice was measured, and
    the story was allowed to fill the whole room until the last page had been spoken.
    """
  private static let portuguese = """
    A leitura em voz alta muda o ritmo de um livro. Quem escuta não pode voltar atrás com o olhar,
    de modo que cada frase precisa sustentar-se sozinha, e quem narra aprende muito cedo a respeitar
    as pausas que o autor deixou escritas. Durante anos esse hábito foi praticado na cozinha da
    casa, enquanto alguém preparava o jantar e os outros escutavam sem olhar para a página. Ninguém
    chamava aquilo de técnica, mas era: escolhia-se o trecho, media-se a voz e deixava-se que a
    história ocupasse o quarto inteiro até a última página ficar dita.
    """
  private static let french = """
    La lecture à voix haute change le rythme d'un livre. Celui qui écoute ne peut pas revenir en
    arrière du regard, si bien que chaque phrase doit tenir toute seule, et celui qui raconte
    apprend très vite à respecter les pauses que l'auteur a laissées par écrit. Pendant des années
    cette habitude se pratiquait dans la cuisine, pendant que quelqu'un préparait le dîner et que
    les autres écoutaient sans regarder la page. Personne n'appelait cela une technique, mais
    c'en était une, jusqu'à ce que la dernière page soit dite à voix haute devant tout le monde.
    """

  /// AC1, AC6: each language is recognised as itself, and the confidence is recorded rather than
  /// merely asserted — a verdict that only just cleared the bar is worth knowing about.
  @MainActor
  func testIdentifiesEachSupportedLanguageOfRealProse() throws {
    for (expected, prose) in [
      ("es", Self.spanish), ("en", Self.english), ("pt", Self.portuguese),
    ] {
      let identified = try XCTUnwrap(
        DocumentLanguage.identify(in: prose), "\(expected): no identificó ningún idioma")
      XCTAssertEqual(identified.language, expected)
      XCTAssertGreaterThanOrEqual(identified.confidence, DocumentLanguage.minimumConfidence)
      XCTContext.runActivity(named: "\(expected) → \(identified.language)") { activity in
        activity.add(
          XCTAttachment(
            string: """
              confianza=\(identified.confidence) letras=\(prose.filter(\.isLetter).count)
              """))
      }
    }
  }

  /// AC3: a language the app has no voice and no engine support for is not an answer. Falling back
  /// is what keeps `normalize_page` from being handed a payload it rejects outright.
  func testFallsBackWhenTheLanguageIsNotOneTheAppSupports() {
    XCTAssertNil(DocumentLanguage.identify(in: Self.french))
  }

  /// AC3: a cover with a title and an author cannot decide a language, and the recogniser will
  /// answer anyway if it is asked. Below the letter floor the document is treated as silent.
  func testFallsBackWhenThereIsTooLittleTextToDecide() {
    XCTAssertNil(DocumentLanguage.identify(in: "Piel negra, máscaras blancas\nFrantz Fanon\n1952"))
    XCTAssertNil(DocumentLanguage.identify(in: ""))
    XCTAssertNil(DocumentLanguage.identify(in: String(repeating: "1234 ", count: 500)))
  }

  /// AC5: a Spanish book that quotes a long English passage is still a Spanish book. Every window
  /// of the sample votes, so a minority passage is outvoted rather than obeyed — and, unlike
  /// before Story 6.16, it is actually read: the quotation used to be ignored only because nothing
  /// past the first hundred characters was ever looked at.
  func testALongQuotationInAnotherLanguageDoesNotChangeTheAnswer() throws {
    let mixed = Self.spanish + "\n" + Self.english.prefix(300)
    let identified = try XCTUnwrap(DocumentLanguage.identify(in: mixed))
    XCTAssertEqual(identified.language, "es")
    XCTAssertLessThan(identified.confidence, 1, "la cita inglesa debería haber votado")
  }

  /// Story 6.16, the measurement the whole design rests on: `NLLanguageRecognizer` reads about the
  /// first hundred characters of a passage and nothing after them. Ninety-six characters of Spanish
  /// in front of 34.800 characters of English come back Spanish, flatly, if the question is asked
  /// once — which is why `identify` asks it once per window instead.
  ///
  /// If this test ever fails because the recogniser grew a longer memory, that is good news, not a
  /// regression: the windowing becomes unnecessary rather than wrong.
  func testTheRecogniserOnlyReadsTheHeadOfASinglePassage() throws {
    let english = String(
      repeating: "The house was quiet and the world was calm tonight here now. ", count: 600)
    let spanishHead = String(Self.spanish.prefix(96))

    let askedOnce = NLLanguageRecognizer()
    askedOnce.processString(spanishHead + english)
    XCTAssertEqual(
      askedOnce.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value })?.key.rawValue,
      NLLanguage.spanish.rawValue,
      "el reconocedor ya lee más de cien caracteres: la ventana podría simplificarse")

    // The same text, asked window by window, answers what it actually is.
    let identified = try XCTUnwrap(DocumentLanguage.identify(in: spanishHead + english))
    XCTAssertEqual(identified.language, "en")
  }

  /// AC1, AC3: the case that opened this story. A book of English prose whose front matter is not
  /// English is identified by its body, because the pages read are spread from the first to the
  /// last instead of taken off the head.
  ///
  /// Modelled on `Goldberg2002`: its cover reads as Swedish (0,670), Swedish is not a language the
  /// app supports, and so 169 pages of English fell back to `es` and were routed to OCR by a
  /// Spanish rule.
  func testABookIsIdentifiedByItsBodyAndNotByItsFrontMatter() async throws {
    let frontMatter = [
      "Piel negra, máscaras blancas\nFrantz Fanon\n1952",
      "Todos los derechos reservados. Prohibida su reproducción total o parcial.",
      "Índice\nPrólogo\nCapítulo primero\nCapítulo segundo\nBibliografía",
    ]
    let body = Array(repeating: Self.english, count: 12)
    let url = try makePagesPDF(frontMatter + body)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))

    let result = await DocumentLanguage.identifyAsync(in: document)

    let identified = try XCTUnwrap(result)

    XCTAssertEqual(identified.language, "en", "el libro se identificó por sus preliminares")
  }

  /// AC1: end to end over a PDF's own text layer, which is the path the app takes when a document
  /// opens.
  func testIdentifiesTheLanguageOfADocumentsOwnTextLayer() async throws {
    for (expected, prose) in [
      ("es", Self.spanish), ("en", Self.english), ("pt", Self.portuguese),
    ] {
      let url = try makeProsePDF(prose)
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try XCTUnwrap(PDFDocument(url: url))

      let result = await DocumentLanguage.identifyAsync(in: document)

      XCTAssertEqual(try XCTUnwrap(result, expected).language, expected)
    }
  }

  /// A bounded number of pages is read — a book must not be scanned end to end to be asked what
  /// language it is in (AC5) — but they are spread from the first page to the last, not taken off
  /// the head (Story 6.16, AC3). Both halves matter, so both are asserted.
  func testReadsABoundedNumberOfPagesSpreadAcrossTheWholeDocument() throws {
    let pageCount = DocumentLanguage.sampledPages * 5
    let pages = (0..<pageCount).map { "\(Self.spanish)\nMARCA DE PAGINA \($0)" }
    let url = try makePagesPDF(pages)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))

    let sample = DocumentLanguage.sampleText(from: document)

    XCTAssertEqual(
      sample.components(separatedBy: "MARCA DE PAGINA").count - 1, DocumentLanguage.sampledPages,
      "leyó más páginas de las que muestrea")
    XCTAssertTrue(
      sample.contains("MARCA DE PAGINA \(pageCount - pageCount / DocumentLanguage.sampledPages)"),
      "no llegó al último tramo del documento: volvió a leer sólo la cabecera")
    XCTAssertFalse(
      sample.contains("MARCA DE PAGINA \(DocumentLanguage.sampledPages)"),
      "leyó las primeras páginas seguidas en vez de repartirlas")
  }

  /// The vote is capped so the work does not grow with the document, and the cap keeps the spread:
  /// windows are taken from end to end, never the first `maximumWindows` of them (AC3).
  func testTheVoteIsCappedWithoutFallingBackToTheHeadOfTheText() throws {
    let blockCount = DocumentLanguage.maximumWindows * 3
    let text = (0..<blockCount).map { index -> String in
      let marker = "MARCA\(index)FIN"
      return marker
        + String(repeating: "a", count: DocumentLanguage.windowCharacters - marker.count)
    }.joined()

    let windows = DocumentLanguage.votingWindows(in: text)

    XCTAssertEqual(windows.count, DocumentLanguage.maximumWindows)
    XCTAssertTrue(try XCTUnwrap(windows.first).contains("MARCA0FIN"))
    let lastMarker = try XCTUnwrap(
      try XCTUnwrap(windows.last).components(separatedBy: "MARCA").last?
        .components(separatedBy: "FIN").first.flatMap(Int.init))
    XCTAssertGreaterThan(
      lastMarker, blockCount * 2 / 3,
      "el tope se quedó en la cabecera del texto en vez de repartir las ventanas")
  }

  /// The corpus fixtures are far too thin to identify a language from, and this records that as a
  /// fact rather than leaving it to be rediscovered: they fall back, they do not guess (AC3).
  func testCorpusFixturesAreTooThinToDecideAndFallBack() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    for name in [
      "es-single-digital", "en-single-digital", "pt-single-digital",
      "es-multi-digital", "en-multi-digital", "pt-multi-digital",
    ] {
      let url = root.appendingPathComponent("tests/corpus/documents/\(name).pdf")
      let document = try XCTUnwrap(PDFDocument(url: url), name)
      let sample = DocumentLanguage.sampleText(from: document)
      XCTAssertLessThan(
        sample.filter(\.isLetter).count, DocumentLanguage.minimumLetters,
        "\(name) ya tiene texto suficiente: revisa esta prueba, no la del idioma")
      XCTAssertNil(DocumentLanguage.identify(in: sample), name)
    }
  }

  /// AC4: the document's language decides the voice when one is installed for it; otherwise the
  /// previous rule stands, and the reader is never left with nothing selectable.
  func testVoicePreselectionFollowsTheDocumentAndNeverLeavesTheReaderWithoutAVoice() {
    let installed = ["en", "es", "pt"]
    XCTAssertEqual(
      DocumentLanguage.preferredVoiceLanguage(
        document: "pt", available: installed, systemPreferred: ["es"]), "pt")
    // No voice for the document's language: the system's preference decides, as it did before.
    XCTAssertEqual(
      DocumentLanguage.preferredVoiceLanguage(
        document: "pt", available: ["en", "es"], systemPreferred: ["es"]), "es")
    // Neither the document nor the system offers a usable language: the first installed one.
    XCTAssertEqual(
      DocumentLanguage.preferredVoiceLanguage(
        document: "pt", available: ["en"], systemPreferred: ["fr"]), "en")
    // Unidentified document, which is the fallback case of AC3.
    XCTAssertEqual(
      DocumentLanguage.preferredVoiceLanguage(
        document: nil, available: installed, systemPreferred: ["es"]), "es")
    // Nothing installed at all: nothing to preselect, and no crash reaching for a first element.
    XCTAssertNil(
      DocumentLanguage.preferredVoiceLanguage(
        document: "es", available: [], systemPreferred: ["es"]))
  }

  private func makeProsePDF(_ prose: String, pageCount: Int = 1) throws -> URL {
    try makePagesPDF(Array(repeating: prose, count: pageCount))
  }

  /// A PDF with a page per entry, so a document can be given a front matter that does not read like
  /// its body (Story 6.16).
  private func makePagesPDF(_ pages: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    for prose in pages {
      let lines = prose.split(separator: "\n", omittingEmptySubsequences: false)
      context.beginPDFPage(nil)
      for (index, text) in lines.enumerated() {
        let line = CTLineCreateWithAttributedString(
          NSAttributedString(
            string: String(text), attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        context.textPosition = CGPoint(x: 40, y: 720 - Double(index) * 20)
        CTLineDraw(line, context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }
}
