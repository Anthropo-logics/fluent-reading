// Story 6.21 — how much of a page is still on screen after the reader turns it.
//
// Why a standalone binary and not a unit test: `LecturaMacTests` runs under `xctest` with no
// `NSApplication`, where creating an `NSWindow` brings the whole run down and laying out a
// `PDFView` without one hangs (lecciones operativas §1.16). The defect this measures lives
// entirely in PDFKit's layout, so it needs a real window — this is the smallest thing that has
// one. `PDFReaderView.updateNSView` is mirrored below, in both its shapes, so the difference the
// fix makes can be measured without rebuilding the app.
//
// The measurement goes through `PDFView.convert(_:from: page)` — the same call the reading-position
// caret uses — so scale, scroll offset and rotation are all folded in, exactly as the reader sees
// them.
//
//   swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
//     -o /tmp/measure-rotation-viewport scripts/measure-rotation-viewport.swift
//   /tmp/measure-rotation-viewport --before --pdf tests/corpus/documents/adversarial-rotated.pdf
//   /tmp/measure-rotation-viewport --after  --pdf tests/corpus/documents/adversarial-rotated.pdf
//
// Exits non-zero when any check fails, so it can gate a re-measurement.

import AppKit
import PDFKit

let arguments = CommandLine.arguments
var pdfPath = "tests/corpus/documents/adversarial-rotated.pdf"
/// `--after` mirrors the shipped `updateNSView`; `--before` mirrors the one this story replaced,
/// so the defect can be reproduced on demand instead of taken on trust.
var fixed = true
var clockwise = true
for (offset, argument) in arguments.enumerated() {
  if argument == "--pdf", offset + 1 < arguments.count { pdfPath = arguments[offset + 1] }
  if argument == "--before" { fixed = false }
  if argument == "--after" { fixed = true }
  if argument == "--ccw" { clockwise = false }
}

guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
  FileHandle.standardError.write(Data("cannot open \(pdfPath)\n".utf8))
  exit(2)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
let view = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
view.autoScales = true
view.displayMode = .singlePage
view.displayDirection = .vertical
view.displaysPageBreaks = true
view.document = document
view.autoresizingMask = [.width, .height]
window.contentView?.addSubview(view)
window.makeKeyAndOrderFront(nil)

func pump(_ seconds: Double) {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    while let event = application.nextEvent(
      matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true)
    {
      application.sendEvent(event)
    }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
}

var pageIndex = 0

/// Share of the page's own ink that lies inside the viewport right now, 0…1.
func inkFraction() -> Double {
  guard let page = document.page(at: pageIndex) else { return -1 }
  let count = page.numberOfCharacters
  guard count > 0, let selection = page.selection(for: NSRange(location: 0, length: count))
  else { return -1 }
  let ink = selection.bounds(for: page)
  guard ink.width > 0, ink.height > 0 else { return -1 }
  let onScreen = view.convert(ink, from: page)
  let clipped = onScreen.intersection(view.bounds)
  guard !clipped.isNull else { return 0 }
  return (clipped.width * clipped.height) / (onScreen.width * onScreen.height)
}

func scrollView() -> NSScrollView? {
  var found: NSScrollView?
  func walk(_ candidate: NSView) {
    if found == nil, let scroll = candidate as? NSScrollView { found = scroll }
    candidate.subviews.forEach(walk)
  }
  walk(view)
  return found
}

func scrollOrigin() -> CGPoint { scrollView()?.contentView.bounds.origin ?? .zero }

// The representable's state, mirrored.
var appliedRotations: [UInt32: Int] = [:]
var overrides: [UInt32: Int] = [:]
var relayouts = 0

/// `PDFReaderView.updateNSView`, in both its shapes.
func updateNSView() {
  if fixed {
    if appliedRotations != overrides {
      appliedRotations = overrides
      for (index, rotation) in overrides {
        guard let page = document.page(at: Int(index)), page.rotation != rotation else { continue }
        page.rotation = rotation
      }
      view.layoutDocumentView()
      relayouts += 1
      if let page = document.page(at: pageIndex) { view.go(to: page) }
    }
  } else {
    var turned = false
    for (index, rotation) in overrides {
      guard let page = document.page(at: Int(index)), page.rotation != rotation else { continue }
      page.rotation = rotation
      turned = true
    }
    if turned {
      view.layoutDocumentView()
      relayouts += 1
    }
  }
  if let page = document.page(at: pageIndex), view.currentPage !== page { view.go(to: page) }
}

/// `ReaderViewModel.rotatePage`: it writes `page.rotation` itself, and only then does SwiftUI
/// re-render — which is the whole reason the old `page.rotation != rotation` guard never fired.
func rotate(clockwise: Bool) {
  guard let page = document.page(at: pageIndex) else { return }
  let turned = (((page.rotation + (clockwise ? 90 : -90)) % 360) + 360) % 360
  page.rotation = turned
  overrides[UInt32(pageIndex)] = turned
  updateNSView()
}

var failures = 0

pump(1.0)
print("build=\(fixed ? "after" : "before")  turn=\(clockwise ? "clockwise" : "counterclockwise")")
print("document=\(pdfPath)")
print(
  String(
    format: "  opened   rotation=%3d  inkVisible=%6.1f%%", document.page(at: 0)?.rotation ?? -1,
    inkFraction() * 100))
var worst = 1.0
for turn in 1...4 {
  rotate(clockwise: clockwise)
  pump(0.6)
  let visible = inkFraction()
  worst = min(worst, visible)
  print(
    String(
      format: "  turn %d   rotation=%3d  inkVisible=%6.1f%%", turn,
      document.page(at: 0)?.rotation ?? -1, visible * 100))
}
if worst <= 0.99 { failures += 1 }
print(
  String(format: "  a full turn keeps the page on screen: %.1f%% at worst -> ", worst * 100)
    + (worst > 0.99 ? "PASS" : "FAIL"))

// Nothing rotated, so nothing may move: `updateNSView` runs many times a second while reading, and
// re-laying the document out on every pass would fight the reader's own scrolling.
if let scroll = scrollView() {
  scroll.contentView.scroll(to: CGPoint(x: scrollOrigin().x, y: scrollOrigin().y + 37))
  scroll.reflectScrolledClipView(scroll.contentView)
  pump(0.3)
  let before = scrollOrigin()
  let relayoutsBefore = relayouts
  for _ in 0..<40 { updateNSView() }
  pump(0.3)
  let after = scrollOrigin()
  let moved =
    abs(after.y - before.y) > 0.5 || abs(after.x - before.x) > 0.5 || relayouts != relayoutsBefore
  if moved { failures += 1 }
  print(
    String(
      format: "  40 idle updates leave the scroll alone: (%.1f,%.1f) -> (%.1f,%.1f) -> ", before.x,
      before.y, after.x, after.y) + (moved ? "FAIL" : "PASS"))
}

if document.pageCount > 1 {
  pageIndex = min(3, document.pageCount - 1)
  updateNSView()
  pump(0.4)
  let landed = view.currentPage.map { document.index(for: $0) } ?? -1
  if landed != pageIndex { failures += 1 }
  print(
    "  turning to page \(pageIndex) still works: landed on \(landed) -> "
      + (landed == pageIndex ? "PASS" : "FAIL"))
}

exit(failures == 0 ? 0 : 1)
