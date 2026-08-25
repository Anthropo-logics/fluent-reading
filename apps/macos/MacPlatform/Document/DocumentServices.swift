import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage
import PDFKit
import Vision
import os

/// The language a document is actually written in, read off the text the app already extracts
/// (Story 6.11).
///
/// Until this existed every call site passed `"es"`. That fixed value was the recognition hint given
/// to Vision, and it was also what the engine judged each page's own text layer by: the degradation
/// rule of the day fired only for `es`/`pt`, and asked for nothing but the diacritics those two
/// languages practically always carry. So an English book was scored against a language it never
/// had, and the reader was offered a Spanish voice for it.
///
/// The engine no longer leans on the language the way it did — three of its four signals
/// (`direct_text_degradation`, Story 6.13) are about the shape of the text and are asked of all
/// three languages alike — but the fourth still is the diacritics test, so what is said here about
/// the document still decides whether a page keeps its own text or is read again.
///
/// **What one wrong answer here costs** (Story 6.16, AC6). This value is asked once per document
/// and then obeyed everywhere, so a single mistake spreads into three separate harms at once:
///
/// 1. **The page is thrown away.** `direct_text_degradation`'s diacritics test asks an `es`/`pt`
///    document for accents. English prose has none, so every page of an English book called `es` is
///    marked degraded, its perfectly good text layer discarded, and the page recognised again by
///    Vision. Measured on `Goldberg2002`: **168 of 169 pages**.
/// 2. **And recognised in the wrong language.** The re-recognition uses `visionLanguage(...)` with
///    the same wrong label, so English is read by a recogniser told to expect Spanish — the pass
///    meant to repair the page is itself handicapped.
/// 3. **And read aloud by the wrong voice.** `preferredVoiceLanguage` preselects from the same
///    value, so the reader is offered a Spanish voice for an English book.
///
/// It also costs time and battery: OCR of a page is three orders of magnitude dearer than keeping
/// the text that is already there. That is why an error here is worth more care than its one call
/// site suggests.
///
/// Everything here runs on the device: `NLLanguageRecognizer` ships with the system, downloads
/// nothing and reaches no network (AC8).
public enum DocumentLanguage {
  /// What the app falls back to when the document cannot say what it is. This is the value that used
  /// to be hardcoded everywhere, so falling back is exactly the previous behaviour (AC3).
  public static let fallback = "es"

  /// The engine rejects a `normalize_page` payload whose language is outside this set
  /// (`crates/lectura-core/src/lib.rs`), and the voice manifest offers no other. An identified
  /// language that is not one of these is therefore not usable, however confident it was.
  public static let supported = ["es", "en", "pt"]

  /// Pages read to decide the question, spread from the first to the last rather than taken off the
  /// head (Story 6.16). A handful settles the body text without reading a whole book; taking them
  /// from the head alone meant a book was judged by its front matter.
  public static let sampledPages = 8

  /// A cover with a title and an author's name cannot decide a language, but
  /// `NLLanguageRecognizer` will answer anyway — confidently, on nothing. Below this many letters
  /// the document is treated as having said nothing (AC3).
  static let minimumLetters = 200

  /// Spanish and Portuguese share enough vocabulary that the recogniser splits its belief between
  /// them on short passages. Requiring a clear majority keeps a near-tie from picking a language.
  static let minimumConfidence = 0.55

  /// How much of a passage `NLLanguageRecognizer` reads: about the first hundred characters of each
  /// `processString` call, and nothing after them.
  ///
  /// Measured, because it is documented nowhere. Ninety-six characters of Spanish followed by 34.800
  /// characters of English come back `es=1.000`, with English not even among the three hypotheses;
  /// the same accented Spanish placed at offset 100 of an English passage does not move the answer
  /// off `en=0.999`. Window size makes no difference to how well a single call does: over the three
  /// books of `tests/tts/sources` the per-window verdict is right 99,8 % (es), 100 % (en) and 95,3 %
  /// (pt — and those misses are, one by one, the English Project Gutenberg licence bolted onto the
  /// Portuguese file, plus one quotation from Montaigne in French) at 100 characters, and exactly as
  /// right at 400. A bigger passage is not a better question, it is the same question with more of
  /// it thrown away.
  ///
  /// This is what went wrong in Story 6.11. Joining the first eight pages produced a sample that
  /// looked large and was — 23.976 letters for `Goldberg2002` — and the recogniser read its cover,
  /// «For Philomena THE R ACIAL S TATE / David Theo Goldberg / … BRADLEY UNIVERSITY LIBRARY», called
  /// it Swedish at 0,670, and never saw the 169 pages of English behind it. Swedish is not a
  /// language this app supports, so the book fell back to `es`, and Story 6.13 then judged English
  /// prose by a Spanish rule: 168 of its 169 pages routed to OCR with a perfect text layer in hand.
  ///
  /// The answer is not a bigger passage. It is more passages: the text is cut into windows, each
  /// window is one question to the recogniser, and the document's language is what they vote for.
  static let windowCharacters = 200

  /// A window with less than half its characters as letters is skipped rather than asked. Covers,
  /// page numbers, running heads and tables of figures clear the character count without carrying
  /// enough language to decide anything, and asking anyway is how they get a vote they have not
  /// earned.
  static let minimumWindowLetters = 100

  /// The vote is capped so that the work does not grow with the document. A window costs about
  /// 1,8 ms, so on `Goldberg2002` this is the difference between 57 ms and 404 ms — and a
  /// thirty-two-window vote is decided far past any doubt already: at the worst per-window accuracy
  /// measured on real prose (95,3 %), a wrong majority of 32 is not something that happens.
  ///
  /// Identifying a document costs ~135 ms in all, once, off the main thread, against ~52 ms before.
  /// It is paid before the first page is normalised, and against it stands what a wrong answer
  /// costs: 168 pages of unnecessary OCR on one book alone.
  static let maximumWindows = 32

  /// What the document said, and how clearly it said it. Since Story 6.16 the confidence is the
  /// winner's **share of the vote**, not one recogniser's own certainty: a book that answered 32
  /// windows to 0 can be told apart from one that answered 17 to 15, and a failure from a guess
  /// that barely made it.
  public struct Identification: Equatable, Sendable {
    public let language: String
    public let confidence: Double

    public init(language: String, confidence: Double) {
      self.language = language
      self.confidence = confidence
    }
  }

  /// Identifies the language of already-extracted text, or returns nil when the text is too thin to
  /// decide, the windows do not agree clearly enough, or the answer is a language the app cannot
  /// use.
  ///
  /// The text is cut into windows and each window is asked separately, because a single call only
  /// ever reads its first hundred characters or so (see `windowCharacters`). The windows vote, each
  /// carrying the weight of its own certainty; a window the recogniser is not sure about says
  /// nothing rather than tipping the count. The reported confidence is the winner's share of the
  /// vote, so a book that answered 32 windows to 0 can be told from one that answered 17 to 15.
  ///
  /// The hypotheses are read rather than `dominantLanguage`, which reports a winner without saying
  /// how narrow the win was. The winner is taken over *all* languages and only then checked against
  /// `supported`: constraining the recogniser to es/en/pt would make a French book answer one of the
  /// three instead of falling back (Story 6.11, lecciones §5.1).
  public nonisolated static func identify(in text: String) -> Identification? {
    guard text.filter(\.isLetter).count >= minimumLetters else { return nil }
    let windows = votingWindows(in: text)
    guard !windows.isEmpty else { return nil }

    var score: [String: Double] = [:]
    let recognizer = NLLanguageRecognizer()
    for window in windows {
      recognizer.reset()
      recognizer.processString(window)
      let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
      guard let best = hypotheses.max(by: { $0.value < $1.value }),
        best.value >= minimumConfidence
      else { continue }
      score[best.key.rawValue, default: 0] += best.value
    }

    let total = score.values.reduce(0, +)
    guard total > 0, let winner = score.max(by: { $0.value < $1.value }) else { return nil }
    let share = winner.value / total
    guard share >= minimumConfidence, supported.contains(winner.key) else { return nil }
    return Identification(language: winner.key, confidence: share)
  }

