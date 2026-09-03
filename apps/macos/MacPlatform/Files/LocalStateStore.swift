import Foundation

public enum LocalStateStoreError: Error, Equatable, Sendable {
  case invalidDocumentID
  case applicationSupportUnavailable
  case storageChanged
}

public enum LocalStatePreparation: Equatable, Sendable {
  case current
  case invalidated
}

public enum LocalStateUnit: String, Sendable {
  case paragraph = "pages"
  case sentence = "sentences"
}

public enum LocalStateStore {
  @discardableResult
  public static func save(
    _ session: LFIncrementalSessionResult,
    root: URL? = nil
  ) throws -> URL {
    _ = try prepare(documentID: session.documentID, root: root)
    let directory = try sessionDirectory(documentID: session.documentID, root: root)
    let destination = directory.appendingPathComponent("session.json", isDirectory: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(session).write(to: destination, options: .atomic)
    return destination
  }

  @discardableResult
  public static func save(
    _ page: DigitalPageResult,
    documentID: String,
    root: URL? = nil
  ) throws -> URL {
    _ = try prepare(documentID: documentID, root: root)
    let directory = try sessionDirectory(documentID: documentID, root: root)
      .appendingPathComponent("pages", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: nil)
    let destination = directory.appendingPathComponent("\(page.pageIndex).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(page).write(to: destination, options: .atomic)
    return destination
  }

  @discardableResult
  public static func save(
    _ page: LFNormalizedPage,
    pageIndex: UInt32,
    documentID: String,
    unit: LocalStateUnit = .paragraph,
    root: URL? = nil
  ) throws -> URL {
    _ = try prepare(documentID: documentID, root: root)
    let directory = try sessionDirectory(documentID: documentID, root: root)
      .appendingPathComponent(unit.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: nil)
    let destination = directory.appendingPathComponent("\(pageIndex).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(page).write(to: destination, options: .atomic)
    return destination
  }

  public static func loadNormalizedPages(
    documentID: String,
    unit: LocalStateUnit = .paragraph,
    root: URL? = nil
  ) throws -> [UInt32: LFNormalizedPage] {
    _ = try prepare(documentID: documentID, root: root)
    let directory = try sessionDirectory(documentID: documentID, root: root)
      .appendingPathComponent(unit.rawValue, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ).reduce(into: [:]) { pages, url in
      guard url.pathExtension == "json",
        let pageIndex = UInt32(url.deletingPathExtension().lastPathComponent)
      else { return }
      guard let page = try? JSONDecoder().decode(LFNormalizedPage.self, from: Data(contentsOf: url))
      else { return }
      pages[pageIndex] = page
    }
  }

  public static func prepare(documentID: String, root: URL? = nil) throws
    -> LocalStatePreparation
  {
    let directory = try sessionDirectory(documentID: documentID, root: root)
    let descriptorURL = directory.appendingPathComponent("store.json")
    let descriptor = try? JSONDecoder().decode(
      StoreDescriptor.self, from: Data(contentsOf: descriptorURL))
    if descriptor == StoreDescriptor.current {
      return .current
    }
    let hasContents =
      try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
      == false
    let invalidated = FileManager.default.fileExists(atPath: descriptorURL.path) || hasContents
    if invalidated {
      try FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(StoreDescriptor.current).write(to: descriptorURL, options: .atomic)
    return invalidated ? .invalidated : .current
  }

  public static func usage(documentID: String, root: URL? = nil) throws -> UInt64 {
    let directory = try sessionDirectory(documentID: documentID, root: root, create: false)
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    let files = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    return try files?.reduce(into: UInt64(0)) { total, item in
      guard let url = item as? URL else { return }
      let values = try url.resourceValues(forKeys: keys)
      if values.isRegularFile == true, values.isSymbolicLink != true {
        total += UInt64(values.fileSize ?? 0)
      }
    } ?? 0
  }

  public static func deleteDerivedData(
    documentID: String,
    expectedBytes: UInt64,
    root: URL? = nil
  ) throws {
    guard try usage(documentID: documentID, root: root) == expectedBytes else {
      throw LocalStateStoreError.storageChanged
    }
    let directory = try sessionDirectory(documentID: documentID, root: root, create: false)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  /// Drops the session directories named after a launch counter, from before Story 6.25.
  ///
  /// `doc_{job_number:016x}` restarted at 1 with every launch, so a directory under one of those
  /// names holds the derived text of whichever documents were opened first, in any number of
  /// launches, mixed together. Now that a document is named after its own bytes nothing will ever
  /// claim those names again — and the storage panel only ever reports and deletes the *open*
  /// document's directory, so they would stay on disk unreported and impossible for the reader to
  /// remove. What goes is regenerable derived data; the PDFs it came from are not touched.
  ///
  /// Only the exact old shape is matched: `doc_` and sixteen lowercase hex digits. A name in the
  /// new shape carries thirty-two, so no document in use can be caught by this.
  @discardableResult
  public static func discardSessionsNamedByLaunchCounter(root: URL? = nil) -> Int {
    guard let sessions = try? sessionsDirectory(root: root),
      let names = try? FileManager.default.contentsOfDirectory(atPath: sessions.path)
    else { return 0 }
    return names.filter(isLaunchCounterName).reduce(into: 0) { removed, name in
      let directory = sessions.appendingPathComponent(name, isDirectory: true)
      if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
    }
  }

  private static func isLaunchCounterName(_ name: String) -> Bool {
    let counter = name.dropFirst("doc_".count)
    return name.hasPrefix("doc_") && counter.count == 16
      && counter.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func sessionsDirectory(root: URL?) throws -> URL {
    let base: URL
    if let root {
      base = root
    } else {
      guard
        let applicationSupport = FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first
      else { throw LocalStateStoreError.applicationSupportUnavailable }
      base = applicationSupport.appendingPathComponent("LecturaFluida", isDirectory: true)
    }
    return base.appendingPathComponent("sessions", isDirectory: true)
  }

  private static func sessionDirectory(
    documentID: String,
    root: URL?,
    create: Bool = true
  ) throws -> URL {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    guard !documentID.isEmpty,
      documentID.unicodeScalars.allSatisfy(allowed.contains)
    else { throw LocalStateStoreError.invalidDocumentID }

    let directory = try sessionsDirectory(root: root)
      .appendingPathComponent(documentID, isDirectory: true)
    if create {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: nil)
    }
    return directory
  }
}

private struct StoreDescriptor: Codable, Equatable {
  let schemaVersion: Int
  let recordType: String
  let writerVersion: String

  static let current = StoreDescriptor(
    schemaVersion: 1,
    recordType: "document_store",
    writerVersion: "0.1.0")

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case recordType = "record_type"
    case writerVersion = "writer_version"
  }
}
