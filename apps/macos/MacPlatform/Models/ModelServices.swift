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
  public typealias FetchArtifact = @Sendable (URL, UInt64) async throws -> URL
  public typealias Progress = @Sendable (ModelInstallationProgress) -> Void

  private struct PackageStamp: Equatable, Sendable {
    struct File: Equatable, Sendable {
      let path: String
      let size: UInt64
      let modifiedAt: TimeInterval
      let fileNumber: UInt64
    }

    let files: [File]
  }

  actor VerificationSession {
    private struct Entry: Sendable {
      let stamp: PackageStamp
      let model: InstalledModel?
    }

    private var entries: [String: Entry] = [:]
    private var runs = 0

    func verifiedPackage(
      manifestData: Data, packageRoot: URL, manifestURL: URL
    ) -> InstalledModel? {
      guard !Task.isCancelled else { return nil }
      guard let manifest = try? ModelPackageInstaller.decodeManifest(manifestData),
        packageRoot.isFileURL,
        let stamp = try? ModelPackageInstaller.packageStamp(
          packageRoot: packageRoot, manifest: manifest)
      else { return nil }
      let manifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
      let key =
        "\(packageRoot.standardizedFileURL.path)|\(manifestURL.standardizedFileURL.path)|\(manifestHash)"
      if let entry = entries[key], entry.stamp == stamp { return entry.model }

      runs += 1
      let model = ModelPackageInstaller.verifiedPackage(
        manifestData: manifestData, packageRoot: packageRoot, manifestURL: manifestURL)
      guard !Task.isCancelled else { return nil }
      guard
        let verifiedStamp = try? ModelPackageInstaller.packageStamp(
          packageRoot: packageRoot, manifest: manifest), verifiedStamp == stamp
      else {
        entries.removeValue(forKey: key)
        return nil
      }
      entries[key] = Entry(stamp: verifiedStamp, model: model)
      return model
    }

    func verificationCount() -> Int { runs }
  }

  private static let verificationSession = VerificationSession()

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

    let downloader: FetchArtifact =
      fetch ?? { url, sizeBytes in
        try await secureDownload(url, sizeBytes: sizeBytes)
      }
    var completed: UInt64 = 0
    do {
      for artifact in manifest.artifacts {
        try Task.checkCancellation()
        let destination = try containedURL(for: artifact.relativePath, root: staging)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = try await downloader(artifact.sourceURL, artifact.sizeBytes)
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

  public static func sessionVerifiedPackage(
    manifestData: Data, packageRoot: URL, manifestURL: URL
  ) async -> InstalledModel? {
    await verificationSession.verifiedPackage(
      manifestData: manifestData, packageRoot: packageRoot, manifestURL: manifestURL)
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
      try Task.checkCancellation()
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

  private static func packageStamp(
    packageRoot: URL, manifest: InstallableModelManifest
  ) throws -> PackageStamp {
    try rejectUnexpectedFiles(in: packageRoot, manifest: manifest)
    let files = try manifest.artifacts.sorted { $0.relativePath < $1.relativePath }.map {
      artifact in
      let url = try containedURL(for: artifact.relativePath, root: packageRoot)
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size >= 0, let modifiedAt = values.contentModificationDate
      else { throw ModelInstallationError.invalidArtifactPath }
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      return PackageStamp.File(
        path: artifact.relativePath, size: UInt64(size),
        modifiedAt: modifiedAt.timeIntervalSinceReferenceDate, fileNumber: fileNumber)
    }
    return PackageStamp(files: files)
  }

  static func secureDownload(
    _ url: URL, sizeBytes: UInt64,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> URL {
    let delegate = BoundedDownloadDelegate(originURL: url, sizeBytes: sizeBytes)
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 120
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.start(session.dataTask(with: request), continuation: continuation)
      }
    } onCancel: {
      delegate.cancel()
    }
  }
}

class PinnedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

private final class BoundedDownloadDelegate: PinnedRedirectDelegate, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let sizeBytes: UInt64
  private let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)
  private let lock = NSLock()
  private var handle: FileHandle?
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<URL, Error>?
  private var received: UInt64 = 0
  private var cancelledByCaller = false

  init(originURL: URL, sizeBytes: UInt64) {
    self.sizeBytes = sizeBytes
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    handle = try? FileHandle(forWritingTo: temporary)
    super.init(originURL: originURL)
  }

  func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<URL, Error>) {
    lock.lock()
    guard handle != nil else {
      lock.unlock()
      try? FileManager.default.removeItem(at: temporary)
      continuation.resume(throwing: ModelInstallationError.downloadFailed)
      return
    }
    self.task = task
    self.continuation = continuation
    let cancelledByCaller = cancelledByCaller
    lock.unlock()
    if cancelledByCaller {
      complete(.failure(CancellationError()))
    } else {
      task.resume()
    }
  }

  func cancel() {
    lock.lock()
    cancelledByCaller = true
    let task = task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      acceptsFinalURL(http.url)
    else {
      completionHandler(.cancel)
      complete(.failure(ModelInstallationError.downloadFailed))
      return
    }
    if response.expectedContentLength >= 0,
      UInt64(response.expectedContentLength) > sizeBytes
    {
      completionHandler(.cancel)
      complete(.failure(ModelInstallationError.sizeMismatch))
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard continuation != nil else {
      lock.unlock()
      return
    }
    guard UInt64(data.count) <= sizeBytes - received else {
      lock.unlock()
      dataTask.cancel()
      complete(.failure(ModelInstallationError.sizeMismatch))
      return
    }
    do {
      try handle?.write(contentsOf: data)
      received += UInt64(data.count)
      lock.unlock()
    } catch {
      lock.unlock()
      dataTask.cancel()
      complete(.failure(ModelInstallationError.downloadFailed))
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    lock.lock()
    let cancelledByCaller = cancelledByCaller
    lock.unlock()
    if cancelledByCaller {
      complete(.failure(CancellationError()))
    } else if error != nil {
      complete(.failure(ModelInstallationError.downloadFailed))
    } else {
      complete(.success(temporary))
    }
  }

  private func complete(_ result: Result<URL, Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    let handle = handle
    self.handle = nil
    lock.unlock()
    try? handle?.close()
    if case .failure = result { try? FileManager.default.removeItem(at: temporary) }
    continuation.resume(with: result)
  }
}

public enum ModelServices {
  public static func phoneticDataRoot(
    engineURL: URL, bundledEngineURL: URL, bundledDataRoot: URL
  ) -> URL {
    if engineURL.standardizedFileURL == bundledEngineURL.standardizedFileURL {
      return bundledDataRoot
    }
    return engineURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("share", isDirectory: true)
  }

  public static func synthesize(
    _ request: TTSSynthesisRequest,
    runtimeURL: URL,
    modelURL: URL,
    workRoot: URL? = nil
  ) throws -> TTSSynthesisResult {
    try synthesize(
      request, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot,
      processOwner: nil)
  }

  public static func synthesizeCancellable(
    _ request: TTSSynthesisRequest,
    runtimeURL: URL,
    modelURL: URL,
    workRoot: URL
  ) async throws -> TTSSynthesisResult {
    let processOwner = CancellableProcessOwner()
    return try await withTaskCancellationHandler {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try synthesize(
            request, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot,
            processOwner: processOwner)
        }.value
        try Task.checkCancellation()
        return result
      } catch {
        if Task.isCancelled {
          try? FileManager.default.removeItem(at: workRoot)
          throw CancellationError()
        }
        throw error
      }
    } onCancel: {
      processOwner.cancel()
    }
  }

  private static func synthesize(
    _ request: TTSSynthesisRequest,
    runtimeURL: URL,
    modelURL: URL,
    workRoot: URL?,
    processOwner: CancellableProcessOwner?
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
      let scalarLimit = request.rawIPA ? 510 : 400
      for (segmentIndex, text) in chunks(unit.text, limit: scalarLimit).enumerated() {
        let fragmentURL = root.appendingPathComponent(
          "fragment-\(segments.count).wav", isDirectory: false)
        let elapsedMs = try runRuntime(
          request: request, runtimeURL: runtimeURL, modelURL: modelURL,
          text: text, outputURL: fragmentURL, processOwner: processOwner)
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
    try processOwner?.checkCancellation()
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
    try? phonemize(
      text, language: language, engineURL: engineURL, dataRoot: dataRoot, processOwner: nil)
  }

  public static func phonemizeCancellable(
    _ text: String, language: String, engineURL: URL, dataRoot: URL
  ) async throws -> String? {
    let processOwner = CancellableProcessOwner()
    return try await withTaskCancellationHandler {
      let value = try await Task.detached(priority: .userInitiated) {
        try phonemize(
          text, language: language, engineURL: engineURL, dataRoot: dataRoot,
          processOwner: processOwner)
      }.value
      try Task.checkCancellation()
      return value
    } onCancel: {
      processOwner.cancel()
    }
  }

  private static func phonemize(
    _ text: String, language: String, engineURL: URL, dataRoot: URL,
    processOwner: CancellableProcessOwner?
  ) throws -> String? {
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
    do {
      try processOwner?.register(process)
    } catch {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      throw error
    }
    defer { processOwner?.unregister(process) }
    input.fileHandleForWriting.write(Data("\(text)\n".utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try processOwner?.checkCancellation()
    guard process.terminationStatus == 0 else {
      runtimeLog.error("espeak.failed status=\(process.terminationStatus, privacy: .public)")
      return nil
    }
    let ipa = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ipa.isEmpty ? nil : ipa
  }

  static func chunks(_ text: String, limit: Int = 400) -> [String] {
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let scalars = Array(normalized.unicodeScalars)
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
    outputURL: URL,
    processOwner: CancellableProcessOwner?
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
    do {
      try processOwner?.register(process)
    } catch {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      throw error
    }
    defer { processOwner?.unregister(process) }
    let stderrData = diagnostics.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try processOwner?.checkCancellation()
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

private final class CancellableProcessOwner: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  func register(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    self.process = process
  }

  func unregister(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if self.process === process { self.process = nil }
  }

  func checkCancellation() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let process = process
    lock.unlock()
    if process?.isRunning == true { process?.terminate() }
  }
}