  /// The passages the vote is taken over: the text cut into windows of `windowCharacters`, the ones
  /// too thin to be worth asking dropped, and at most `maximumWindows` kept — spread from the first
  /// to the last, never the first N, so that capping the work does not quietly turn the vote back
  /// into a question about the head of the document.
  nonisolated static func votingWindows(in text: String) -> [String] {
    let characters = Array(text)
    var windows: [String] = []
    var start = 0
    while start < characters.count {
      let window = characters[start..<min(start + windowCharacters, characters.count)]
      if window.lazy.filter(\.isLetter).count >= minimumWindowLetters {
        windows.append(String(window))
      }
      start += windowCharacters
    }
    guard windows.count > maximumWindows else { return windows }
    return spreadIndices(over: windows.count, count: maximumWindows).map { windows[$0] }
  }

  /// `count` indices spread from 0 across `total`, used for both the pages read and the windows
  /// kept. Returns everything when there is not enough to choose from.
  nonisolated static func spreadIndices(over total: Int, count: Int) -> [Int] {
    guard count > 0 else { return [] }
    guard total > count else { return Array(0..<max(total, 0)) }
    return (0..<count).map { $0 * total / count }
  }

  /// A document's own text layer, read from `sampledPages` pages spread from the first to the last
  /// and joined as one passage. Empty for a scan that carries no text at all — those documents
  /// answer later, from what Vision reads (Story 6.11, AC1).
  ///
  /// Spread, not the head: a book's front matter is a cover, a copyright page and a table of
  /// contents, and those are the pages least like the book. Reading the head was what let
  /// `Goldberg2002` — 169 pages of English — be decided by its title page (Story 6.16).
  public nonisolated static func sampleText(from document: PDFDocument) -> String {
    spreadIndices(over: document.pageCount, count: sampledPages)
      .compactMap { document.page(at: $0)?.string }
      .joined(separator: "\n")
  }

  /// The same question asked off the main thread. The vote is dozens of recogniser calls — some 58
  /// ms at the cap — so it does not belong on the thread that is drawing the page. Used by the OCR
  /// path, which asks again after each recognised page until the document answers (Story 6.16).
  public nonisolated static func identifyAsync(in text: String) async -> Identification? {
    await Task.detached(priority: .userInitiated) { identify(in: text) }.value
  }

  /// Reads the sampled pages of the text layer off the main thread, the way the outline prescan
  /// does, so opening stays responsive.
  public static func identifyAsync(in document: PDFDocument) async -> Identification? {
    let sendable = SendablePDFDocument(value: document)
    return await Task.detached(priority: .userInitiated) {
      identify(in: sampleText(from: sendable.value))
    }.value
  }

  /// Which voice language to preselect (AC4). The document's own language wins when a voice for it
  /// is installed; otherwise the previous rule stands — the system's preferred language, and failing
  /// that the first one installed — so the reader is never left with no voice to pick.
  public static func preferredVoiceLanguage(
    document: String?, available: [String], systemPreferred: [String]
  ) -> String? {
    guard !available.isEmpty else { return nil }
    if let document, available.contains(document) { return document }
    return systemPreferred.first(where: available.contains) ?? available[0]
  }
}

/// One entry of a document's table of contents, keeping the nesting depth so a navigator can show
/// the structure the way any PDF reader does.
public struct DocumentOutlineEntry: Identifiable, Equatable, Sendable {
  public let title: String
  public let pageIndex: Int
  public let level: Int

  public var id: String { "\(pageIndex)-\(level)-\(title)" }

  public init(title: String, pageIndex: Int, level: Int) {
    self.title = title
    self.pageIndex = pageIndex
    self.level = level
  }
}

/// A passage rendered over the page in place of its source text.
public struct TranslatedOverlayBlock: Equatable, Sendable {
  public let pageIndex: Int
  public let rectPDFPoints: [Double]
  public let text: String

  public init(pageIndex: Int, rectPDFPoints: [Double], text: String) {
    self.pageIndex = pageIndex
    self.rectPDFPoints = rectPDFPoints
    self.text = text
  }
}

/// A non-editable, wrapping label that reports a double click by calling `onDoubleClick`. Used one
/// per translated passage: a single merged text view could not tell which passage was double-clicked
/// (an `NSTextView` also swallowed the click before `ReadOnlyPDFView.mouseDown` ever saw it, silently
/// disabling "read from here" on any translated page).
///
/// A gesture recognizer, not an overridden `mouseDown`: `NSTextField` is an `NSControl`, and its
/// cell begins tracking the mouse on the *first* click of the pair — that tracking loop can consume
/// the second click internally (to extend the text selection to a word) without ever handing the
/// window a fresh top-level `mouseDown` with `clickCount == 2`, so an override here silently never
/// fires. A gesture recognizer sees the event before the control's own tracking gets it.
private final class TranslatedPassageLabel: NSTextField {
  var onDoubleClick: (() -> Void)?

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard superview != nil, gestureRecognizers.isEmpty else { return }
    let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
    recognizer.numberOfClicksRequired = 2
    addGestureRecognizer(recognizer)
  }

  @objc private func handleDoubleClick() { onDoubleClick?() }
}

/// Flips the coordinate system so passages stack top-to-bottom in reading order using plain
/// increasing-Y arithmetic, instead of the bottom-up space the rest of AppKit uses.
private final class TopDownView: NSView {
  override var isFlipped: Bool { true }
}

public final class ReadOnlyPDFView: PDFView {
  private let sourceIndicator = CAShapeLayer()
  private var translatedBlocks: [TranslatedOverlayBlock] = []
  private var translatedPageIndex = -1
  private var translatedScroll: NSScrollView?
  private var translatedContainer: TopDownView?
  private var translatedLabels: [TranslatedPassageLabel] = []
  /// The marker lives in its own overlay view. As a sublayer of the PDF view it was painted under
  /// PDFKit's own document subviews, which is why no reading indicator was ever visible.
  private let indicatorOverlay = NSView()

  /// Double-clicking a passage reports the point in page coordinates, together with the index of
  /// the page that was actually
  /// clicked. The reader's page index is not enough: it only ever travels from the model to this
  /// view, so a click had been matched against the passages of whichever page the model believed
  /// was current.
  public var onDoubleClickPagePoint: ((CGPoint, Int) -> Void)?

