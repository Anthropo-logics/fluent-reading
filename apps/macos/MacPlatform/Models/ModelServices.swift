import AVFoundation
import CryptoKit
import Foundation
import OSLog

let runtimeLog = Logger(subsystem: "com.lecturafluida.app", category: "runtime")

public struct TTSUnitRequest: Codable, Equatable, Sendable {
  public let unitId: String
  public let text: String

  public init(unitId: String, text: String) {
    self.unitId = unitId
    self.text = text
  }
}

public struct TTSSynthesisRequest: Codable, Equatable, Sendable {
  public let modelId: String
  public let modelRevision: String
  public let runtimeId: String
  public let runtimeVersion: String
  public let voiceId: String
  public let language: String
  public let rawIPA: Bool
  public let units: [TTSUnitRequest]

  public init(
    modelId: String, modelRevision: String, runtimeId: String, runtimeVersion: String,
    voiceId: String, language: String, rawIPA: Bool, units: [TTSUnitRequest]
  ) {
    self.modelId = modelId
    self.modelRevision = modelRevision
    self.runtimeId = runtimeId
    self.runtimeVersion = runtimeVersion
    self.voiceId = voiceId
    self.language = language
    self.rawIPA = rawIPA
    self.units = units
  }
}

public struct NarrationSegmentResult: Codable, Equatable, Sendable {
  public let unitId: String
  public let segmentIndex: UInt32
  public let unitSampleOffset: UInt64
  public let sampleCount: UInt64
  public let sampleRateHz: UInt32
  public let elapsedMs: UInt64
  public let artifactHash: String?
  public let modelRevision: String
  public let voiceId: String
}

public struct TTSSynthesisResult: Codable, Equatable, Sendable {
  public let modelId: String
  public let modelRevision: String
  public let runtimeId: String
  public let runtimeVersion: String
  public let voiceId: String
  public let language: String
  public let audioPath: String
  public let segments: [NarrationSegmentResult]
  public let omittedUnitIds: [String]
}

public enum ModelServiceError: Error, Equatable, Sendable {
  case invalidPair
  case runtimeMissing
  case modelMissing
  case synthesisFailed
  case outputInvalid
}

public struct InstallableModelArtifact: Codable, Equatable, Sendable {
  public let relativePath: String
  public let role: String
  public let sourceURL: URL
  public let publisher: String
  public let format: String
  public let quantization: String
  public let sizeBytes: UInt64
  public let sha256Hex: String

  enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case role
    case sourceURL = "source_url"
    case publisher, format, quantization
    case sizeBytes = "size_bytes"
    case sha256Hex = "sha256_hex"
  }
}

public struct InstallableModelManifest: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let id: String
  public let modelRevision: String
  public let artifactRevision: String
  public let purpose: String
  public let authors: [String]
  public let licenseId: String
  public let usageRestrictions: [String]
  public let languages: [String]
  public let voices: [String]
  public let runtimeId: String
  public let runtimeVersion: String
  public let distributionStatus: String
  public let artifacts: [InstallableModelArtifact]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id
    case modelRevision = "model_revision"
    case artifactRevision = "artifact_revision"
    case purpose, authors
    case licenseId = "license_id"
    case usageRestrictions = "usage_restrictions"
    case languages, voices
    case runtimeId = "runtime_id"
    case runtimeVersion = "runtime_version"
    case distributionStatus = "distribution_status"
    case artifacts
  }

  public var totalSizeBytes: UInt64 { artifacts.reduce(0) { $0 + $1.sizeBytes } }

  public func voices(for language: String) -> [String] {
    let role = "voice_embedding_\(language)"
    return artifacts.filter { $0.role == role }.compactMap {
      URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent
    }.filter { voices.contains($0) }
  }

  /// Mirrors the ratified 6-pair contract in `SUPPORTED_TRANSLATION_DIRECTIONS`
  /// (crates/lectura-core/src/models.rs).
  static let translationDirectionPairs = [
    ("es", "en"), ("es", "pt"), ("en", "es"), ("en", "pt"), ("pt", "es"), ("pt", "en"),
  ]

  public var translationDirections: [String] {
    Self.translationDirectionPairs
      .filter { languages.contains($0.0) && languages.contains($0.1) }
      .map { "\($0.0.uppercased())→\($0.1.uppercased())" }
  }

  public func translationTargets(from source: String) -> [String] {
    guard !source.isEmpty, languages.contains(source) else { return [] }
    return Self.translationDirectionPairs
      .filter { $0.0 == source && languages.contains($0.1) }
      .map(\.1)
  }
}

