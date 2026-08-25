import CoreGraphics
import CoreML
import XCTest

@testable import MacPlatform

final class DocumentLayoutServicesTests: XCTestCase {
  func testDecodeOrdersRolesAndNarrationPolicies() throws {
    let classLogits = try array(shape: [1, 4, 25])
    let boxes = try array(shape: [1, 4, 4])
    let orderLogits = try array(shape: [1, 4, 4])
    set(4, in: classLogits, at: [0, 0, 17])
    set(4, in: classLogits, at: [0, 1, 22])
    set(4, in: classLogits, at: [0, 2, 10])
    set(4, in: classLogits, at: [0, 3, 16])
    setBox([0.5, 0.6, 0.8, 0.3], in: boxes, query: 1)
    for query in 0..<4 {
      setBox([0.5, 0.5, 0.2, 0.2], in: boxes, query: query)
      for later in (query + 1)..<4 { set(20, in: orderLogits, at: [0, query, later]) }
    }
    setBox([0.5, 0.6, 0.8, 0.3], in: boxes, query: 1)

    let regions = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: orderLogits, pageIndex: 0,
      pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800), pageRotationDegrees: 0,
      physicalPageIndex: 0, orderOffset: 0)

    XCTAssertEqual(regions.map(\.role), [.paragraphTitle, .text, .footnote, .number])
    XCTAssertEqual(regions.map(\.order), [0, 1, 2, 3])
    XCTAssertEqual(regions.map(\.disposition), [.automatic, .automatic, .never, .never])
    XCTAssertEqual(regions[1].rectPDFPoints[0], 60, accuracy: 0.001)
    XCTAssertEqual(regions[1].rectPDFPoints[1], 200, accuracy: 0.001)
    XCTAssertEqual(regions[1].rectPDFPoints[2], 480, accuracy: 0.001)
    XCTAssertEqual(regions[1].rectPDFPoints[3], 240, accuracy: 0.001)
  }

  func testDecodeRejectsNonFiniteOutputs() throws {
    let logits = try array(shape: [1, 1, 25])
    let boxes = try array(shape: [1, 1, 4])
    let order = try array(shape: [1, 1, 1])
    set(.infinity, in: boxes, at: [0, 0, 0])

    XCTAssertEqual(
      DocumentLayoutPostprocessor.decode(
        classLogits: logits, boxes: boxes, orderLogits: order, pageIndex: 0,
        pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800), pageRotationDegrees: 0,
        physicalPageIndex: 0, orderOffset: 0), [])
  }

  func testDecodeRejectsScoresBelowThreshold() throws {
    let logits = try array(shape: [1, 1, 25])
    let boxes = try array(shape: [1, 1, 4])
    let order = try array(shape: [1, 1, 1])
    set(-1, in: logits, at: [0, 0, 22])

    XCTAssertEqual(
      DocumentLayoutPostprocessor.decode(
        classLogits: logits, boxes: boxes, orderLogits: order, pageIndex: 0,
        pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800), pageRotationDegrees: 0,
        physicalPageIndex: 0, orderOffset: 0), [])
  }

  func testDecodeMapsTopOriginBoxesIntoPDFSpace() throws {
    let classLogits = try array(shape: [1, 1, 25])
    let boxes = try array(shape: [1, 1, 4])
    let order = try array(shape: [1, 1, 1])
    set(4, in: classLogits, at: [0, 0, 22])
    setBox([0.25, 0.1, 0.2, 0.1], in: boxes, query: 0)
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 800)

    let upright = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: order, pageIndex: 0,
      pageBounds: bounds, pageRotationDegrees: 0, physicalPageIndex: 0, orderOffset: 0)
    let ninety = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: order, pageIndex: 0,
      pageBounds: bounds, pageRotationDegrees: 90, physicalPageIndex: 0, orderOffset: 0)
    let twoSeventy = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: order, pageIndex: 0,
      pageBounds: bounds, pageRotationDegrees: 270, physicalPageIndex: 0, orderOffset: 0)

    assertRect(upright[0].rectPDFPoints, equals: [100, 700, 120, 80])
    assertRect(ninety[0].rectPDFPoints, equals: [40, 140, 60, 160])
    assertRect(twoSeventy[0].rectPDFPoints, equals: [520, 540, 60, 160])
  }

  func testDecodeMapsBottomTopOriginBoxNearPDFBottom() throws {
    let classLogits = try array(shape: [1, 1, 25])
    let boxes = try array(shape: [1, 1, 4])
    let order = try array(shape: [1, 1, 1])
    set(4, in: classLogits, at: [0, 0, 22])
    setBox([0.25, 0.9, 0.2, 0.1], in: boxes, query: 0)

    let regions = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: order, pageIndex: 0,
      pageBounds: CGRect(x: 10, y: 20, width: 600, height: 800), pageRotationDegrees: 0,
      physicalPageIndex: 0, orderOffset: 0)

    assertRect(regions[0].rectPDFPoints, equals: [100, 60, 120, 80])
  }

  func testRegionOfInterestRectExpandsIntoFullImageCoordinates() {
    let observation = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)

    XCTAssertEqual(
      DocumentLayoutPostprocessor.fullImageRect(
        observation, within: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
      CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.2))
    XCTAssertEqual(
      DocumentLayoutPostprocessor.fullImageRect(
        observation, within: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
      CGRect(x: 0.6, y: 0.3, width: 0.2, height: 0.2))
  }

  func testDecodeMapsSplitRegionsIntoOppositeDisplayedHalves() throws {
    let classLogits = try array(shape: [1, 1, 25])
    let boxes = try array(shape: [1, 1, 4])
    let order = try array(shape: [1, 1, 1])
    set(4, in: classLogits, at: [0, 0, 22])
    setBox([0.5, 0.5, 0.2, 0.2], in: boxes, query: 0)
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 800)

    let left = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: order, pageIndex: 0,
      pageBounds: bounds, pageRotationDegrees: 90, physicalPageIndex: 0, orderOffset: 0,
      regionOfInterest: CGRect(x: 0, y: 0, width: 0.5, height: 1))
    let right = DocumentLayoutPostprocessor.decode(
      classLogits: classLogits, boxes: boxes, orderLogits: order, pageIndex: 0,
      pageBounds: bounds, pageRotationDegrees: 90, physicalPageIndex: 1, orderOffset: 1,
      regionOfInterest: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

    assertRect(left[0].rectPDFPoints, equals: [250, 180, 120, 80])
    assertRect(right[0].rectPDFPoints, equals: [250, 580, 120, 80])
  }

  func testWideTwoColumnPageWithoutPairedFoliosIsNotASpread() {
    XCTAssertFalse(
      DocumentLayoutPostprocessor.isPhysicalSpread(
        [
          region(.text, [80, 100, 400, 500]),
          region(.text, [720, 100, 400, 500]),
        ], pageBounds: CGRect(x: 0, y: 0, width: 1_200, height: 800)))
  }

  func testWidePageWithReadableHalvesAndOppositeFoliosIsASpread() {
    XCTAssertTrue(
      DocumentLayoutPostprocessor.isPhysicalSpread(
        [
          region(.text, [80, 100, 400, 500]),
          region(.text, [720, 100, 400, 500]),
          region(.number, [80, 30, 20, 20]),
          region(.number, [1_100, 30, 20, 20]),
        ], pageBounds: CGRect(x: 0, y: 0, width: 1_200, height: 800)))
  }

  func testQuarterTurnedWidePageWithOppositeFoliosIsASpread() {
    XCTAssertTrue(
      DocumentLayoutPostprocessor.isPhysicalSpread(
        [
          region(.text, [100, 80, 350, 250]),
          region(.text, [100, 450, 350, 250]),
          region(.number, [544, 80, 20, 20]),
          region(.number, [544, 680, 20, 20]),
        ], pageBounds: CGRect(x: 0, y: 0, width: 594, height: 780),
        pageRotationDegrees: 90))
  }

  func testConfirmedSpreadWithAnEmptyHalfDegradesWithoutRegions() {
    XCTAssertNil(
      DocumentLayoutClassifier.combinedSpreadRegions(
        left: [], right: [region(.text, [0, 0, 1, 1])]))
  }

  func testSpreadHalfBoundsFollowDisplayedLeftThenRightAtEveryQuarterTurn() throws {
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 800)
    let expected = [
      0: [
        CGRect(x: 10, y: 20, width: 300, height: 800),
        CGRect(x: 310, y: 20, width: 300, height: 800),
      ],
      90: [
        CGRect(x: 10, y: 20, width: 600, height: 400),
        CGRect(x: 10, y: 420, width: 600, height: 400),
      ],
      180: [
        CGRect(x: 310, y: 20, width: 300, height: 800),
        CGRect(x: 10, y: 20, width: 300, height: 800),
      ],
      270: [
        CGRect(x: 10, y: 420, width: 600, height: 400),
        CGRect(x: 10, y: 20, width: 600, height: 400),
      ],
    ]
    for rotation in [0, 90, 180, 270] {
      let halves = DocumentLayoutClassifier.spreadPageBounds(
        pageBounds: bounds, rotation: rotation)
      XCTAssertEqual(halves.left, expected[rotation]?[0], "left at \(rotation)°")
      XCTAssertEqual(halves.right, expected[rotation]?[1], "right at \(rotation)°")
    }

    let combined = try XCTUnwrap(
      DocumentLayoutClassifier.combinedSpreadRegions(
        left: [region(.text, [10, 20, 50, 20], physicalPageIndex: 0)],
        right: [region(.text, [10, 420, 50, 20], order: 1, physicalPageIndex: 1)]))
    XCTAssertEqual(Set(combined.map(\.physicalPageIndex)), [0, 1])
    XCTAssertEqual(combined.map(\.physicalPageIndex), [0, 1])
  }

  func testAlignmentCopiesEvidenceFromTheContainingRegion() throws {
    let source = block("covered", [10, 10, 100, 10])
    let layout = result([
      DocumentLayoutRegion(
        role: .paragraphTitle, disposition: .automatic, confidence: 0.3,
        rectPDFPoints: [0, 0, 70, 30], order: 4, physicalPageIndex: 1)
    ])

    let aligned = try XCTUnwrap(DocumentLayoutAlignment.enrich([source], with: layout).first)

    XCTAssertEqual(aligned.layoutRole, .paragraphTitle)
    XCTAssertEqual(aligned.layoutConfidence, 0.3)
    XCTAssertEqual(aligned.layoutOrder, 4)
    XCTAssertEqual(aligned.narrationDisposition, .automatic)
    XCTAssertEqual(aligned.physicalPageIndex, 1)
  }

  func testAlignmentLeavesUncoveredAndAmbiguousBlocksWithoutEvidence() throws {
    let sources = [
      block("covered-1", [0, 0, 40, 10]),
      block("covered-2", [0, 20, 40, 10]),
      block("covered-3", [0, 60, 40, 10]),
      block("uncovered", [100, 100, 40, 10]),
      block("ambiguous", [0, 40, 40, 10]),
    ]
    let layout = result([
      region(.text, [0, 0, 40, 10], order: 0),
      region(.text, [0, 20, 40, 10], order: 1),
      region(.text, [0, 60, 40, 10], order: 2),
      region(.text, [0, 40, 40, 10], order: 3),
      region(.paragraphTitle, [0, 40, 40, 10], order: 4),
    ])

    let aligned = DocumentLayoutAlignment.enrich(sources, with: layout)

    XCTAssertEqual(aligned.count, sources.count)
    XCTAssertEqual(aligned.first { $0.blockID == "covered-1" }?.layoutRole, .text)
    for id in ["uncovered", "ambiguous"] {
      let block = try XCTUnwrap(aligned.first { $0.blockID == id })
      XCTAssertNil(block.layoutRole)
      XCTAssertNil(block.layoutConfidence)
      XCTAssertNil(block.layoutOrder)
      XCTAssertNil(block.narrationDisposition)
      XCTAssertNil(block.physicalPageIndex)
    }
  }

  func testAlignmentFallsBackWhenFewerThanSixtyPercentOfBlocksAlign() {
    let sources = [
      block("covered", [0, 0, 40, 10]),
      block("uncovered-1", [100, 0, 40, 10]),
      block("uncovered-2", [100, 20, 40, 10]),
    ]

    let aligned = DocumentLayoutAlignment.enrich(
      sources, with: result([region(.text, [0, 0, 40, 10])]))

    XCTAssertEqual(aligned, sources)
    XCTAssertTrue(aligned.allSatisfy { $0.layoutRole == nil })
  }

  func testAlignmentDoesNotTurnVisibleTextIntoImageContentOrReorderIt() {
    let sources = [
      block("2021", [0, 0, 40, 10]),
      block("separator", [50, 0, 10, 10]),
      block("2030", [70, 0, 40, 10]),
    ]
    let layout = result([
      region(.image, [0, 0, 40, 10], order: 1),
      region(.image, [50, 0, 10, 10], order: 0),
      region(.text, [70, 0, 40, 10], order: 2),
    ])

    let aligned = DocumentLayoutAlignment.enrich(sources, with: layout)

    XCTAssertEqual(aligned, sources)
    XCTAssertTrue(aligned.allSatisfy { $0.layoutRole == nil })
  }

  func testSpreadAlignmentOrdersEveryLeftBlockBeforeEveryRightBlock() {
    let sources = [
      block("right-top", [700, 700, 100, 20]),
      block("left-bottom", [100, 100, 100, 20]),
      block("right-bottom", [700, 100, 100, 20]),
      block("left-top", [100, 700, 100, 20]),
    ]
    let layout = result(
      [
        region(.text, [100, 700, 100, 20], order: 0, physicalPageIndex: 0),
        region(.text, [100, 100, 100, 20], order: 1, physicalPageIndex: 0),
        region(.text, [700, 700, 100, 20], order: 2, physicalPageIndex: 1),
        region(.text, [700, 100, 100, 20], order: 3, physicalPageIndex: 1),
      ], physicalPageCount: 2)

    let aligned = DocumentLayoutAlignment.enrich(sources, with: layout)

    XCTAssertEqual(
      aligned.map(\.blockID), ["left-top", "left-bottom", "right-top", "right-bottom"])
  }

  func testPartiallyAlignedSpreadKeepsUnmatchedLeftBlocksBeforeTheRightPage() {
    let sources = [
      block("right-top", [700, 700, 100, 20]),
      block("left-unmatched-first", [100, 300, 100, 20]),
      block("right-bottom", [700, 100, 100, 20]),
      block("left-matched", [100, 700, 100, 20]),
      block("left-unmatched-second", [100, 200, 100, 20]),
    ]
    let layout = result(
      [
        region(.text, [100, 700, 100, 20], order: 0, physicalPageIndex: 0),
        region(.text, [700, 700, 100, 20], order: 1, physicalPageIndex: 1),
        region(.text, [700, 100, 100, 20], order: 2, physicalPageIndex: 1),
      ], physicalPageCount: 2)

    let aligned = DocumentLayoutAlignment.enrich(sources, with: layout)

    XCTAssertEqual(
      aligned.map(\.blockID),
      [
        "left-matched", "left-unmatched-first", "left-unmatched-second", "right-top",
        "right-bottom",
      ])
  }

  private func array(shape: [NSNumber]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape, dataType: .float32)
    for index in 0..<array.count { array[index] = -20 }
    return array
  }

  private func set(_ value: Double, in array: MLMultiArray, at index: [Int]) {
    array[index.map(NSNumber.init(value:))] = NSNumber(value: value)
  }

  private func setBox(_ values: [Double], in array: MLMultiArray, query: Int) {
    for (index, value) in values.enumerated() { set(value, in: array, at: [0, query, index]) }
  }

  private func assertRect(_ actual: [Double], equals expected: [Double]) {
    XCTAssertEqual(actual.count, expected.count)
    for (value, expectation) in zip(actual, expected) {
      XCTAssertEqual(value, expectation, accuracy: 0.001)
    }
  }

  private func block(_ id: String, _ rect: [Double]) -> DigitalTextBlock {
    DigitalTextBlock(
      blockID: id, text: id,
      region: DigitalSourceRegion(
        pageIndex: 0, rectPDFPoints: rect, pageRotationDegrees: 0,
        sourceToPageTransform: [1, 0, 0, 1, 0, 0], confidence: 1),
      confidence: 1)
  }

  private func result(
    _ regions: [DocumentLayoutRegion], physicalPageCount: UInt8 = 1
  ) -> DocumentLayoutResult {
    DocumentLayoutResult(
      regions: regions, physicalPageCount: physicalPageCount, status: "completed",
      elapsedMilliseconds: 7, processorRevision: "test")
  }

  private func region(
    _ role: LayoutRole, _ rect: [Double], order: UInt32 = 0,
    physicalPageIndex: UInt8 = 0
  ) -> DocumentLayoutRegion {
    DocumentLayoutRegion(
      role: role, disposition: .automatic, confidence: 0.9, rectPDFPoints: rect, order: order,
      physicalPageIndex: physicalPageIndex)
  }
}