  public override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2, let page = currentPage, let document {
      let index = document.index(for: page)
      if index >= 0 {
        let location = convert(event.locationInWindow, from: nil)
        onDoubleClickPagePoint?(convert(location, to: page), index)
      }
    }
    super.mouseDown(with: event)
  }

  var sourceIndicatorBounds: CGRect { sourceIndicator.path?.boundingBox ?? .null }

  /// Right-pointing triangle placed in the margin at the top-left corner of `rect`.
  private func caret(besideTopOf rect: CGRect) -> CGPath {
    let size: CGFloat = 11
    let gap: CGFloat = 7
    let tipX = max(rect.minX - gap, 2)
    let top = rect.maxY
    let path = CGMutablePath()
    path.move(to: CGPoint(x: tipX, y: top))
    path.addLine(to: CGPoint(x: tipX - size * 0.85, y: top + size / 2))
    path.addLine(to: CGPoint(x: tipX - size * 0.85, y: top - size / 2))
    path.closeSubpath()
    return path
  }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    sourceIndicator.fillColor = NSColor.controlAccentColor.cgColor
    sourceIndicator.strokeColor = NSColor.clear.cgColor
    indicatorOverlay.wantsLayer = true
    indicatorOverlay.layer?.addSublayer(sourceIndicator)
    indicatorOverlay.autoresizingMask = [.width, .height]
    addSubview(indicatorOverlay, positioned: .above, relativeTo: nil)
  }

  required init?(coder: NSCoder) { nil }

  public override func perform(_ action: PDFAction) {}

  public override func layout() {
    super.layout()
    indicatorOverlay.frame = bounds
    indicatorOverlay.isHidden = sourceIndicator.path == nil && translatedBlocks.isEmpty
    layoutTranslatedText()
  }

  /// Lays the translated passages inside the page's text area, reflowed. Fitting each translation
  /// into the exact box of the block it replaces cannot work — a translated passage has a different
  /// length, so it ends up either shrunk past legibility or truncated. Reading is what matters, so
  /// the text keeps a body size close to the original and flows within the page margins, scrolling
  /// if it runs longer than the source did.
  public func showTranslations(_ blocks: [TranslatedOverlayBlock], forPage pageIndex: Int) {
    guard blocks != translatedBlocks || pageIndex != translatedPageIndex else { return }
    translatedBlocks = blocks
    translatedPageIndex = pageIndex
    layoutTranslatedText()
  }

  private func layoutTranslatedText() {
    // Only draw once the view has actually turned to the page these blocks belong to. Turning a
    // page updates the reader before PDFKit catches up, and trusting `currentPage` alone left the
    // previous page's translation on screen.
    guard let document, let page = currentPage,
      document.index(for: page) == translatedPageIndex
    else {
      translatedScroll?.isHidden = true
      return
    }
    let visible = translatedBlocks.filter {
      $0.pageIndex == translatedPageIndex && $0.rectPDFPoints.count == 4
    }
    guard !visible.isEmpty else {
      translatedScroll?.isHidden = true
      return
    }

    let scroll = translatedScroll ?? makeTranslatedScroll()
    let container = translatedContainer ?? scroll.documentView as! TopDownView
    scroll.isHidden = false

    // The page's own text area, so the translation keeps the book's margins.
    let minX = visible.map { $0.rectPDFPoints[0] }.min() ?? 0
    let minY = visible.map { $0.rectPDFPoints[1] }.min() ?? 0
    let maxX = visible.map { $0.rectPDFPoints[0] + $0.rectPDFPoints[2] }.max() ?? 0
    let maxY = visible.map { $0.rectPDFPoints[1] + $0.rectPDFPoints[3] }.max() ?? 0
    let area = convert(
      CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), from: page)
    scroll.frame = area.insetBy(dx: -4, dy: -4)

    // Body size taken from the source: the median line height of the blocks being replaced.
    let heights = visible.map { $0.rectPDFPoints[3] / Double(max(estimatedLines(in: $0), 1)) }
      .sorted()
    let lineHeight = heights.isEmpty ? 12 : heights[heights.count / 2]
    let scale = area.height / max(maxY - minY, 1)
    let bodySize = max(9, min(22, lineHeight * 0.74 * scale))
    let font = NSFont.systemFont(ofSize: bodySize)
    let width = max(scroll.contentSize.width - 8, 40)

    while translatedLabels.count > visible.count {
      translatedLabels.removeLast().removeFromSuperview()
    }
    while translatedLabels.count < visible.count {
      let label = TranslatedPassageLabel(wrappingLabelWithString: "")
      label.isEditable = false
      label.isSelectable = true
      label.isBordered = false
      label.drawsBackground = false
      label.lineBreakMode = .byWordWrapping
      container.addSubview(label)
      translatedLabels.append(label)
    }

    var offsetY: CGFloat = 4
    let spacing: CGFloat = bodySize * 0.9
    for (label, block) in zip(translatedLabels, visible) {
      label.stringValue = block.text
      label.font = font
      let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
      label.frame = CGRect(x: 4, y: offsetY, width: width, height: height)
      // The double click reports the centre of the source block directly in page-space points,
      // which the reader already knows how to map back to its unit — no on-screen hit test needed.
      let rect = block.rectPDFPoints
      label.onDoubleClick = { [weak self] in
        self?.onDoubleClickPagePoint?(
          CGPoint(x: rect[0] + rect[2] / 2, y: rect[1] + rect[3] / 2), block.pageIndex)
      }
      offsetY += height + spacing
    }
    container.frame = CGRect(x: 0, y: 0, width: width + 8, height: max(offsetY, area.height))
  }

  /// How many source lines a block spanned, used to recover its body size from its box.
  private func estimatedLines(in block: TranslatedOverlayBlock) -> Int {
    max(1, Int((block.rectPDFPoints[3] / 14).rounded()))
  }

  private func makeTranslatedScroll() -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let container = TopDownView()
    scroll.documentView = container
    indicatorOverlay.addSubview(scroll)
    translatedScroll = scroll
    translatedContainer = container
    return scroll
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === indicatorOverlay ? self : hit
  }

  public func show(_ region: DigitalSourceRegion?, in document: PDFDocument) {
    indicatorOverlay.frame = bounds
    defer { indicatorOverlay.isHidden = sourceIndicator.path == nil && translatedBlocks.isEmpty }
    guard let region, let page = document.page(at: Int(region.pageIndex)) else {
      sourceIndicator.path = nil
      return
    }
    if region.confidence >= 0.6, region.rectPDFPoints.count == 4 {
      let rect = CGRect(
        x: region.rectPDFPoints[0], y: region.rectPDFPoints[1],
        width: region.rectPDFPoints[2], height: region.rectPDFPoints[3])
      // A caret in the left margin, level with the top of the passage being read. An outline around
      // the whole block was easy to lose against the page; a marker that travels down the margin
      // tells the reader at a glance which paragraph the voice is on.
      sourceIndicator.path = caret(besideTopOf: convert(rect, from: page))
      sourceIndicator.fillColor = NSColor.controlAccentColor.cgColor
    } else {
      sourceIndicator.path = CGPath(
        rect: CGRect(x: 8, y: bounds.midY - 24, width: 4, height: 48), transform: nil)
      sourceIndicator.fillColor = NSColor.systemOrange.cgColor
    }
  }
}

public enum DocumentOpenError: String, Error, Equatable, Sendable {
  case encrypted
  case unreadable
}

private struct SendablePDFDocument: @unchecked Sendable {
  let value: PDFDocument
}

public struct DigitalSourceRegion: Codable, Equatable, Sendable {
  public let pageIndex: UInt32
  public let rectPDFPoints: [Double]
  public let pageRotationDegrees: Int
  public let sourceToPageTransform: [Double]
  public let confidence: Double

  enum CodingKeys: String, CodingKey {
    case pageIndex = "page_index"
    case rectPDFPoints = "rect_pdf_points"
    case pageRotationDegrees = "page_rotation_degrees"
    case sourceToPageTransform = "source_to_page_transform"
    case confidence
  }
}

public struct DigitalTextBlock: Codable, Equatable, Sendable {
  public let blockID: String
  public let text: String
  public let region: DigitalSourceRegion
  public let confidence: Double

  enum CodingKeys: String, CodingKey {
    case blockID = "block_id"
    case text, region, confidence
  }
}

public struct DigitalPageResult: Codable, Equatable, Sendable {
  public let pageIndex: UInt32
  public let status: String
  public let blocks: [DigitalTextBlock]
  public let errorCode: String?

  enum CodingKeys: String, CodingKey {
    case pageIndex = "page_index"
    case status, blocks
    case errorCode = "error_code"
  }
}

@MainActor
public enum DocumentServices {
  public static func openReadOnly(with grant: ReadAccessGrant) throws -> PDFDocument {
    try openReadOnly(at: grant.url)
  }

  public static func openReadOnlyAsync(with grant: ReadAccessGrant) async throws -> PDFDocument {
    let url = grant.url
    let document = try await Task.detached(priority: .userInitiated) {
      SendablePDFDocument(value: try makeReadOnlyDocument(at: url))
    }.value
    return document.value
  }

  public static func openReadOnly(at url: URL) throws -> PDFDocument {
    try makeReadOnlyDocument(at: url)
  }