public enum ModelInstallationError: Error, Equatable, Sendable {
  case invalidManifest
  case incompatibleRuntime
  case unauthorizedDestination
  case invalidArtifactPath
  case unexpectedArtifact
  case downloadFailed
  case insufficientSpace
  case sizeMismatch
  case hashMismatch
  case cancelled
}

public struct ModelInstallationProgress: Equatable, Sendable {
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let artifactPath: String
}

public struct InstalledModel: Equatable, Sendable {
  public let id: String
  public let directory: URL
  public let manifestURL: URL
  public let totalSizeBytes: UInt64
}

public enum ModelPackageInstaller {
  public typealias FetchArtifact = @Sendable (URL) async throws -> URL
  public typealias Progress = @Sendable (ModelInstallationProgress) -> Void

  /// Parejas propósito/runtime exactas admitidas para descarga. Un `purpose` nuevo o un
  /// runtime distinto para uno ya admitido exige extender esta lista explícitamente — nunca
  /// aceptar "cualquier runtime" para un propósito conocido.
  private static let supportedPurposeRuntimePairs: Set<[String]> = [
    ["tts", "mlx-audio-swift", "v0.1.3"],
    ["translation", "mlx-swift-lm", "gemma3"],
  ]

  private static func validVoices(purpose: String, voices: [String]) -> Bool {
    switch purpose {
    case "tts": return !voices.isEmpty
    case "translation": return voices.isEmpty
    default: return false
    }
  }

  public static func decodeManifest(_ data: Data) throws -> InstallableModelManifest {
    let manifest: InstallableModelManifest
    do { manifest = try JSONDecoder().decode(InstallableModelManifest.self, from: data) } catch {
      throw ModelInstallationError.invalidManifest
    }
    guard manifest.schemaVersion == 1,
      supportedPurposeRuntimePairs.contains([
        manifest.purpose, manifest.runtimeId, manifest.runtimeVersion,
      ]),
      manifest.distributionStatus != "laboratory", !manifest.id.isEmpty,
      !manifest.authors.isEmpty, !manifest.languages.isEmpty,
      validVoices(purpose: manifest.purpose, voices: manifest.voices),
      !manifest.artifacts.isEmpty, manifest.artifacts.count <= 32,
      Set(manifest.artifacts.map(\.relativePath)).count == manifest.artifacts.count,
      manifest.totalSizeBytes > 0
    else { throw ModelInstallationError.invalidManifest }
    for artifact in manifest.artifacts {
      try validate(artifact, revision: manifest.artifactRevision)
    }
    return manifest
  }

