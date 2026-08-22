import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

public enum AudiobookExportError: String, Error, Codable, Equatable, Sendable {
  case noNarrableUnits
  case insufficientSpace
  case destinationUnavailable
  case destinationExists
  case permissionDenied
  case synthesisFailed
  case encodingFailed
  case missingFragment
  case invalidManifest
  case verificationFailed
  case paused
  case cancelled
  /// AC5 (Story 5.9): translating a unit failed. The export stops here rather than falling back to
  /// the source text, which would silently publish an untranslated passage inside a file labelled
  /// as the translation.
  case translationFailed
}

public struct AudiobookExportUnit: Codable, Equatable, Sendable {
  public let unitID: String
  public let text: String
  public let anchorID: String

  public init(unitID: String, text: String, anchorID: String) {
    self.unitID = unitID
    self.text = text
    self.anchorID = anchorID
  }
}

public struct AudiobookChapterMark: Codable, Equatable, Sendable {
  public let title: String
  public let unitIndex: Int

  public init(title: String, unitIndex: Int) {
    self.title = title
    self.unitIndex = unitIndex
  }
}

public struct AudiobookExportRequest: Sendable {
  public let jobID: String
  public let sourceFingerprint: String
  public let title: String
  public let language: String
  public let voiceID: String
  public let units: [AudiobookExportUnit]
  public let model: InstallableModelManifest
  public let modelURL: URL
  public let runtimeURL: URL
  public let destinationURL: URL
  public let workRoot: URL
  public let replaceExisting: Bool
  public let chapters: [AudiobookChapterMark]

  public init(
    jobID: String, sourceFingerprint: String, title: String, language: String,
    voiceID: String, units: [AudiobookExportUnit], model: InstallableModelManifest,
    modelURL: URL, runtimeURL: URL, destinationURL: URL, workRoot: URL,
    replaceExisting: Bool = false, chapters: [AudiobookChapterMark] = []
  ) {
    self.jobID = jobID
    self.sourceFingerprint = sourceFingerprint
    self.title = title
    self.language = language
    self.voiceID = voiceID
    self.units = units
    self.model = model
    self.modelURL = modelURL
    self.runtimeURL = runtimeURL
    self.destinationURL = destinationURL
    self.workRoot = workRoot
    self.replaceExisting = replaceExisting
    self.chapters = chapters
  }
}

public struct AudiobookExportProgress: Equatable, Sendable {
  public let completedUnits: Int
  public let totalUnits: Int
  public let destinationName: String
}

public struct AudiobookFragment: Codable, Equatable, Sendable {
  public let unitID: String
  public let anchorID: String
  public let startSeconds: Double
  public let relativePath: String
  public let sha256: String
  public let durationSeconds: Double
}

public struct AudiobookJobManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let jobID: String
  public let sourceFingerprint: String
  public let title: String
  public let language: String
  public let voiceID: String
  public let modelID: String
  public let modelRevision: String
  public let format: String
  public let totalUnits: Int
  public var destinationBookmark: Data?
  public var destinationName: String
  public var fragments: [AudiobookFragment]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case jobID = "job_id"
    case sourceFingerprint = "source_fingerprint"
    case title, language
    case voiceID = "voice_id"
    case modelID = "model_id"
    case modelRevision = "model_revision"
    case format, fragments
    case totalUnits = "total_units"
    case destinationBookmark = "destination_bookmark"
    case destinationName = "destination_name"
  }
}

public struct AudiobookResumeCandidate: Sendable {
  public let manifest: AudiobookJobManifest
  public let destinationURL: URL
  public let accessRootURL: URL
}

public enum AudiobookExporter {
  public typealias Progress = @MainActor @Sendable (AudiobookExportProgress) -> Void
  public typealias Synthesize =
    @Sendable (
      TTSSynthesisRequest, URL, URL, URL
    ) throws -> TTSSynthesisResult
  /// Resolves the text to narrate for a unit. `nil` (the default) narrates `unit.text` as-is —
  /// Original export is unaffected. When set (Story 5.9, narrating a translation), it runs once per
  /// unit interleaved with synthesis, so a book is translated incrementally in export order rather
  /// than requiring the whole document translated up front.
  public typealias Translate = @Sendable (AudiobookExportUnit) async throws -> String