  /// The document's own authored outline (table of contents), in reading order.
  /// Confidence/order validation happens downstream in `AudiobookExporter.chapterMarks`.
  public static func outlineEntries(from document: PDFDocument) -> [(title: String, pageIndex: Int)]
  {
    guard let root = document.outlineRoot else { return [] }
    var entries: [(title: String, pageIndex: Int)] = []
    func walk(_ node: PDFOutline) {
      for index in 0..<node.numberOfChildren {
        guard let child = node.child(at: index) else { continue }
        if let label = child.label, let page = child.destination?.page {
          let pageIndex = document.index(for: page)
          if pageIndex >= 0 { entries.append((label, pageIndex)) }
        }
        walk(child)
      }
    }
    walk(root)
    return entries
  }

  /// Outline entries keeping their nesting depth, for a navigable table of contents. The flat
  /// `outlineEntries` stays as it is because chapter marks for export do not need the hierarchy.
  public nonisolated static func outlineOutline(from document: PDFDocument)
    -> [DocumentOutlineEntry]
  {
    guard let root = document.outlineRoot else { return [] }
    var entries: [DocumentOutlineEntry] = []
    func walk(_ node: PDFOutline, level: Int) {
      for index in 0..<node.numberOfChildren {
        guard let child = node.child(at: index) else { continue }
        if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty, let page = child.destination?.page
        {
          let pageIndex = document.index(for: page)
          if pageIndex >= 0 {
            entries.append(
              DocumentOutlineEntry(title: label, pageIndex: pageIndex, level: level))
          }
        }
        walk(child, level: level + 1)
      }
    }
    walk(root, level: 0)
    // Scanned books often ship a machine-generated outline whose labels carry no words at all
    // ("f - 0002"). Such an outline is worse than none: it hides the headings recovered from the
    // page behind entries a reader cannot navigate by.
    let readable = entries.filter { entry in
      entry.title.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 3 }
    }
    return readable.count * 2 >= entries.count ? entries : []
  }

  /// Builds a table of contents from the PDF's own text layer, using typographic size rather than
  /// OCR geometry. Reading every page's attributed string costs seconds even on a 1000-page book,
  /// so the navigator is complete as soon as the document opens instead of filling in page by page
  /// as OCR progresses. Vision still runs afterwards for reading quality; when it recovers a
  /// heading on a page this scan also found, the OCR text replaces this one (see
  /// `ReaderViewModel.documentOutline`) because a degraded text layer loses diacritics.
  ///
  /// Returns an empty list when the document has no usable text layer, no typographic hierarchy, or
  /// so many candidates that size clearly does not mark titles in it.
  public static func prescanHeadingsAsync(from document: PDFDocument) async
    -> [DocumentOutlineEntry]
  {
    let sendable = SendablePDFDocument(value: document)
    return await Task.detached(priority: .utility) {
      prescanHeadings(from: sendable.value)
    }.value
  }

  public nonisolated static func prescanHeadings(from document: PDFDocument)
    -> [DocumentOutlineEntry]
  {
    struct Line {
      let text: String
      let size: Double
      let pageIndex: Int
    }

    var lines: [Line] = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex), let attributed = page.attributedString else {
        continue
      }
      let string = attributed.string as NSString
      string.enumerateSubstrings(
        in: NSRange(location: 0, length: string.length), options: .byLines
      ) { _, range, _, _ in
        var size = 0.0
        // A line that exists only because the reader kept its recognised text inside the PDF
        // (Story 6.6) never votes here. Its type size comes from the height of the box Vision drew
        // around the words, which grows with capitals, digits and accents rather than with the
        // body of the face — feeding it to a scan that reads titles off type size would invent a
        // table of contents where the page has none, and would shift the body-size median that
        // decides what counts as a title on every other page.
        var recognisedLayerOnly = true
        attributed.enumerateAttribute(.font, in: range) { value, _, _ in
          let font = value as? NSFont
          if let font, OCRTextLayer.isLayerFont(font) { return }
          recognisedLayerOnly = false
          if let font { size = max(size, Double(font.pointSize)) }
        }
        let text = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !recognisedLayerOnly {
          lines.append(Line(text: text, size: size, pageIndex: pageIndex))
        }
      }
    }

    let sizes = lines.map(\.size).sorted()
    guard !sizes.isEmpty else { return [] }
    let bodySize = sizes[sizes.count / 2]
    guard bodySize > 0 else { return [] }
    let titleSize = bodySize * 1.35
    let chapterSize = bodySize * 2.5

    // A title can span several lines and mix sizes (a large numeral over a smaller subtitle), and
    // scanned layers drop stray accent fragments between them, so lines without letters never break
    // a title in two.
    var candidates: [DocumentOutlineEntry] = []
    var current: DocumentOutlineEntry?
    var currentIsChapter = false
    var lastPageIndex = -1
    for line in lines {
      if line.pageIndex != lastPageIndex {
        if let heading = current { candidates.append(heading) }
        current = nil
        lastPageIndex = line.pageIndex
      }
      let hasLetters = line.text.contains(where: \.isLetter)
      if line.size >= titleSize && hasLetters {
        if current == nil {
          currentIsChapter = line.size >= chapterSize
          current = DocumentOutlineEntry(
            title: line.text, pageIndex: line.pageIndex, level: currentIsChapter ? 0 : 1)
        } else {
          current = DocumentOutlineEntry(
            title: current!.title + " " + line.text, pageIndex: current!.pageIndex,
            level: current!.level)
        }
      } else if !hasLetters {
        continue
      } else if let heading = current {
        candidates.append(heading)
        current = nil
      }
    }
    if let heading = current { candidates.append(heading) }

    var headings = candidates.filter { heading in
      let words = heading.title.split(separator: " ").count
      guard (1...30).contains(words) else { return false }
      guard !heading.title.hasSuffix("."), !heading.title.hasSuffix(",") else { return false }
      // Cover artwork and scan noise ("NO'MhWN-fl", "W600 OO") is mostly non-letters.
      let letters = heading.title.filter(\.isLetter).count
      let meaningful = heading.title.filter { $0.isLetter || $0 == " " }.count
      return letters >= 3 && Double(meaningful) / Double(heading.title.count) >= 0.75
    }

    // A running head repeats across the book; a title appears once.
    var pagesByTitle: [String: Set<Int>] = [:]
    for heading in headings {
      pagesByTitle[heading.title.lowercased(), default: []].insert(heading.pageIndex)
    }
    headings = headings.filter { (pagesByTitle[$0.title.lowercased()]?.count ?? 0) < 3 }

    // More than roughly one title per two pages means size is not what marks titles here; a
    // navigator that long is noise, not a table of contents.
    guard headings.count <= max(4, document.pageCount * 3 / 5) else { return [] }
    return headings
  }

  nonisolated private static func makeReadOnlyDocument(at url: URL) throws -> PDFDocument {
    guard url.isFileURL, let document = PDFDocument(url: url), document.pageCount > 0 else {
      throw DocumentOpenError.unreadable
    }
    guard !document.isLocked else {
      throw DocumentOpenError.encrypted
    }
    return document
  }

  public static func extractDigitalPages(
    from document: PDFDocument, pageLimit: Int? = nil
  ) -> [DigitalPageResult] {
    let count = min(document.pageCount, pageLimit ?? document.pageCount)
    return (0..<count).map { extractDigitalPage(from: document, pageIndex: $0) }
  }

  /// A reader-chosen orientation for one page, applied to the copy this extraction opens.
  ///
  /// Some pages are printed sideways and say nothing about it: a landscape table set across a
  /// portrait page, or a sheet fed into the scanner the wrong way round. `/Rotate` reads 0, so
  /// nothing — not the viewer, not the engine — has any reason to turn them, and the reader is left
  /// tilting their head while the voice reads the page down a column that is really a line.
  ///
  /// Measured on the owner's 818 PDFs: 84 pages of 25 documents are printed across the page while
  /// the file claims they are upright.
  ///
  /// Setting the rotation on the opened copy is all it takes, and it is exact rather than clever:
  /// PDFKit's line rectangles and crop box are **invariant** to `rotation` (verified on
  /// `BraunClarke2013` p36 at all four quarter turns — identical to the hundredth of a point), so
  /// the rectangles keep landing on the words and only the axis the engine reads them along
  /// changes. The file on disk is never touched.
  nonisolated private static func apply(_ rotation: Int?, to page: PDFPage?) {
    guard let rotation, let page else { return }
    page.rotation = rotation
  }

  public static func extractDigitalPage(
    at url: URL, pageIndex: Int, rotation: Int? = nil
  ) async -> DigitalPageResult {
    await Task.detached(priority: .utility) {
      guard url.isFileURL, let document = PDFDocument(url: url), !document.isLocked else {
        return DigitalPageResult(
          pageIndex: UInt32(pageIndex), status: "failed", blocks: [],
          errorCode: "LF_PDF_UNREADABLE")
      }
      apply(rotation, to: document.page(at: pageIndex))
      return extractDigitalPage(from: document, pageIndex: pageIndex)
    }.value
  }

  public static func extractOCRPage(
    at url: URL, pageIndex: Int, language: String, rotation: Int? = nil
  ) async -> DigitalPageResult {
    await Task.detached(priority: .utility) {
      guard url.isFileURL, let document = PDFDocument(url: url), !document.isLocked else {
        return DigitalPageResult(
          pageIndex: UInt32(max(0, pageIndex)), status: "failed", blocks: [],
          errorCode: "LF_PDF_UNREADABLE")
      }
      apply(rotation, to: document.page(at: pageIndex))
      return extractOCRPages(
        from: document, pageIndexes: [pageIndex], language: language
      ).first
        ?? DigitalPageResult(
          pageIndex: UInt32(max(0, pageIndex)), status: "failed", blocks: [],
          errorCode: "LF_OCR_RECOGNITION_FAILED")
    }.value
  }

  nonisolated private static func extractDigitalPage(
    from document: PDFDocument, pageIndex: Int
  ) -> DigitalPageResult {
    guard pageIndex >= 0, let page = document.page(at: pageIndex) else {
      return DigitalPageResult(
        pageIndex: UInt32(max(0, pageIndex)), status: "failed", blocks: [],
        errorCode: "LF_PDF_PAGE_MISSING")
    }
    // The page is asked for its whole character range, not for the rectangle it occupies.
    //
    // `PDFDocument.selection(from:at:to:at:)`, which stood here, does not select a rectangle: it
    // selects the run between the characters nearest those two points *in the page's own content
    // order*, the way dragging the cursor does. On a page whose content order does not run from the
    // top left to the bottom right — several columns, floating boxes, marginal notes, a repository
    // stamp added above the type block — everything the order places before the first point or
    // after the last one was left out, with no error and no indication: the reader simply never
    // heard it.
    //
    // Measured over the owner's 818 real PDFs (67,197 pages, Story 6.14): the two corners returned
    // 97.78 % of the letters `page.string` reports, 2,333 pages (3.47 %) lost more than a tenth of
    // theirs, and one page of 2,081 letters came back with 183. The whole character range returns
    // 100.00 %, produces 4.4 % more lines, loses a line on no page of the corpus, and costs
    // 0.39 ms per page against 2.68 — finding the character nearest a point is a search over the
    // page, and asking by index skips it.
    //
    // `document.selection(from:atCharacterIndex:to:atCharacterIndex:)` was measured to return
    // exactly the same lines and boxes on all 64,226 pages of the corpus that carry text; the page
    // is asked directly here because a range has no off-by-one to get wrong.
    let characterCount = page.numberOfCharacters
    let lines =
      characterCount > 0
      ? page.selection(for: NSRange(location: 0, length: characterCount))?.selectionsByLine() ?? []
      : []
    let blocks = lines.enumerated().compactMap { lineIndex, selection -> DigitalTextBlock? in
      guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else { return nil }
      let bounds = selection.bounds(for: page)
      return DigitalTextBlock(
        blockID: "page-\(pageIndex)-block-\(lineIndex)",
        text: text,
        region: DigitalSourceRegion(
          pageIndex: UInt32(pageIndex),
          rectPDFPoints: [bounds.minX, bounds.minY, bounds.width, bounds.height],
          pageRotationDegrees: page.rotation,
          sourceToPageTransform: [1, 0, 0, 1, 0, 0],
          confidence: 1
        ),
        confidence: 1
      )
    }
    return DigitalPageResult(
      pageIndex: UInt32(pageIndex),
      status: blocks.isEmpty ? "failed" : "completed",
      blocks: blocks,
      errorCode: blocks.isEmpty ? "LF_PDF_PAGE_NO_TEXT" : nil)
  }

  nonisolated public static func extractOCRPages(
    from document: PDFDocument, pageIndexes: Set<Int>, language: String
  ) -> [DigitalPageResult] {
    pageIndexes.sorted().map { pageIndex in
      guard let page = document.page(at: pageIndex) else {
        return DigitalPageResult(
          pageIndex: UInt32(pageIndex), status: "failed", blocks: [],
          errorCode: "LF_PDF_PAGE_MISSING")
      }
      let bounds = page.bounds(for: .cropBox)
      guard bounds.width > 0, bounds.height > 0 else {
        return DigitalPageResult(
          pageIndex: UInt32(pageIndex), status: "failed", blocks: [],
          errorCode: "LF_PDF_PAGE_INVALID")
      }

      let targetScale = 300.0 / 72.0
      let targetPixels = bounds.width * targetScale * bounds.height * targetScale
      // ponytail: Vision fails above this stable edge on macOS 15; tile pages if
      // corpus evidence later shows that 3200 px loses required OCR accuracy.
      let scale = min(
        targetScale,
        3200.0 / max(bounds.width, bounds.height),
        targetPixels > 24_000_000 ? targetScale * sqrt(24_000_000 / targetPixels) : targetScale
      )
      let image = page.thumbnail(
        of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return DigitalPageResult(
          pageIndex: UInt32(pageIndex), status: "failed", blocks: [],
          errorCode: "LF_PDF_RENDER_FAILED")
      }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = [visionLanguage(language)]
      do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
      } catch {
        return DigitalPageResult(
          pageIndex: UInt32(pageIndex), status: "failed", blocks: [],
          errorCode: "LF_OCR_RECOGNITION_FAILED")
      }

      let blocks = (request.results ?? [])
        .compactMap { observation -> (VNRecognizedTextObservation, VNRecognizedText)? in
          observation.topCandidates(1).first.map { (observation, $0) }
        }
        .sorted {
          if abs($0.0.boundingBox.midY - $1.0.boundingBox.midY) > 0.01 {
            return $0.0.boundingBox.midY > $1.0.boundingBox.midY
          }
          return $0.0.boundingBox.minX < $1.0.boundingBox.minX
        }
        .enumerated()
        .map { blockIndex, value in
          let observation = value.0
          let recognized = value.1
          return DigitalTextBlock(
            blockID: "page-\(pageIndex)-ocr-\(blockIndex)",
            text: recognized.string,
            region: DigitalSourceRegion(
              pageIndex: UInt32(pageIndex),
              rectPDFPoints: pageSpaceRect(observation.boundingBox, on: page, within: bounds),
              pageRotationDegrees: page.rotation,
              sourceToPageTransform: [1, 0, 0, 1, 0, 0],
              confidence: Double(recognized.confidence)
            ),
            confidence: Double(recognized.confidence)
          )
        }
      // A page that renders and recognises without throwing but yields no text is a blank page
      // (title versos, section separators): valid content, not a failure. Only genuine technical
      // faults above — missing page, invalid bounds, render failure, Vision throwing — report
      // "failed", so the reader is never blocked by an unrecoverable error it cannot retry away.
      return DigitalPageResult(
        pageIndex: UInt32(pageIndex),
        status: !blocks.isEmpty && scale < targetScale ? "degraded" : "completed",
        blocks: blocks,
        errorCode: nil
      )
    }
  }

  /// Where a box Vision reported sits in the page's own coordinates.
  ///
  /// `PDFPage.thumbnail(of:for:)` renders the page **as it is displayed** — it applies the page's
  /// `/Rotate` — while `bounds(for: .cropBox)` reports the box in unrotated PDF user space. On a
  /// quarter-turned page the two disagree about which dimension is which, and scaling Vision's
  /// normalised box by the wrong one put every recognised line somewhere it is not: on
  /// `Goldberg2002` p5 (`/Rotate 90`, crop 593 x 824) a line whose ink runs 633 pt down the page
  /// came back as a box 456 pt wide and 34 pt tall. Highlighting, "read from here" and the
  /// engine's own reading order all take that rectangle at its word.
  ///
  /// Verified against the same page's embedded text layer, whose boxes come straight from PDFKit
  /// in page space: after this mapping the two agree.
  ///
  /// An upright page is returned exactly as before — the quarter turn is the identity there — so
  /// the 63,000 unrotated pages of the reference corpus are untouched.
  nonisolated private static func pageSpaceRect(
    _ normalized: CGRect, on page: PDFPage, within bounds: CGRect
  ) -> [Double] {
    let turn = ((page.rotation % 360) + 360) % 360
    let quarterTurned = turn % 180 != 0
    let displayWidth = quarterTurned ? bounds.height : bounds.width
    let displayHeight = quarterTurned ? bounds.width : bounds.height
    let x = normalized.minX * displayWidth
    let y = normalized.minY * displayHeight
    let width = normalized.width * displayWidth
    let height = normalized.height * displayHeight
    switch turn {
    case 90:
      return [bounds.maxX - (y + height), bounds.minY + x, height, width]
    case 180:
      return [bounds.maxX - (x + width), bounds.maxY - (y + height), width, height]
    case 270:
      return [bounds.minX + y, bounds.maxY - (x + width), height, width]
    default:
      return [bounds.minX + x, bounds.minY + y, width, height]
    }
  }

  nonisolated private static func visionLanguage(_ language: String) -> String {
    switch language {
    case "es": return "es-ES"
    case "pt": return "pt-BR"
    default: return "en-US"
    }
  }
}

