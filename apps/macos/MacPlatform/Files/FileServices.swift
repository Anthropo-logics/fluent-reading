import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class ReadAccessGrant {
  public let id = "grant_\(UUID().uuidString.lowercased())"
  let url: URL
  private let securityScoped: Bool

  init(url: URL) {
    self.url = url
    securityScoped = url.startAccessingSecurityScopedResource()
  }

  public var displayName: String { url.deletingPathExtension().lastPathComponent }

  /// `rotation`, when given, is the orientation the reader chose for this page: the extraction
  /// opens its own copy of the file and turns that page before reading it, so the narration
  /// follows the same axis the reader sees. The file on disk is not touched.
  public func extractDigitalPage(
    _ pageIndex: Int, rotation: Int? = nil
  ) async -> DigitalPageResult {
    await DocumentServices.extractDigitalPage(at: url, pageIndex: pageIndex, rotation: rotation)
  }

  public func extractDigitalPages(_ pageIndexes: [Int]) async -> [DigitalPageResult] {
    await DocumentServices.extractDigitalPages(at: url, pageIndexes: pageIndexes)
  }

  public func extractOCRPage(
    _ pageIndex: Int, language: String, rotation: Int? = nil
  ) async -> DigitalPageResult {
    await DocumentServices.extractOCRPage(
      at: url, pageIndex: pageIndex, language: language, rotation: rotation)
  }

  /// Whether the text just recognised for `pageIndex` could be kept inside the document.
  ///
  /// Asked of the file, on its own copy, and never of the page the reader is looking at: PDFKit
  /// recognises image-only pages it displays and then answers `PDFPage.string` with words that are
  /// not in the document, which reads as a text layer already there (see
  /// `OCRTextLayer.canEmbed(_:atPageIndex:of:)`). The file is also what `embedRecognisedText`
  /// writes to, so the offer and the write are decided by the same thing.
  public func canKeepRecognisedText(_ result: DigitalPageResult, pageIndex: Int) async -> Bool {
    let url = url
    return await Task.detached(priority: .utility) {
      OCRTextLayer.canEmbed(result, atPageIndex: pageIndex, of: url)
    }.value
  }

  /// Keeps the text the reader's OCR already recognised inside the document itself (Story 6.6).
  ///
  /// This is the only method of the grant that writes, and its name says so: the grant is otherwise
  /// read-only by design, and the PRD keeps the source document that way. The entitlement behind
  /// the open panel — `com.apple.security.files.user-selected.read-write` — has always allowed it;
  /// the app simply never exercised it before.
  ///
  /// The write runs while this grant is alive, so the security-scoped access opened in `init` is
  /// still held for the whole operation: the caller must keep holding the grant until this returns,
  /// or the scope would close underneath a write that can take a moment on a long book.
  public func embedRecognisedText(pages: [UInt32: DigitalPageResult]) async throws {
    let url = url
    try await Task.detached(priority: .userInitiated) {
      try OCRTextLayer.embed(pages, into: url)
    }.value
  }

  public func documentFingerprint() async throws -> String {
    let url = url
    return try await Task.detached(priority: .utility) {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hash = SHA256()
      while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
        hash.update(data: data)
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }.value
  }

  deinit {
    if securityScoped { url.stopAccessingSecurityScopedResource() }
  }
}

@MainActor
public enum FileServices {
  public static func selectPDF() -> ReadAccessGrant? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.prompt = String(localized: "reader.open")
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return ReadAccessGrant(url: url)
  }

}