  public static func export(
    _ request: AudiobookExportRequest,
    shouldPause: @escaping @Sendable () async -> Bool = { false },
    synthesize: @escaping Synthesize = { request, runtimeURL, modelURL, workRoot in
      try ModelServices.synthesize(
        request, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot)
    },
    translate: Translate? = nil,
    progress: @escaping Progress = { _ in }
  ) async throws -> URL {
    guard !request.units.isEmpty else { throw AudiobookExportError.noNarrableUnits }
    let fileManager = FileManager.default
    let destination = request.destinationURL
    let destinationDirectory = destination.deletingLastPathComponent()
    // Story 6.17: this used to ask the enclosing folder for `.isWritableKey`, and then read the
    // free space off the folder too. Both questions are asked of something a sandboxed app has no
    // access to: a save panel grants the app **the file the reader named**, and nothing else in
    // that folder — measured, the folder reports not-writable, refuses a security-scoped bookmark
    // and will not take a sibling file, while the chosen file itself can be created and bookmarked.
    // So the preflight asks the destination: can this file be made, and does its volume have room?
    // Every export failed on `permissionDenied` before this, in every folder the reader tried.
    let alreadyThere = fileManager.fileExists(atPath: destination.path)
    if alreadyThere, !request.replaceExisting {
      throw AudiobookExportError.destinationExists
    }
    if !alreadyThere {
      guard fileManager.createFile(atPath: destination.path, contents: nil) else {
        throw fileManager.fileExists(atPath: destinationDirectory.path)
          ? AudiobookExportError.permissionDenied : AudiobookExportError.destinationUnavailable
      }
    }
    let words = request.units.reduce(0) {
      $0 + $1.text.split(whereSeparator: \.isWhitespace).count
    }
    let requiredBytes = Int64(max(10_000_000, words * 18_667))
    // Read while the file is certain to exist; the volume is the same either way.
    //
    // Two keys, because one of them lies on exactly the disks this app is meant for.
    // `…ForImportantUsage` is macOS's best answer on the boot volume, where it can count space it
    // would purge to make room — and on an external volume it answers **0**. Measured on the 3,6 TB
    // APFS disk this project keeps its books on: important=0, available=3 438 380 077 056, with the
    // internal disk answering 14,6 GB and 12,7 GB respectively. Asked only the first way, the export
    // turned down every external destination for lack of space on a disk that was 85 % empty.
    let space = try? destination.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    let capacity = max(
      space?.volumeAvailableCapacityForImportantUsage ?? 0,
      Int64(space?.volumeAvailableCapacity ?? 0))
    // The placeholder was a probe, not a result: an export that is cancelled or paused must not
    // leave an empty audiobook where the reader asked for one.
    if !alreadyThere { try? fileManager.removeItem(at: destination) }
    guard capacity >= requiredBytes else {
      throw AudiobookExportError.insufficientSpace
    }
    let jobRoot = request.workRoot.appendingPathComponent(request.jobID, isDirectory: true)
    let fragmentsRoot = jobRoot.appendingPathComponent("fragments", isDirectory: true)
    do {
      try fileManager.createDirectory(at: fragmentsRoot, withIntermediateDirectories: true)
    } catch { throw AudiobookExportError.permissionDenied }
    var manifest = try loadOrCreateManifest(request, jobRoot: jobRoot)
    try validate(manifest, request: request, jobRoot: jobRoot)

    do {
      for (index, unit) in request.units.enumerated().dropFirst(manifest.fragments.count) {
        try Task.checkCancellation()
        if await shouldPause() { throw AudiobookExportError.paused }
        let synthesisRoot = jobRoot.appendingPathComponent("current", isDirectory: true)
        try? fileManager.removeItem(at: synthesisRoot)
        // The unit narrated is either the source (Original) or, when `translate` is supplied, that
        // unit's translation — resolved now rather than ahead of time, one unit at a time.
        let narratedText: String
        if let translate {
          do { narratedText = try await translate(unit) } catch {
            throw AudiobookExportError.translationFailed
          }
        } else {
          narratedText = unit.text
        }
        // A translated fragment is traced back to both the translated unit ("t-<source>", matching
        // the id scheme the interactive translation view already uses) and, via anchorID, the
        // untouched source unit — AC4.
        let fragmentUnitID = translate == nil ? unit.unitID : "t-\(unit.unitID)"
        let result: TTSSynthesisResult
        do {
          result = try synthesize(
            TTSSynthesisRequest(
              modelId: request.model.id, modelRevision: request.model.modelRevision,
              runtimeId: request.model.runtimeId, runtimeVersion: request.model.runtimeVersion,
              voiceId: request.voiceID, language: request.language, rawIPA: false,
              units: [TTSUnitRequest(unitId: fragmentUnitID, text: narratedText)]),
            request.runtimeURL, request.modelURL, synthesisRoot)
        } catch { throw AudiobookExportError.synthesisFailed }
        try Task.checkCancellation()
        guard result.omittedUnitIds.isEmpty, !result.segments.isEmpty,
          result.segments.allSatisfy({ $0.unitId == fragmentUnitID })
        else { throw AudiobookExportError.synthesisFailed }
        let source = URL(fileURLWithPath: result.audioPath)
        let relative = String(format: "fragments/%08d.wav", index)
        let destination = jobRoot.appendingPathComponent(relative)
        try? fileManager.removeItem(at: destination)
        do { try fileManager.moveItem(at: source, to: destination) } catch {
          throw AudiobookExportError.permissionDenied
        }
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        let startSeconds = manifest.fragments.reduce(0) { $0 + $1.durationSeconds }
        manifest.fragments.append(
          AudiobookFragment(
            unitID: fragmentUnitID, anchorID: unit.anchorID, startSeconds: startSeconds,
            relativePath: relative,
            sha256: try sha256(destination), durationSeconds: duration))
        try save(manifest, at: jobRoot)
        await progress(
          AudiobookExportProgress(
            completedUnits: manifest.fragments.count, totalUnits: request.units.count,
            destinationName: request.destinationURL.lastPathComponent))
      }
      if await shouldPause() { throw AudiobookExportError.paused }
      try Task.checkCancellation()
      let temporary = jobRoot.appendingPathComponent("complete.m4a")
      try await assemble(manifest, jobRoot: jobRoot, output: temporary)
      let embeddedChapters = try embedChapters(request.chapters, manifest: manifest, at: temporary)
      try await verify(
        temporary, expectedDuration: manifest.fragments.reduce(0) { $0 + $1.durationSeconds },
        expectedChapters: embeddedChapters)
      do {
        // Story 6.17: replacing an existing audiobook used to go through `replaceItemAt`, which
        // needs to put its own items *next to* the destination — and the sandbox grants the app the
        // destination alone, not a folder it can add siblings to (measured: canCreateSibling=false).
        // It is also a rename, so it fails outright when the audiobook is staged on the boot volume
        // and the reader asked for it on an external one (Story 6.18, `NSPOSIXErrorDomain 18`).
        // Removing the old file and moving the new one onto its name touches nothing but the path
        // the reader chose, and `moveItem` copies across volumes when it cannot rename — measured.
        if fileManager.fileExists(atPath: request.destinationURL.path) {
          guard request.replaceExisting else { throw AudiobookExportError.destinationExists }
          try fileManager.removeItem(at: request.destinationURL)
        }
        try fileManager.moveItem(at: temporary, to: request.destinationURL)
      } catch let error as AudiobookExportError {
        throw error
      } catch {
        throw AudiobookExportError.destinationUnavailable
      }
      try? fileManager.removeItem(at: jobRoot)
      return request.destinationURL
    } catch is CancellationError {
      try? fileManager.removeItem(at: jobRoot)
      throw AudiobookExportError.cancelled
    } catch AudiobookExportError.paused {
      throw AudiobookExportError.paused
    }
  }

