import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit

@main
@MainActor
private struct DocumentExtractionProbe {
  static func main() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try makePDF(at: url)
    let before = SHA256.hash(data: try Data(contentsOf: url))

    let document = try DocumentServices.openReadOnly(at: url)
    let pages = DocumentServices.extractDigitalPages(from: document)

    precondition(pages.count == 2)
    precondition(pages[0].status == "completed")
    precondition(pages[0].blocks.map(\.text) == ["Primera línea", "Segunda línea"])
    precondition(pages[0].blocks.allSatisfy { $0.region.rectPDFPoints[2] > 0 })
    precondition(pages[1].status == "failed")
    precondition(pages[1].errorCode == "LF_PDF_PAGE_NO_TEXT")
    let after = SHA256.hash(data: try Data(contentsOf: url))
    precondition(after == before)
  }

  private static func makePDF(at url: URL) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else { throw ProbeError.creation }
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 480)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw ProbeError.creation
    }
    context.beginPDFPage(nil)
    for (text, y) in [("Primera línea", 400.0), ("Segunda línea", 360.0)] {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
      context.textPosition = CGPoint(x: 30, y: y)
      CTLineDraw(line, context)
    }
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
  }
}

private enum ProbeError: Error {
  case creation
}
