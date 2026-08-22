import MacPlatform
import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
  let document: PDFDocument
  let pageIndex: Int
  let sourceRegion: DigitalSourceRegion?
  let firstPagePresented: () -> Void
  /// Double-clicking a passage on the page starts reading there, mirroring the same gesture in the
  /// immersion view so the choice of starting point does not depend on which surface is open.
  var startReadingAt: ((CGPoint, Int) -> Void)?
  /// Translated passages to lay over the page in place of their source blocks.
  var translatedBlocks: [TranslatedOverlayBlock] = []
  /// Orientations the reader chose by hand for particular pages (Story 6.15).
  ///
  /// Carried in as a value so SwiftUI notices the change and calls `updateNSView`: the rotation
  /// lives on the `PDFPage`, which SwiftUI cannot see, and without this the page kept its old
  /// orientation on screen until something else happened to redraw it.
  var pageRotations: [UInt32: Int] = [:]
  /// Whether the PDF surface is the one on screen.
  ///
  /// SwiftUI's `.opacity(0)` is not enough to hide this view: `ReadOnlyPDFView` is layer-backed
  /// (it needs `wantsLayer` to host the reading-position indicator), and a layer-backed AppKit view
  /// composites on its own, so it kept painting over the immersion surface stacked above it. AppKit
  /// honours `isHidden` regardless of layer backing, and hiding beats removing the view from the
  /// hierarchy here: the document, scroll position and page stay loaded for the way back.
  var isVisible: Bool = true

  /// Remembers which orientations have already been pushed into PDFKit.
  ///
  /// A turn cannot be told from `page.rotation`: `ReaderViewModel.rotatePage` writes the page
  /// itself, before SwiftUI re-renders, so by the time `updateNSView` looks the two always already
  /// agree — measured on `adversarial-rotated.pdf`, the old `page.rotation != rotation` guard let
  /// `layoutDocumentView()` run on **0 of 4** quarter turns. And the dictionary cannot simply be
  /// acted on every pass either: `updateNSView` runs several times a second while reading, and
  /// re-laying the document out that often would fight the reader's own scrolling.
  final class Coordinator {
    var appliedRotations: [UInt32: Int] = [:]
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> PDFView {
    let view = ReadOnlyPDFView()
    view.onDoubleClickPagePoint = { [startReadingAt] point, page in startReadingAt?(point, page) }
    view.autoScales = true
    view.displayMode = .singlePage
    view.displayDirection = .vertical
    view.displaysPageBreaks = true
    view.setAccessibilityIdentifier("reader.document")
    view.setAccessibilityLabel(String(localized: "reader.document"))
    view.document = document
    // The PDF view must accept whatever space is left instead of imposing the page's intrinsic
    // size on the layout: turning to a taller page pushed the reading toolbar out of the window.
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    return view
  }

  /// Always take the space SwiftUI offers; never report a preferred size derived from the page.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }

  func updateNSView(_ view: PDFView, context: Context) {
    view.isHidden = !isVisible
    // `documentView` is PDFKit's own scroll content view; it is created lazily once `view` is
    // actually installed in a window, so it is still nil in `makeNSView` when `.document` is
    // first assigned there. Re-applying here, after layout, is what makes the identifier appear
    // in the accessibility tree at all — setting it only in `makeNSView` left it silently unset.
    view.documentView?.setAccessibilityIdentifier("reader.document")
    view.documentView?.setAccessibilityLabel(String(localized: "reader.document"))
    (view as? ReadOnlyPDFView)?.onDoubleClickPagePoint = { [startReadingAt] point, page in
      startReadingAt?(point, page)
    }
    if view.document !== document { view.document = document }
    if context.coordinator.appliedRotations != pageRotations {
      context.coordinator.appliedRotations = pageRotations
      for (index, rotation) in pageRotations {
        guard let page = document.page(at: Int(index)), page.rotation != rotation else { continue }
        page.rotation = rotation
      }
      // PDFKit lays a page out once and keeps the result — including the scale it picked to fit the
      // orientation the page had then. Left alone after a turn, an upright page keeps the scale
      // chosen for a landscape one, comes out taller than the viewport, and the scroll offset that
      // was right before the turn now points above the text. Measured on
      // `adversarial-rotated.pdf`, turning ⌘] four times: 100 % / 100 % / 100 % / **0 %** / 100 %
      // of the page's ink on screen — the page went blank at rotation 0, the upright orientation
      // the reader was turning it *to*. Re-laying the document out recomputes the fit-to-view
      // scale, and going to the page puts it back under the viewport.
      view.layoutDocumentView()
      if let page = document.page(at: pageIndex) { view.go(to: page) }
    }
    // Keyboard focus is deliberately left alone here. Handing this view first responder status
    // does make Page Up/Down reach PDFKit — and it also hands PDFKit the **space bar**, which this
    // app spends on play/pause. Measured in the running app on `long-1000-pages.pdf`: with nothing
    // focused (a freshly opened document) space toggles narration, as it should; with this view
    // focused, space is swallowed by PDFKit, which pages the view forward without telling the
    // model — the page on screen read "LECTURA PAGINA 4" while the counter still said 2, so the
    // voice would narrate a page the reader is not looking at. The arrow keys survive it (SwiftUI's
    // key equivalents win), the space bar does not. A turned page no longer needs scrolling at all,
    // so the trade is not worth taking; the story records it as a known limit (AC3).

    if let page = document.page(at: pageIndex), view.currentPage !== page { view.go(to: page) }
    (view as? ReadOnlyPDFView)?.show(sourceRegion, in: document)
    (view as? ReadOnlyPDFView)?.showTranslations(translatedBlocks, forPage: pageIndex)
    DispatchQueue.main.async { firstPagePresented() }
  }
}