  public static func cancel(jobID: String, workRoot: URL) {
    try? FileManager.default.removeItem(at: workRoot.appendingPathComponent(jobID))
  }

  public static func resumableJobs(
    workRoot: URL, sourceFingerprint: String, modelID: String, modelRevision: String
  ) -> [AudiobookResumeCandidate] {
    let fileManager = FileManager.default
    let jobs =
      (try? fileManager.contentsOfDirectory(
        at: workRoot, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    return jobs.compactMap { jobRoot in
      guard
        let data = try? Data(contentsOf: jobRoot.appendingPathComponent("manifest.json")),
        let manifest = try? JSONDecoder().decode(AudiobookJobManifest.self, from: data),
        jobRoot.lastPathComponent == manifest.jobID,
        manifest.schemaVersion == 1, manifest.sourceFingerprint == sourceFingerprint,
        manifest.modelID == modelID, manifest.modelRevision == modelRevision,
        manifest.format == "m4b-aac-lc-24000-mono", manifest.totalUnits > 0,
        manifest.fragments.count < manifest.totalUnits,
        manifest.fragments.enumerated().allSatisfy({ index, fragment in
          let expectedStart = manifest.fragments.prefix(index).reduce(0) {
            $0 + $1.durationSeconds
          }
          return fragment.relativePath.hasPrefix("fragments/")
            && !fragment.relativePath.contains("..")
            && abs(fragment.startSeconds - expectedStart) < 0.001
            && (try? sha256(jobRoot.appendingPathComponent(fragment.relativePath)))
              == fragment.sha256
        }),
        let bookmark = manifest.destinationBookmark
      else { return nil }
      var stale = false
      guard
        let directory = try? URL(
          resolvingBookmarkData: bookmark, options: .withSecurityScope,
          relativeTo: nil, bookmarkDataIsStale: &stale), !stale
      else { return nil }
      return AudiobookResumeCandidate(
        manifest: manifest,
        destinationURL: directory.appendingPathComponent(manifest.destinationName),
        accessRootURL: directory)
    }
  }

  /// Removes job directories for this document whose manifest decodes but is structurally
  /// broken (bad schema, inconsistent fragment order, or a fragment hash mismatch) — never
  /// a job that is merely for a different model/voice, which stays resumable if reselected.
  public static func pruneStaleJobs(workRoot: URL, sourceFingerprint: String) {
    let fileManager = FileManager.default
    let jobs =
      (try? fileManager.contentsOfDirectory(
        at: workRoot, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    for jobRoot in jobs {
      guard let data = try? Data(contentsOf: jobRoot.appendingPathComponent("manifest.json")),
        let manifest = try? JSONDecoder().decode(AudiobookJobManifest.self, from: data),
        manifest.sourceFingerprint == sourceFingerprint
      else { continue }
      let structurallyValid =
        jobRoot.lastPathComponent == manifest.jobID && manifest.schemaVersion == 1
        && manifest.totalUnits > 0 && manifest.fragments.count < manifest.totalUnits
        && manifest.fragments.enumerated().allSatisfy { index, fragment in
          let expectedStart = manifest.fragments.prefix(index).reduce(0) {
            $0 + $1.durationSeconds
          }
          return fragment.relativePath.hasPrefix("fragments/")
            && !fragment.relativePath.contains("..")
            && abs(fragment.startSeconds - expectedStart) < 0.001
            && (try? sha256(jobRoot.appendingPathComponent(fragment.relativePath)))
              == fragment.sha256
        }
      if !structurallyValid { try? fileManager.removeItem(at: jobRoot) }
    }
  }

  private static func loadOrCreateManifest(
    _ request: AudiobookExportRequest, jobRoot: URL
  ) throws -> AudiobookJobManifest {
    let url = jobRoot.appendingPathComponent("manifest.json")
    if let data = try? Data(contentsOf: url),
      var value = try? JSONDecoder().decode(AudiobookJobManifest.self, from: data)
    {
      value.destinationBookmark = try? request.destinationURL.deletingLastPathComponent()
        .bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      value.destinationName = request.destinationURL.lastPathComponent
      try save(value, at: jobRoot)
      return value
    }
    let value = AudiobookJobManifest(
      schemaVersion: 1, jobID: request.jobID, sourceFingerprint: request.sourceFingerprint,
      title: request.title, language: request.language, voiceID: request.voiceID,
      modelID: request.model.id, modelRevision: request.model.modelRevision,
      format: "m4b-aac-lc-24000-mono", totalUnits: request.units.count,
      destinationBookmark: try? request.destinationURL.deletingLastPathComponent().bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
      destinationName: request.destinationURL.lastPathComponent,
      fragments: [])
    try save(value, at: jobRoot)
    return value
  }

  private static func validate(
    _ manifest: AudiobookJobManifest, request: AudiobookExportRequest, jobRoot: URL
  ) throws {
    guard manifest.schemaVersion == 1, manifest.jobID == request.jobID,
      manifest.sourceFingerprint == request.sourceFingerprint, manifest.voiceID == request.voiceID,
      manifest.modelID == request.model.id,
      manifest.modelRevision == request.model.modelRevision,
      manifest.totalUnits == request.units.count,
      manifest.fragments.count <= request.units.count
    else { throw AudiobookExportError.invalidManifest }
    for (index, fragment) in manifest.fragments.enumerated() {
      let url = jobRoot.appendingPathComponent(fragment.relativePath)
      let expectedStart = manifest.fragments.prefix(index).reduce(0) { $0 + $1.durationSeconds }
      guard request.units[index].unitID == fragment.unitID,
        request.units[index].anchorID == fragment.anchorID,
        abs(fragment.startSeconds - expectedStart) < 0.001,
        (try? sha256(url)) == fragment.sha256
      else { throw AudiobookExportError.missingFragment }
    }
  }

  private static func save(_ manifest: AudiobookJobManifest, at jobRoot: URL) throws {
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: jobRoot.appendingPathComponent("manifest.json"), options: .atomic)
  }

  private static func assemble(
    _ manifest: AudiobookJobManifest, jobRoot: URL, output: URL
  ) async throws {
    let composition = AVMutableComposition()
    guard
      let target = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw AudiobookExportError.encodingFailed }
    var cursor = CMTime.zero
    for fragment in manifest.fragments {
      let asset = AVURLAsset(url: jobRoot.appendingPathComponent(fragment.relativePath))
      guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw AudiobookExportError.missingFragment
      }
      let duration = try await asset.load(.duration)
      try target.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
      cursor = cursor + duration
    }
    guard
      let session = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else { throw AudiobookExportError.encodingFailed }
    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = manifest.title as NSString
    let language = AVMutableMetadataItem()
    language.identifier = .commonIdentifierLanguage
    language.value = manifest.language as NSString
    session.metadata = [title, language]
    do { try await session.export(to: output, as: .m4a) } catch {
      throw AudiobookExportError.encodingFailed
    }
  }

  private static func verify(
    _ url: URL, expectedDuration: Double, expectedChapters: Int
  ) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let extraneousTracks = try await asset.loadTracks(withMediaType: .metadata)
    let chapterTracks = try await asset.loadTracks(withMediaType: .text)
    let chapters = expectedChapters > 0 ? try readChapterSamples(fromFileAt: url) : []
    guard tracks.count == 1, abs(duration - expectedDuration) <= 0.25,
      extraneousTracks.isEmpty, chapterTracks.count == (expectedChapters > 0 ? 1 : 0),
      chapters.count == expectedChapters,
      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
    else { throw AudiobookExportError.verificationFailed }
  }