public enum OCRTextLayerError: String, Error, Equatable, Sendable {
  /// No page of the request could take the layer — nothing was written, the file is untouched.
  case nothingToEmbed
  case unreadable
  case writeFailed
}

/// Story 6.18: keeping the recognised text failed on an external volume and the app said nothing at
/// all — the three ways it can refuse are collapsed into one sentence for the reader, and the error
/// underneath was thrown away. The reader's message stays as plain as it was; this is where the
/// reason goes, so the next failure of this kind takes minutes to place instead of a session.
let writeLog = Logger(subsystem: "com.lecturafluida.app", category: "writing")

/// Writes the text the reader's own OCR already recognised back into the PDF, as an invisible layer
/// underneath the page, so reopening that document does not pay for the recognition again
/// (Story 6.6).
///
/// The PRD calls the source document "external and read-only", and `ReadAccessGrant` is named after
/// that rule. This is the one place where the app writes to it, deliberately and narrowly: only on
/// the owner's explicit confirmation, only on pages whose own text layer had nothing worth reading,
/// and never in a way that changes what the page looks like.
public enum OCRTextLayer {
  /// One of the fourteen faces every PDF reader is required to have, so keeping the layer costs no
  /// embedded font and next to no bytes. It also marks the layer: prose is practically never set in
  /// Courier, so a run in this face is how `prescanHeadings` tells recognised text apart from the
  /// document's own (AC8).
  public static let layerFontName = "Courier"