  public static func install(
    manifestData: Data,
    containerRoot: URL,
    fetch: FetchArtifact? = nil,
    progress: @escaping Progress = { _ in }
  ) async throws -> InstalledModel {
    let manifest = try decodeManifest(manifestData)
    guard containerRoot.isFileURL else { throw ModelInstallationError.unauthorizedDestination }
    if Task.isCancelled { throw ModelInstallationError.cancelled }
    let fileManager = FileManager.default
    let managedRoot = containerRoot.standardizedFileURL
    if let capacity = try? managedRoot.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ]).volumeAvailableCapacityForImportantUsage,
      capacity >= 0, UInt64(capacity) < manifest.totalSizeBytes
    {
      throw ModelInstallationError.insufficientSpace
    }
    let incomingRoot = managedRoot.appendingPathComponent("incoming", isDirectory: true)
    let installedRoot = managedRoot.appendingPathComponent("installed", isDirectory: true)
    let manifestsRoot = managedRoot.appendingPathComponent("manifests", isDirectory: true)
    try fileManager.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: installedRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: manifestsRoot, withIntermediateDirectories: true)
    let staging = incomingRoot.appendingPathComponent(
      "\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    var published = false
    defer { if !published { try? fileManager.removeItem(at: staging) } }

    let downloader = fetch ?? secureDownload
    var completed: UInt64 = 0
    do {
      for artifact in manifest.artifacts {
        try Task.checkCancellation()
        let destination = try containedURL(for: artifact.relativePath, root: staging)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = try await downloader(artifact.sourceURL)
        defer { try? fileManager.removeItem(at: temporary) }
        let partial = destination.appendingPathExtension("part")
        try fileManager.copyItem(at: temporary, to: partial)
        try verify(partial, artifact: artifact)
        try fileManager.moveItem(at: partial, to: destination)
        completed += artifact.sizeBytes
        progress(
          ModelInstallationProgress(
            completedBytes: completed, totalBytes: manifest.totalSizeBytes,
            artifactPath: artifact.relativePath))
      }
      try rejectUnexpectedFiles(in: staging, manifest: manifest)
    } catch is CancellationError {
      throw ModelInstallationError.cancelled
    } catch let error as ModelInstallationError {
      throw error
    } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
      throw ModelInstallationError.insufficientSpace
    } catch {
      throw ModelInstallationError.downloadFailed
    }

    let installed = installedRoot.appendingPathComponent(manifest.id, isDirectory: true)
    guard installed.deletingLastPathComponent().standardizedFileURL == installedRoot else {
      throw ModelInstallationError.unauthorizedDestination
    }
    if fileManager.fileExists(atPath: installed.path) {
      throw ModelInstallationError.unauthorizedDestination
    }
    let manifestURL = manifestsRoot.appendingPathComponent("\(manifest.id).json")
    try manifestData.write(to: manifestURL, options: .atomic)
    do { try fileManager.moveItem(at: staging, to: installed) } catch {
      try? fileManager.removeItem(at: manifestURL)
      throw ModelInstallationError.unauthorizedDestination
    }
    published = true
    return InstalledModel(
      id: manifest.id, directory: installed, manifestURL: manifestURL,
      totalSizeBytes: manifest.totalSizeBytes)
  }

  public static func installedModel(id: String, containerRoot: URL) -> InstalledModel? {
    let directory = containerRoot.appendingPathComponent("installed/\(id)", isDirectory: true)
    let manifestURL = containerRoot.appendingPathComponent("manifests/\(id).json")
    guard FileManager.default.fileExists(atPath: directory.path),
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? decodeManifest(data), manifest.id == id
    else { return nil }
    return InstalledModel(
      id: id, directory: directory, manifestURL: manifestURL,
      totalSizeBytes: manifest.totalSizeBytes)
  }

  public static func verifiedPackage(
    manifestData: Data, packageRoot: URL, manifestURL: URL
  ) -> InstalledModel? {
    guard let manifest = try? decodeManifest(manifestData), packageRoot.isFileURL else {
      return nil
    }
    do {
      for artifact in manifest.artifacts {
        try verify(
          try containedURL(for: artifact.relativePath, root: packageRoot), artifact: artifact)
      }
      try rejectUnexpectedFiles(in: packageRoot, manifest: manifest)
      return InstalledModel(
        id: manifest.id, directory: packageRoot, manifestURL: manifestURL,
        totalSizeBytes: manifest.totalSizeBytes)
    } catch {
      return nil
    }
  }

  private static func validate(_ artifact: InstallableModelArtifact, revision: String) throws {
    let path = artifact.relativePath as NSString
    let extensionName = path.pathExtension.lowercased()
    let forbidden = ["zip", "tar", "gz", "tgz", "7z", "dylib", "so", "dll", "exe", "sh", "py"]
    guard artifact.relativePath.hasPrefix("data/"), !artifact.relativePath.contains("//"),
      !artifact.relativePath.split(separator: "/").contains(".."),
      !artifact.relativePath.hasSuffix("/"), !forbidden.contains(extensionName),
      artifact.sourceURL.scheme == "https", artifact.sourceURL.user == nil,
      artifact.sourceURL.fragment == nil, artifact.sourceURL.absoluteString.contains(revision),
      artifact.sizeBytes > 0, artifact.sha256Hex.count == 64,
      artifact.sha256Hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { throw ModelInstallationError.invalidArtifactPath }
  }

  private static func containedURL(for path: String, root: URL) throws -> URL {
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else {
      throw ModelInstallationError.invalidArtifactPath
    }
    return candidate
  }

  private static func verify(_ url: URL, artifact: InstallableModelArtifact) throws {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ModelInstallationError.invalidArtifactPath
    }
    guard UInt64(values.fileSize ?? -1) == artifact.sizeBytes else {
      throw ModelInstallationError.sizeMismatch
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == artifact.sha256Hex else { throw ModelInstallationError.hashMismatch }
  }

  private static func rejectUnexpectedFiles(
    in directory: URL, manifest: InstallableModelManifest
  ) throws {
    let expected = Set(manifest.artifacts.map(\.relativePath))
    let canonicalDirectory = directory.resolvingSymlinksInPath()
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { throw ModelInstallationError.unexpectedArtifact }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { throw ModelInstallationError.unexpectedArtifact }
      guard values.isRegularFile == true else { continue }
      let canonical = url.resolvingSymlinksInPath()
      let relative = canonical.pathComponents.dropFirst(canonicalDirectory.pathComponents.count)
        .joined(separator: "/")
      guard expected.contains(relative) else { throw ModelInstallationError.unexpectedArtifact }
    }
  }

  private static func secureDownload(_ url: URL) async throws -> URL {
    let delegate = PinnedRedirectDelegate(originURL: url)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 120
    let (temporary, response) = try await session.download(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      delegate.acceptsFinalURL(http.url)
    else { throw ModelInstallationError.downloadFailed }
    let retained = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.moveItem(at: temporary, to: retained)
    return retained
  }
}