  /// Reads chapter titles and start times back from the ISO-BMFF boxes `embedChapters`
  /// itself writes. `AVAssetReaderTrackOutput` and `AVAsset.loadChapterMetadataGroups`
  /// both fail to surface legacy QuickTime text-track chapter samples in this toolchain
  /// (verified even against ffmpeg's own reference M4A output), so verification reads the
  /// container directly instead — a small, purpose-built reader for the exact box shape
  /// `embedChapters` produces, not a general-purpose demuxer.
  static func readChapterSamples(fromFileAt url: URL) throws -> [(
    title: String, startSeconds: Double
  )] {
    let data = try Data(contentsOf: url)
    guard let moov = box(data, "moov", in: 0..<data.count) else { return [] }
    var i = moov.lowerBound + 8
    while let trak = box(data, "trak", in: i..<moov.upperBound) {
      defer { i = trak.upperBound }
      guard let mdia = box(data, "mdia", in: trak.lowerBound + 8..<trak.upperBound),
        let hdlr = box(data, "hdlr", in: mdia.lowerBound + 8..<mdia.upperBound),
        hdlr.lowerBound + 8 + 8 + 4 <= data.count,
        data[(hdlr.lowerBound + 16)..<(hdlr.lowerBound + 20)].elementsEqual(Array("text".utf8)),
        let mdhd = box(data, "mdhd", in: mdia.lowerBound + 8..<mdia.upperBound),
        let minf = box(data, "minf", in: mdia.lowerBound + 8..<mdia.upperBound),
        let stbl = box(data, "stbl", in: minf.lowerBound + 8..<minf.upperBound),
        let stts = box(data, "stts", in: stbl.lowerBound + 8..<stbl.upperBound),
        let stsz = box(data, "stsz", in: stbl.lowerBound + 8..<stbl.upperBound),
        let stco = box(data, "stco", in: stbl.lowerBound + 8..<stbl.upperBound)
      else { continue }
      let timescale = readUInt32BE(data, mdhd.lowerBound + 20)
      guard timescale > 0 else { return [] }
      var durations: [(count: Int, delta: Int)] = []
      let sttsCount = Int(readUInt32BE(data, stts.lowerBound + 12))
      for entry in 0..<sttsCount {
        let base = stts.lowerBound + 16 + entry * 8
        durations.append(
          (Int(readUInt32BE(data, base)), Int(readUInt32BE(data, base + 4))))
      }
      let stszCount = Int(readUInt32BE(data, stsz.lowerBound + 16))
      var sizes: [Int] = []
      for entry in 0..<stszCount {
        sizes.append(Int(readUInt32BE(data, stsz.lowerBound + 20 + entry * 4)))
      }
      let chunkOffset = Int(readUInt32BE(data, stco.lowerBound + 16))
      var results: [(title: String, startSeconds: Double)] = []
      var cursor = chunkOffset
      var elapsed = 0
      var durationIndex = 0
      var remainingInRun = durations.first?.count ?? 0
      for size in sizes {
        guard cursor + size <= data.count, size >= 2 else { break }
        let textLength = Int(data[cursor]) << 8 | Int(data[cursor + 1])
        guard size >= 2 + textLength else { break }
        let title = String(decoding: data[(cursor + 2)..<(cursor + 2 + textLength)], as: UTF8.self)
        results.append((title, Double(elapsed) / Double(timescale)))
        cursor += size
        guard durationIndex < durations.count else { continue }
        elapsed += durations[durationIndex].delta
        remainingInRun -= 1
        if remainingInRun <= 0 {
          durationIndex += 1
          remainingInRun = durationIndex < durations.count ? durations[durationIndex].count : 0
        }
      }
      return results
    }
    return []
  }