  public nonisolated static func isLayerFont(_ font: NSFont) -> Bool {
    font.fontName == layerFontName
  }

  /// The two ways a page can end up carrying the recognised text.
  enum Route {
    /// The page has no text worth keeping, so the recognised words simply go on top of it, over
    /// its own drawing left untouched (Story 6.6).
    case overOwnDrawing
    /// The page carries a text layer of its own that cannot be read — a scan vectorised with a
    /// broken Unicode map — so its content is redrawn glyph by glyph, without that text, before
    /// the recognised words go on (Story 6.9).
    case replacingBrokenText
  }

  /// Whether recognised text can be kept on this page without spoiling what the page already reads
  /// as, and by which of the two routes.
  ///
  /// PDFKit lays a page's text out by position, and it merges two lines that sit at the same
  /// height into one — character by character, in x order. Measured on a real book whose scanning
  /// software had left a poor text layer behind, a quarter of the lines came back interleaved
  /// ("c o m p l e j o d e i n f e r i o r i d a d"), which no reader and no voice can use. So the
  /// recognised words are only ever added to a page that has no text of its own to interleave
  /// with: either because its layer is empty or so thin the recognition found several times more
  /// letters than it holds, or because the page's own broken text is being taken out in the same
  /// operation.
  nonisolated static func route(for result: DigitalPageResult, page: PDFPage) -> Route? {
    let recognised = result.blocks.map(\.text).joined(separator: " ")
    let recognisedLetters = recognised.filter(\.isLetter).count
    guard recognisedLetters > 0 else { return nil }
    let existing = page.string ?? ""
    if existing.filter(\.isLetter).count * 5 < recognisedLetters { return .overOwnDrawing }
    return isBrokenTextLayer(existing, against: recognised) ? .replacingBrokenText : nil
  }

  public nonisolated static func canEmbed(_ result: DigitalPageResult, into page: PDFPage) -> Bool {
    route(for: result, page: page) != nil
  }

  /// The same question, asked of the file rather than of a page already in hand.
  ///
  /// It has to be the file. `PDFPage.string` on a page that is **being shown in a `PDFView`** is
  /// not the page's own text: PDFKit runs its own recognition over image-only pages it displays,
  /// and from then on the page answers with words that are nowhere in the document. Measured on a
  /// three-page image-only fixture with a bare `PDFView` and no app around it: all three pages
  /// answer `nil` before, and twelve seconds after the view is shown page 0 answers with 1,216
  /// characters and page 1 — merely the neighbour PDFKit renders ahead — with 3,183.
  ///
  /// Asked of such a page, `route` reads that invention as a text layer the recognised words would
  /// interleave with, and declines to keep them. That is not a hypothetical: it is why the page the
  /// reader was looking at never got its recognised text kept, and why turning a page and having it
  /// re-read left the *first*, unturned recognition in the document (Story 6.15, QA of 2026-08-21).
  ///
  /// Opening the file is also what makes the offer honest: `embed` decides the same way, on the
  /// same bytes, so a page the reader is offered is a page that will actually be written.
  ///
  /// The cost is the extra open, and it is small because PDFKit opens lazily. Measured on the
  /// reference machine, opening and asking one page for its text: **0.1 ms** on an 8-page image-only
  /// book and **5.3 ms** on a 372-page scanned one (medians of twelve). The pass of Vision that
  /// produced `result` costs 485 ms in the same corpus.
  public nonisolated static func canEmbed(
    _ result: DigitalPageResult, atPageIndex pageIndex: Int, of url: URL
  ) -> Bool {
    guard url.isFileURL, let document = PDFDocument(url: url), !document.isLocked,
      let page = document.page(at: pageIndex)
    else { return false }
    return canEmbed(result, into: page)
  }