final class PinnedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let host: String?
  private let revision: String?

  init(originURL: URL) {
    host = originURL.host
    revision = originURL.pathComponents.first {
      $0.count == 40 && $0.allSatisfy(\.isHexDigit)
    }
  }

  func acceptsFinalURL(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.host == host, let revision else { return false }
    return url.path.contains(revision)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(acceptsFinalURL(request.url) ? request : nil) }
}

public enum ModelServices {
  public static func synthesize(
    _ request: TTSSynthesisRequest,
    runtimeURL: URL,
    modelURL: URL,
    workRoot: URL? = nil
  ) throws -> TTSSynthesisResult {
    try validate(request)
    guard runtimeURL.isFileURL, FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
      throw ModelServiceError.runtimeMissing
    }
    var isDirectory: ObjCBool = false
    guard modelURL.isFileURL,
      FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ModelServiceError.modelMissing }

    let root =
      workRoot
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("lectura-tts-\(UUID().uuidString)", isDirectory: true)
    guard root.isFileURL else { throw ModelServiceError.outputInvalid }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("narration.wav")
    var completed = false
    defer {
      if !completed { try? FileManager.default.removeItem(at: root) }
    }

    var writer: AVAudioFile?
    var expectedFormat: AVAudioFormat?
    var segments = [NarrationSegmentResult]()
    for unit in request.units {
      var unitOffset: UInt64 = 0
      for (segmentIndex, text) in chunks(unit.text).enumerated() {
        let fragmentURL = root.appendingPathComponent(
          "fragment-\(segments.count).wav", isDirectory: false)
        let elapsedMs = try runRuntime(
          request: request, runtimeURL: runtimeURL, modelURL: modelURL,
          text: text, outputURL: fragmentURL)
        let reader = try AVAudioFile(forReading: fragmentURL)
        guard reader.length > 0, reader.processingFormat.sampleRate >= 8_000,
          reader.processingFormat.channelCount > 0
        else { throw ModelServiceError.outputInvalid }
        if let expectedFormat {
          guard expectedFormat.sampleRate == reader.processingFormat.sampleRate,
            expectedFormat.channelCount == reader.processingFormat.channelCount
          else { throw ModelServiceError.outputInvalid }
        } else {
          expectedFormat = reader.processingFormat
          writer = try AVAudioFile(forWriting: outputURL, settings: reader.fileFormat.settings)
        }
        guard let writer else { throw ModelServiceError.outputInvalid }
        let sampleCount = UInt64(reader.length)
        try append(reader, to: writer)
        let hash = SHA256.hash(data: try Data(contentsOf: fragmentURL))
          .map { String(format: "%02x", $0) }.joined()
        segments.append(
          NarrationSegmentResult(
            unitId: unit.unitId,
            segmentIndex: UInt32(segmentIndex),
            unitSampleOffset: unitOffset,
            sampleCount: sampleCount,
            sampleRateHz: UInt32(reader.processingFormat.sampleRate.rounded()),
            elapsedMs: elapsedMs,
            artifactHash: hash,
            modelRevision: request.modelRevision,
            voiceId: request.voiceId
          ))
        unitOffset += sampleCount
        try FileManager.default.removeItem(at: fragmentURL)
      }
    }
    guard !segments.isEmpty, FileManager.default.fileExists(atPath: outputURL.path) else {
      throw ModelServiceError.outputInvalid
    }
    completed = true
    return TTSSynthesisResult(
      modelId: request.modelId,
      modelRevision: request.modelRevision,
      runtimeId: request.runtimeId,
      runtimeVersion: request.runtimeVersion,
      voiceId: request.voiceId,
      language: request.language,
      audioPath: outputURL.path,
      segments: segments,
      omittedUnitIds: []
    )
  }

  private static func validate(_ request: TTSSynthesisRequest) throws {
    let pair: Bool
    switch request.modelId {
    case "kokoro-82m-4bit":
      pair =
        request.modelRevision == "e4468a460f6f70b9125a003e0adb1ab7d4904bbd"
        && ((request.language == "es" && request.voiceId == "ef_dora")
          || (request.language == "en" && request.voiceId == "af_heart")
          || (request.language == "pt" && request.voiceId == "pf_dora"))
    case "qwen3-tts-0.6b-customvoice-4bit":
      pair =
        request.modelRevision == "93076f032b285167cbb63aeba1e37ec918968bbb"
        && ["es", "en", "pt"].contains(request.language)
        && request.voiceId.lowercased() == "ryan"
    case "qwen3-tts-1.7b-customvoice-4bit":
      pair =
        request.modelRevision == "f35faf19b0cc2160865af64ecf0f22f83d335135"
        && ["es", "en", "pt"].contains(request.language)
        && request.voiceId.lowercased() == "ryan"
    default: pair = false
    }
    if request.rawIPA && request.modelId != "kokoro-82m-4bit" {
      throw ModelServiceError.invalidPair
    }
    guard pair, request.runtimeId == "mlx-audio-swift", request.runtimeVersion == "v0.1.3",
      !request.units.isEmpty, request.units.count <= 64,
      Set(request.units.map(\.unitId)).count == request.units.count,
      request.units.allSatisfy({
        !$0.unitId.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw ModelServiceError.invalidPair }
  }

  /// Kokoro's built-in grapheme-to-phoneme step silently drops Spanish numerals and acronyms —
  /// "art. 270" is spoken as "art." — so text is phonemised with eSpeak NG first, exactly like the
  /// harness that validated narration quality. Returns nil when the engine is unavailable, letting
  /// the caller fall back to raw text rather than losing narration altogether.
  public static func phonemize(_ text: String, language: String, engineURL: URL, dataRoot: URL)
    -> String?
  {
    guard FileManager.default.isExecutableFile(atPath: engineURL.path) else { return nil }
    let process = Process()
    process.executableURL = engineURL
    process.arguments = ["--path=\(dataRoot.path)", "-q", "--ipa=3", "-v", language, "--stdin"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
      runtimeLog.error("espeak.spawn_failed \(error.localizedDescription, privacy: .public)")
      return nil
    }
    input.fileHandleForWriting.write(Data("\(text)\n".utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      runtimeLog.error("espeak.failed status=\(process.terminationStatus, privacy: .public)")
      return nil
    }
    let ipa = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ipa.isEmpty ? nil : ipa
  }

  static func chunks(_ text: String) -> [String] {
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let scalars = Array(normalized.unicodeScalars)
    let limit = 510
    let strong = CharacterSet(charactersIn: ".?!")
    let medium = CharacterSet(charactersIn: ";:—")
    let comma = CharacterSet(charactersIn: ",")
    let whitespace = CharacterSet.whitespacesAndNewlines
    let numericPunctuation = CharacterSet(charactersIn: ".,:")
    let digits = CharacterSet.decimalDigits
    var result = [String]()
    var start = 0
    while start < scalars.count {
      let ceiling = min(start + limit, scalars.count)
      var end = ceiling
      if ceiling < scalars.count {
        let last = { (set: CharacterSet) in
          (start..<ceiling).reversed().first(where: { index in
            guard set.contains(scalars[index]) else { return false }
            return !numericPunctuation.contains(scalars[index])
              || index == 0 || index + 1 == scalars.count
              || !digits.contains(scalars[index - 1]) || !digits.contains(scalars[index + 1])
          }).map { $0 + 1 }
        }
        end = last(strong) ?? last(medium) ?? last(comma) ?? last(whitespace) ?? ceiling
      }
      let fragment = String(String.UnicodeScalarView(scalars[start..<end]))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !fragment.isEmpty { result.append(fragment) }
      start = end
      while start < scalars.count, whitespace.contains(scalars[start]) {
        start += 1
      }
    }
    return result
  }

  private static func runRuntime(
    request: TTSSynthesisRequest,
    runtimeURL: URL,
    modelURL: URL,
    text: String,
    outputURL: URL
  ) throws -> UInt64 {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let process = Process()
    process.executableURL = runtimeURL
    process.arguments = [
      "--model", modelURL.path,
      "--voice", request.voiceId,
      "--language", request.language,
      "--text", text,
      "--output", outputURL.path,
    ]
    if request.rawIPA { process.arguments?.append("--raw-ipa") }
    process.standardOutput = FileHandle.nullDevice
    // Discarding the engine's stderr turned every failure into an opaque "audio unavailable" with
    // no way to tell a missing model from a crash, so it is captured and logged instead.
    let diagnostics = Pipe()
    process.standardError = diagnostics
    do {
      try process.run()
    } catch {
      runtimeLog.error("tts.spawn_failed \(error.localizedDescription, privacy: .public)")
      throw ModelServiceError.synthesisFailed
    }
    let stderrData = diagnostics.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path)
    else {
      let detail = String(decoding: stderrData.suffix(2_000), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      runtimeLog.error(
        """
        tts.failed status=\(process.terminationStatus, privacy: .public) \
        output_exists=\(FileManager.default.fileExists(atPath: outputURL.path), privacy: .public) \
        stderr=\(detail, privacy: .public)
        """)
      throw ModelServiceError.synthesisFailed
    }
    return max(1, (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
  }

  private static func append(_ reader: AVAudioFile, to writer: AVAudioFile) throws {
    let capacity: AVAudioFrameCount = 16_384
    guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: capacity)
    else { throw ModelServiceError.outputInvalid }
    while reader.framePosition < reader.length {
      buffer.frameLength = 0
      try reader.read(into: buffer, frameCount: capacity)
      guard buffer.frameLength > 0 else { break }
      try writer.write(from: buffer)
    }
  }
}
