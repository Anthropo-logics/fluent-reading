import MacPlatform
import XCTest

/// Story 6.5: the arithmetic behind the tutorial callouts. AC5 — the card never leaves the window
/// and never covers the control it points at — is decided here, in window sizes a running app is
/// tedious to reproduce (a minimum-size window with system text scaled up, a control hard against
/// the right edge), so it is checked here rather than only by eye.
final class TutorialCalloutTests: XCTestCase {
  private let overlay = CGSize(width: 900, height: 600)
  private let card = CGSize(width: 360, height: 320)

  private func assertInside(
    _ placement: TutorialCalloutPlacement,
    _ size: CGSize,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let frame = placement.cardFrame
    XCTAssertGreaterThanOrEqual(frame.minX, 0, "card off the leading edge", file: file, line: line)
    XCTAssertGreaterThanOrEqual(frame.minY, 0, "card off the top edge", file: file, line: line)
    XCTAssertLessThanOrEqual(
      frame.maxX, size.width, "card off the trailing edge", file: file, line: line)
    XCTAssertLessThanOrEqual(
      frame.maxY, size.height, "card off the bottom edge", file: file, line: line)
  }

  /// A native toolbar item lives above the content area, so its rectangle converts to a negative
  /// y in overlay coordinates. The card must still land inside — pinned just under the toolbar —
  /// and its pointer must sit on the top edge, tracking the item's horizontal centre.
  func testToolbarTargetAboveTheOverlayPinsTheCardUnderIt() {
    let toolbarItem = CGRect(x: 420, y: -38, width: 120, height: 28)
    let placement = TutorialCallout.placement(
      target: toolbarItem, cardSize: card, overlaySize: overlay)

    assertInside(placement, overlay)
    XCTAssertEqual(placement.cardFrame.minY, TutorialCallout.margin, accuracy: 0.001)
    XCTAssertEqual(placement.cardFrame.midX, toolbarItem.midX, accuracy: 0.001)
    guard case .above(let tipX) = placement.tip else {
      return XCTFail("expected a pointer on the top edge, got \(placement.tip)")
    }
    XCTAssertEqual(placement.cardFrame.minX + tipX, toolbarItem.midX, accuracy: 0.001)
    XCTAssertNil(placement.highlight, "a toolbar item is outside the overlay, nothing to outline")
  }

  /// AC5: a control against the trailing edge of a window pulls the card outwards; it has to stop
  /// at the margin while the pointer keeps tracking the control.
  func testTargetAgainstTheTrailingEdgeClampsTheCardAndKeepsThePointerOnTarget() {
    let target = CGRect(x: 860, y: 40, width: 30, height: 28)
    let placement = TutorialCallout.placement(target: target, cardSize: card, overlaySize: overlay)

    assertInside(placement, overlay)
    XCTAssertEqual(
      placement.cardFrame.maxX, overlay.width - TutorialCallout.margin, accuracy: 0.001)
    guard case .above(let tipX) = placement.tip else {
      return XCTFail("expected a pointer on the top edge, got \(placement.tip)")
    }
    // The pointer keeps its distance from the corner of the card, so it stops short of the exact
    // centre here; what has to hold is that it still lands on the control.
    let pointsAt = placement.cardFrame.minX + tipX
    XCTAssertTrue(
      (target.minX...target.maxX).contains(pointsAt),
      "pointer at \(pointsAt) misses the control at \(target.minX)…\(target.maxX)")
  }

  /// AC5, the other half: the card is adjacent to the control, never on top of it.
  func testCardNeverOverlapsAControlItCanStandBeside() {
    let targets = [
      CGRect(x: 40, y: 10, width: 90, height: 28),  // top-left, card goes below
      CGRect(x: 400, y: 560, width: 90, height: 28),  // bottom, card goes above
      CGRect(x: 820, y: 300, width: 60, height: 60),  // mid-height, right edge
    ]
    for target in targets {
      let placement = TutorialCallout.placement(
        target: target, cardSize: card, overlaySize: overlay)
      assertInside(placement, overlay)
      XCTAssertFalse(
        placement.cardFrame.intersects(target), "card covers its own target: \(target)")
    }
  }

  /// A target too tall to stand beside — the reading surface fills the window — gets the card laid
  /// over it and the outline instead of a pointer, which is the only honest option left.
  func testFullHeightTargetGetsAnOutlineInsteadOfAPointer() {
    let readingArea = CGRect(origin: .zero, size: overlay)
    let placement = TutorialCallout.placement(
      target: readingArea, cardSize: card, overlaySize: overlay)

    assertInside(placement, overlay)
    XCTAssertEqual(placement.tip, .none)
    XCTAssertEqual(placement.highlight, readingArea)
  }

  /// AC5 with scaled system text in a minimum-size window: the card grows past what the overlay
  /// can hold, so it is capped to the overlay rather than hanging off it — the view scrolls the
  /// remainder, and the buttons stay reachable.
  func testCardTallerThanTheOverlayIsCappedToIt() {
    let small = CGSize(width: 420, height: 260)
    let grown = CGSize(width: 360, height: 900)
    let placement = TutorialCallout.placement(
      target: CGRect(x: 100, y: -30, width: 80, height: 28), cardSize: grown, overlaySize: small)

    assertInside(placement, small)
    XCTAssertEqual(
      placement.cardFrame.height, small.height - 2 * TutorialCallout.margin, accuracy: 0.001)
  }

  /// The steps that describe the tutorial itself have no control to point at, and must not invent
  /// one: centred card, no pointer, no outline.
  func testStepWithoutATargetIsCentred() {
    let placement = TutorialCallout.placement(target: nil, cardSize: card, overlaySize: overlay)

    assertInside(placement, overlay)
    XCTAssertEqual(placement.cardFrame.midX, overlay.width / 2, accuracy: 0.001)
    XCTAssertEqual(placement.cardFrame.midY, overlay.height / 2, accuracy: 0.001)
    XCTAssertEqual(placement.tip, .none)
    XCTAssertNil(placement.highlight)
  }

  /// AppKit measures from the bottom-left of the window and SwiftUI from the top-left of the
  /// overlay. Getting this flip wrong is what would put a card at the bottom of the window while
  /// pointing at a control at the top, so it is pinned down explicitly.
  func testWindowToOverlayConversionFlipsTheVerticalAxis() {
    let overlayInWindow = CGRect(x: 0, y: 0, width: 900, height: 600)
    let toolbarItem = CGRect(x: 420, y: 620, width: 120, height: 28)

    let converted = TutorialCallout.overlayRect(
      windowRect: toolbarItem, overlayWindowRect: overlayInWindow)

    XCTAssertEqual(converted.minX, 420, accuracy: 0.001)
    XCTAssertEqual(converted.minY, -48, accuracy: 0.001, "the toolbar sits above the overlay")
    XCTAssertEqual(converted.size, toolbarItem.size)

    let inContent = CGRect(x: 100, y: 100, width: 200, height: 40)
    let contentConverted = TutorialCallout.overlayRect(
      windowRect: inContent, overlayWindowRect: overlayInWindow)
    XCTAssertEqual(contentConverted.minY, 460, accuracy: 0.001)
  }
}