  /// Whether the page's own text layer says the same words as the recognition but cannot spell
  /// them.
  ///
  /// The signal is not how *many* letters the layer holds — on the reference book it holds as many
  /// as the recognition finds (949 against 953 on one page) — but *which*: a Spanish page of two
  /// thousand letters whose layer contains not one accented letter, where the recognition reads
  /// dozens, has a broken character map, not prose. Measured across that book: 0 accented letters
  /// in the layer against 19 to 63 per page recognised.
  ///
  /// The word check is the safety half. Replacing a page is only sound if the recognition is
  /// reading the same page: at least half of the words it found must already be in the layer
  /// (measured on the same pages: 0.73 to 0.81), which a recognition that has gone astray, or a
  /// page whose accents are simply absent from the prose, will not reach.
  nonisolated static func isBrokenTextLayer(_ existing: String, against recognised: String) -> Bool
  {
    let unmapped = recognised.filter { $0.isLetter && !$0.isASCII }.count
    guard unmapped >= 8,
      existing.filter({ $0.isLetter && !$0.isASCII }).count * 10 < unmapped
    else { return false }
    func words(_ text: String) -> [Substring] {
      text.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 4 }
    }
    let known = Set(words(existing))
    let found = words(recognised)
    guard !found.isEmpty else { return false }
    return found.filter(known.contains).count * 2 >= found.count
  }

  /// Replaces `url` with a copy carrying the recognised text of `pages`, or leaves it untouched.
  ///
  /// Nothing is written to the reader's file until the whole document has been built successfully
  /// in a temporary one; the last step is a single atomic replacement (AC4). A failure, or a
  /// cancellation between pages (AC7), throws before that step and the original stays exactly as
  /// it was — down to the byte.
  public nonisolated static func embed(
    _ pages: [UInt32: DigitalPageResult], into url: URL
  ) throws {
    guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
      writeLog.error("embed: the document could not be reopened for writing (unreadable)")
      throw OCRTextLayerError.unreadable
    }
    var overOwnDrawing: [(index: Int, result: DigitalPageResult)] = []
    var replacingBrokenText: [(index: Int, result: DigitalPageResult)] = []
    for (pageIndex, result) in pages.sorted(by: { $0.key < $1.key }) {
      let index = Int(pageIndex)
      guard let page = document.page(at: index) else { continue }
      switch route(for: result, page: page) {
      case .overOwnDrawing: overOwnDrawing.append((index, result))
      case .replacingBrokenText: replacingBrokenText.append((index, result))
      case nil: continue
      }
    }
    // Read the table of contents off the pages that are about to lose their own text, while they
    // still have it (see `keepOutline`).
    let headings =
      replacingBrokenText.isEmpty ? [] : DocumentServices.prescanHeadings(from: document)
    let redrawn = try replacingBrokenText.isEmpty ? nil : redraw(replacingBrokenText, of: url)
    // The redrawn pages come out of a document of their own; it has to outlive the write, not just
    // the loop that hands its pages over.
    defer { withExtendedLifetime(redrawn) {} }

    var embedded = 0
    for (index, result) in overOwnDrawing {
      try Task.checkCancellation()
      guard let page = document.page(at: index),
        let replacement = pageKeepingRecognisedText(of: page, blocks: result.blocks)
      else { continue }
      document.removePage(at: index)
      document.insert(replacement, at: index)
      embedded += 1
    }
    var replaced = 0
    for (index, replacement) in redrawn?.pages ?? [] {
      try Task.checkCancellation()
      // The one thing that makes redrawing a page safe: unless the new drawing renders as the old
      // one did, the page is left exactly as it was.
      guard let page = document.page(at: index), matchesVisually(page, replacement) else {
        continue
      }
      document.removePage(at: index)
      document.insert(replacement, at: index)
      embedded += 1
      replaced += 1
    }
    if replaced > 0 { keepOutline(headings, in: document) }
    guard embedded > 0 else {
      writeLog.error(
        """
        embed: no page took the layer (asked for \(pages.count, privacy: .public), \
        over own drawing \(overOwnDrawing.count, privacy: .public), \
        redrawn \(replacingBrokenText.count, privacy: .public))
        """)
      throw OCRTextLayerError.nothingToEmbed
    }
    writeLog.notice(
      """
      embed: \(embedded, privacy: .public) page(s) carry the recognised text \
      (\(replaced, privacy: .public) redrawn); staging the replacement
      """)
    try Task.checkCancellation()

    let temporary = try stagingURL(for: url)
    guard document.write(to: temporary) else {
      writeLog.error(
        "embed: PDFDocument.write refused, staging=\(temporary.path, privacy: .private)")
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
      throw OCRTextLayerError.writeFailed
    }
    do {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      writeLog.error(
        """
        embed: replaceItemAt failed: \(error as NSError, privacy: .public) \
        sameVolume=\(sameVolume(temporary, url) == true, privacy: .public)
        """)
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
      throw OCRTextLayerError.writeFailed
    }
    try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
  }

  /// Where the rebuilt document is staged before it replaces the reader's file.
  ///
  /// It has to be on the **same volume as the file being replaced** (Story 6.18). The obvious
  /// `FileManager.temporaryDirectory` is on the boot disk, and `replaceItemAt` is a rename: asked
  /// to move a staged file onto another volume it fails with `NSPOSIXErrorDomain 18`, *Cross-device
  /// link*, wrapped in `NSCocoaErrorDomain 512`. Measured, and nothing to do with the sandbox — the
  /// same call fails the same way from an ordinary command-line tool. That is why keeping the
  /// recognised text worked for a document on the internal disk and failed for the very same
  /// document on the external one, which is where this project keeps books by design.
  ///
  /// `.itemReplacementDirectory` is the API that answers "somewhere I can stage a replacement for
  /// *this* URL", and it answers with a directory on that URL's own volume.
  nonisolated private static func stagingURL(for url: URL) throws -> URL {
    let directory: URL
    do {
      directory = try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
    } catch {
      writeLog.error(
        "embed: no replacement directory: \(error as NSError, privacy: .public)")
      throw OCRTextLayerError.writeFailed
    }
    return directory.appendingPathComponent("ocr-layer-\(UUID().uuidString)")
      .appendingPathExtension("pdf")
  }

  /// `nil` when either volume identifier could not be read — the answer is for the log only.
  nonisolated private static func sameVolume(_ one: URL, _ other: URL) -> Bool? {
    guard
      let a = (try? one.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
      let b = (try? other.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    else { return nil }
    return a.isEqual(b)
  }

  /// A copy of `page` drawing exactly what it drew before, plus the recognised words placed
  /// invisibly over the glyphs they were read from.
  ///
  /// The page's own content is redrawn, not re-rendered to an image: a scanned page keeps its
  /// original image untouched and a typeset one keeps its vectors, so the file grows by little more
  /// than the words themselves and the page looks the same at any zoom (AC3).
  nonisolated private static func pageKeepingRecognisedText(
    of page: PDFPage, blocks: [DigitalTextBlock]
  ) -> PDFPage? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return nil }
    var mediaBox = page.bounds(for: .mediaBox)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
    context.beginPDFPage(nil)
    context.saveGState()
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()
    context.saveGState()
    context.setTextDrawingMode(.invisible)
    for block in blocks { draw(block, in: context) }
    context.restoreGState()
    context.endPDFPage()
    context.closePDF()

    guard let copy = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
    // Drawing a page into a context does not carry its rotation or its crop, and losing either
    // would turn the page sideways or show margins the reader never saw.
    //
    // This is the page's *own* rotation even when the reader turned the page while reading: a turn
    // made on screen is a way of looking at the page, not an edit of it, and Story 6.6 promises the
    // document comes back looking exactly as it did. The recognised layer follows the reader's axis
    // (see `draw`); the page keeps the orientation its file declares.
    copy.rotation = page.rotation
    copy.setBounds(page.bounds(for: .cropBox), for: .cropBox)
    return copy
  }

  /// Pages built in one document, so they can be kept alive together while they are checked and
  /// swapped in.
  struct Redrawn {
    let document: PDFDocument
    let pages: [(index: Int, page: PDFPage)]
  }

  /// Copies of the given pages with their own text taken out and the recognised words put on
  /// instead (Story 6.9).
  ///
  /// Every page goes into a single PDF context on purpose. Core Graphics embeds one subset of a
  /// font per `CGFont` object it is handed, and the shared cache makes all the pages of a book
  /// share theirs: measured on the reference book, 369 pages came to 5.3 MB together where a
  /// context per page came to 16.7 MB for exactly the same ink.
  ///
  /// A page whose content this app cannot reproduce exactly is simply left out — it keeps the
  /// behaviour it had before this story.
  nonisolated private static func redraw(
    _ targets: [(index: Int, result: DigitalPageResult)], of url: URL
  ) throws -> Redrawn? {
    guard let source = PDFDocument(url: url), let original = CGPDFDocument(url as CFURL) else {
      return nil
    }
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return nil }
    var firstBox = source.page(at: targets[0].index)?.bounds(for: .mediaBox) ?? .zero
    guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }

    let cache = PDFGlyphReplay.FontCache()
    // A refused page still leaves a page behind in the document being built — the drawing stops
    // where the refusal happened, but `beginPDFPage` has already opened it. So each reproduced page
    // has to remember *where* it landed; counting only the good ones would hand every page after a
    // refusal the drawing of a different page.
    var built = 0
    var reproduced: [(index: Int, offset: Int)] = []
    for (index, result) in targets {
      try Task.checkCancellation()
      guard let page = source.page(at: index), let cgPage = original.page(at: index + 1) else {
        continue
      }
      let box = page.bounds(for: .mediaBox)
      let boxData = withUnsafeBytes(of: box) { Data($0) } as CFData
      context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
      context.saveGState()
      let outcome = PDFGlyphReplay.replay(page: cgPage, into: context, fonts: cache)
      context.restoreGState()
      if outcome.succeeded {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for block in result.blocks { draw(block, in: context) }
        context.restoreGState()
        reproduced.append((index, built))
      }
      context.endPDFPage()
      built += 1
    }
    context.closePDF()

    guard !reproduced.isEmpty, let document = PDFDocument(data: data as Data) else { return nil }
    var pages: [(index: Int, page: PDFPage)] = []
    for target in reproduced {
      guard let copy = document.page(at: target.offset), let page = source.page(at: target.index)
      else { continue }
      // Drawing a page into a context does not carry its rotation or its crop, and losing either
      // would turn the page sideways or show margins the reader never saw.
      copy.rotation = page.rotation
      copy.setBounds(page.bounds(for: .cropBox), for: .cropBox)
      pages.append((target.index, copy))
    }
    return Redrawn(document: document, pages: pages)
  }

  /// Whether the redrawn page puts the same ink on the paper as the page it replaces.
  ///
  /// This is what makes redrawing safe by construction: the reader's document is never changed on
  /// the strength of the interpreter being right, only on the strength of the result looking the
  /// same. Both pages are rendered at twice their size and compared channel by channel with the
  /// tolerance Story 6.6 already uses (0.02). Antialiasing along the edge of a glyph never lands on
  /// the same pixel twice, so a page passes when at most one pixel in two hundred is off — measured
  /// on the reference book, the worst of its 369 reproduced pages differed on 0.069% of its pixels,
  /// seven times inside that bound, while a page drawn wrong differed on 71%.
  nonisolated static func matchesVisually(_ original: PDFPage, _ replacement: PDFPage) -> Bool {
    guard let left = raster(original), let right = raster(replacement), left.count == right.count,
      !left.isEmpty
    else { return false }
    var differing = 0
    for index in stride(from: 0, to: left.count, by: 4) {
      for channel in 0..<3 where abs(Int(left[index + channel]) - Int(right[index + channel])) > 5 {
        differing += 1
        break
      }
    }
    return differing * 200 <= left.count / 4
  }

  nonisolated private static func raster(_ page: PDFPage) -> [UInt8]? {
    let scale = 2.0
    let bounds = page.bounds(for: .cropBox)
    let turned = page.rotation % 180 != 0
    let width = Int((turned ? bounds.height : bounds.width) * scale)
    let height = Int((turned ? bounds.width : bounds.height) * scale)
    guard width > 0, height > 0, width * height <= 16_000_000,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)
    guard let raw = context.data else { return nil }
    return Array(
      UnsafeBufferPointer(
        start: raw.bindMemory(to: UInt8.self, capacity: width * height * 4),
        count: width * height * 4))
  }

  /// Keeps the table of contents the navigator builds from the page's own typography.
  ///
  /// `prescanHeadings` reads titles off type size, and a page redrawn glyph by glyph has no type
  /// left to read — only the recognised layer, which that scan deliberately ignores. So the
  /// headings found before the change are written into the document's own outline, where the
  /// navigator already looks first: chapter navigation survives the change and becomes instant on
  /// every later opening. An outline the document already has and that the app can use is never
  /// touched; the one on the reference book (360 entries reading "f - 0002") is not one of those.
  nonisolated private static func keepOutline(
    _ headings: [DocumentOutlineEntry], in document: PDFDocument
  ) {
    guard !headings.isEmpty, DocumentServices.outlineOutline(from: document).isEmpty else { return }
    let root = PDFOutline()
    var chapter: PDFOutline?
    for heading in headings {
      guard let page = document.page(at: heading.pageIndex) else { continue }
      let node = PDFOutline()
      node.label = heading.title
      node.destination = PDFDestination(
        page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
      if heading.level == 0 || chapter == nil {
        root.insertChild(node, at: root.numberOfChildren)
        chapter = node
      } else if let chapter {
        chapter.insertChild(node, at: chapter.numberOfChildren)
      }
    }
    guard root.numberOfChildren > 0 else { return }
    document.outlineRoot = root
  }

  nonisolated private static func draw(_ block: DigitalTextBlock, in context: CGContext) {
    let points = block.region.rectPDFPoints
    guard points.count == 4, points[2] > 1, points[3] > 1 else { return }
    let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // The recognised line has to run along the same axis as the ink underneath it. A page content
    // stream is written in page space, which ignores the page's own `/Rotate`; on a quarter-turned
    // page a line of type is therefore a **tall, narrow** box, and laying the words across it
    // would squeeze a whole sentence into the width of a word and leave it crossing the visible
    // text at a right angle. The quarter turn is put on the coordinate system and the line is then
    // drawn as it would be on an upright page.
    //
    // The turn comes from the block's own region, which is the orientation its rectangle was
    // measured against, and never from the page `embed` reopened. Those are not always the same
    // page: a sheet printed sideways in a file that declares `/Rotate 0` is turned by the reader by
    // hand (Story 6.15), and that choice deliberately never touches the document — it is applied to
    // the private copy each extraction opens, and travels out with every region it emits. Reading
    // the axis off the file instead wrote the kept line across the ink on exactly those pages, in
    // the one place this app writes to the reader's own document. Measured on the same words and
    // the same rectangle: `[120.0 86.3 18.0 176.0]` where the control that declares the turn in
    // the file gives `[123.9 90.0 14.4 220.0]`. One frame, one source.
    //
    // The origin is the corner the reader sees as bottom-left, expressed in page space, and
    // `length`/`thickness` are the box's extent along and across the line as displayed.
    let x = points[0]
    let y = points[1]
    let width = points[2]
    let height = points[3]
    let origin: CGPoint
    let angle: CGFloat
    let length: Double
    let thickness: Double
    switch ((block.region.pageRotationDegrees % 360) + 360) % 360 {
    case 90:
      (origin, angle, length, thickness) = (CGPoint(x: x + width, y: y), .pi / 2, height, width)
    case 180:
      (origin, angle, length, thickness) = (
        CGPoint(x: x + width, y: y + height), .pi, width, height
      )
    case 270:
      (origin, angle, length, thickness) = (CGPoint(x: x, y: y + height), -.pi / 2, height, width)
    default:
      (origin, angle, length, thickness) = (CGPoint(x: x, y: y), 0, width, height)
    }

    let font = CTFontCreateWithName(layerFontName as CFString, max(thickness * 0.8, 1), nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
    let typeset = CTLineGetTypographicBounds(line, nil, nil, nil)
    guard typeset > 0 else { return }

    context.saveGState()
    // Stretching the line to the width of the box Vision read it from is what makes selecting the
    // recognised text land on the words on the page: the reading marker and "read from here" both
    // work off those rectangles. The stretch goes on the coordinate system, not on the text matrix
    // — `CTLineDraw` writes its own text matrix from the line's runs and the context's text
    // position, so a scale left there is simply dropped (measured: lines came out a fifth wider
    // than the words underneath, and long ones ran off the page).
    context.translateBy(x: origin.x, y: origin.y)
    context.rotate(by: angle)
    context.translateBy(x: 0, y: thickness * 0.18)
    context.scaleBy(x: length / typeset, y: 1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