  private static func box(_ data: Data, _ fourCC: String, in range: Range<Int>) -> Range<Int>? {
    let target = Array(fourCC.utf8)
    var i = range.lowerBound
    while i + 8 <= range.upperBound {
      var size = Int(readUInt32BE(data, i))
      if size == 1 {
        guard i + 16 <= range.upperBound else { return nil }
        size = Int(
          UInt64(readUInt32BE(data, i + 8)) << 32 | UInt64(readUInt32BE(data, i + 12)))
      }
      guard size >= 8, i + size <= range.upperBound else { return nil }
      if data[(i + 4)..<(i + 8)].elementsEqual(target) { return i..<(i + size) }
      i += size
    }
    return nil
  }

  private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }

  /// Classic QuickTime `TextDescription` sample entry for a plain, unstyled chapter text
  /// track (media type `'text'`), byte-for-byte identical to what mature muxers (verified
  /// against ffmpeg's MOV/M4A output) write; constant across every chapter sample.
  private static let chapterTextFormatDescriptionBytes: [UInt8] = [
    0x00, 0x00, 0x00, 0x4f, 0x74, 0x65, 0x78, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x66, 0x74, 0x61, 0x62, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x14, 0x62, 0x74, 0x72, 0x74, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x82, 0x00, 0x00, 0x00, 0x82,
  ]

  private static func chapterTextFormatDescription() throws -> CMFormatDescription {
    var description: CMFormatDescription?
    let status = chapterTextFormatDescriptionBytes.withUnsafeBufferPointer { buffer -> OSStatus in
      CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
        allocator: nil, bigEndianTextDescriptionData: buffer.baseAddress!,
        size: buffer.count, flavor: nil, mediaType: kCMMediaType_Text,
        formatDescriptionOut: &description)
    }
    guard status == noErr, let description else { throw AudiobookExportError.encodingFailed }
    return description
  }

  /// QuickTime text sample: big-endian UTF-8 length prefix, the text, then an `encd` atom
  /// declaring UTF-8 (otherwise readers assume legacy MacRoman).
  private static func chapterSampleData(for title: String) -> Data {
    let text = Array(title.utf8.prefix(Int(UInt16.max)))
    var data = Data()
    withUnsafeBytes(of: UInt16(text.count).bigEndian) { data.append(contentsOf: $0) }
    data.append(contentsOf: text)
    withUnsafeBytes(of: UInt32(12).bigEndian) { data.append(contentsOf: $0) }
    data.append(contentsOf: Array("encd".utf8))
    withUnsafeBytes(of: UInt32(0x100).bigEndian) { data.append(contentsOf: $0) }
    return data
  }

  private static func appendChapterSample(
    title: String, timeRange: CMTimeRange, formatDescription: CMFormatDescription,
    to track: AVMutableMovieTrack
  ) throws {
    let payload = chapterSampleData(for: title)
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: payload.count, flags: 0, blockBufferOut: &blockBuffer)
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
      throw AudiobookExportError.encodingFailed
    }
    status = payload.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0,
        dataLength: payload.count)
    }
    guard status == kCMBlockBufferNoErr else { throw AudiobookExportError.encodingFailed }
    var timing = CMSampleTimingInfo(
      duration: timeRange.duration, presentationTimeStamp: timeRange.start,
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = payload.count
    status = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sampleBuffer else { throw AudiobookExportError.encodingFailed }
    try track.append(sampleBuffer, decodeTime: nil, presentationTime: nil)
  }

  /// Embeds native chapter markers by rewriting the movie header in place; media samples
  /// already written by `assemble` are referenced, never re-encoded or duplicated.
  private static func embedChapters(
    _ chapters: [AudiobookChapterMark], manifest: AudiobookJobManifest, at url: URL
  ) throws -> Int {
    guard !chapters.isEmpty else { return 0 }
    let totalSeconds = manifest.fragments.reduce(0) { $0 + $1.durationSeconds }
    var windows: [(title: String, range: CMTimeRange)] = []
    for (index, chapter) in chapters.enumerated() {
      guard manifest.fragments.indices.contains(chapter.unitIndex) else { continue }
      let start = manifest.fragments[chapter.unitIndex].startSeconds
      let nextIndex = index + 1
      let end =
        nextIndex < chapters.count
          && manifest.fragments.indices.contains(chapters[nextIndex].unitIndex)
        ? manifest.fragments[chapters[nextIndex].unitIndex].startSeconds
        : totalSeconds
      guard end > start else { continue }
      windows.append(
        (
          chapter.title,
          CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
        ))
    }
    guard !windows.isEmpty else { return 0 }
    let movie = AVMutableMovie(url: url)
    movie.defaultMediaDataStorage = AVMediaDataStorage(url: url, options: nil)
    guard let audioTrack = movie.tracks(withMediaType: .audio).first,
      let chapterTrack = movie.addMutableTrack(
        withMediaType: .text, copySettingsFrom: nil, options: nil)
    else { throw AudiobookExportError.encodingFailed }
    chapterTrack.extendedLanguageTag = manifest.language
    let formatDescription = try chapterTextFormatDescription()
    for window in windows {
      try appendChapterSample(
        title: window.title, timeRange: window.range, formatDescription: formatDescription,
        to: chapterTrack)
    }
    audioTrack.addTrackAssociation(to: chapterTrack, type: .chapterList)
    do { try movie.writeHeader(to: url, fileType: .m4a) } catch {
      throw AudiobookExportError.encodingFailed
    }
    return windows.count
  }

  /// Accepts an outline entry only when it advances to a later unit than the previous
  /// accepted entry, so confidence reflects how much the source hierarchy is monotonic.
  /// Mirrors the ratified 0.6 narrability confidence bar used across `lectura-core`.
  public static func chapterMarks(
    outline: [(title: String, pageIndex: Int)], unitPages: [Int]
  ) -> [AudiobookChapterMark] {
    guard !outline.isEmpty, !unitPages.isEmpty else { return [] }
    var accepted: [AudiobookChapterMark] = []
    var lastUnitIndex = -1
    for entry in outline {
      let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty,
        let unitIndex = unitPages.firstIndex(where: { $0 >= entry.pageIndex }),
        unitIndex > lastUnitIndex
      else { continue }
      accepted.append(AudiobookChapterMark(title: title, unitIndex: unitIndex))
      lastUnitIndex = unitIndex
    }
    let confidence = Double(accepted.count) / Double(outline.count)
    return confidence >= 0.6 ? accepted : []
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// QA-gate check (never on the production export path): flags whether the AAC-encoded
  /// segment of the published audiobook introduces clipping or unexpected silence that the
  /// source TTS fragment did not already have.
  public static func detectsClippingRegression(
    sourceWav: URL, finalAsset: URL, timeRange: CMTimeRange
  ) async throws -> Bool {
    let source = try await peakAndRMS(of: sourceWav, timeRange: nil)
    let encoded = try await peakAndRMS(of: finalAsset, timeRange: timeRange)
    let newClipping = encoded.peak >= 0.999 && source.peak < 0.999
    let newSilence = source.rms > 0.01 && encoded.rms < 0.001
    return newClipping || newSilence
  }

  private static func peakAndRMS(of url: URL, timeRange: CMTimeRange?) async throws -> (
    peak: Float, rms: Float
  ) {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      return (0, 0)
    }
    let reader = try AVAssetReader(asset: asset)
    if let timeRange { reader.timeRange = timeRange }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    guard reader.startReading() else { return (0, 0) }
    var peak: Float = 0
    var sumSquares: Double = 0
    var count = 0
    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      var length = 0
      var pointer: UnsafeMutablePointer<Int8>?
      guard
        CMBlockBufferGetDataPointer(
          blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer
      else { continue }
      let sampleCount = length / MemoryLayout<Float>.size
      pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floats in
        for index in 0..<sampleCount {
          let value = abs(floats[index])
          peak = max(peak, value)
          sumSquares += Double(value) * Double(value)
          count += 1
        }
      }
    }
    let rms = count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
    return (peak, rms)
  }
}
