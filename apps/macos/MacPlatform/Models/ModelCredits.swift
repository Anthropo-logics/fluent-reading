import Foundation

/// Where the reader keeps model packages. The location is the reader's choice — today an external
/// SSD for the owner of this project — so nothing here may assume a fixed path. Resolution lives in
/// one place because both the reader window and the credits panel need the same answer, and two
/// copies of a bookmark-resolution rule drift apart silently.
public enum ModelStorage {
  public static let bookmarkKey = "model-storage-bookmark"
  public static let environmentKey = "LECTURA_MODEL_ROOT"

  public struct Resolved: Equatable, Sendable {
    public let url: URL
    /// False when the folder came from the development environment override, which carries no
    /// security scope to start and no bookmark to refresh.
    public let isSecurityScoped: Bool
    public let isStale: Bool
  }

  /// Resolves the chosen folder without starting security-scoped access: whoever owns the lifetime
  /// of that access decides when to start and stop it.
  public static func resolve(defaults: UserDefaults = .standard) -> Resolved? {
    // The environment override is a development convenience, so it only wins when it points at a
    // folder that actually exists. Otherwise a stale or mistyped value would silently override the
    // folder the reader chose by hand, leaving narration unable to find its engine.
    if let path = ProcessInfo.processInfo.environment[environmentKey],
      FileManager.default.fileExists(atPath: path)
    {
      return Resolved(
        url: URL(fileURLWithPath: path, isDirectory: true), isSecurityScoped: false, isStale: false)
    }
    guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data, options: .withSecurityScope,
        relativeTo: nil, bookmarkDataIsStale: &stale)
    else { return nil }
    return Resolved(url: url, isSecurityScoped: true, isStale: stale)
  }

  /// Managed model container inside the chosen folder, falling back to Application Support when the
  /// reader has not chosen one yet.
  public static func containerRoot(storageRoot: URL?) -> URL {
    (storageRoot
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
      .appendingPathComponent("LecturaFluida/Models", isDirectory: true)
  }
}

/// One third-party model shown in the About panel (Story 6.4, AC2).
public struct ModelCredit: Equatable, Sendable, Identifiable {
  public let id: String
  public let purpose: String
  public let authors: [String]
  public let licenseId: String
  public let modelRevision: String
  public let usageRestrictions: [String]
  /// Whether a package for this manifest exists on this device right now.
  public let isInstalled: Bool

  public init(manifest: InstallableModelManifest, isInstalled: Bool) {
    id = manifest.id
    purpose = manifest.purpose
    authors = manifest.authors
    licenseId = manifest.licenseId
    modelRevision = manifest.modelRevision
    usageRestrictions = manifest.usageRestrictions
    self.isInstalled = isInstalled
  }

  fileprivate init(layout: LayoutModelManifest, isInstalled: Bool) {
    id = layout.id
    purpose = layout.purpose
    authors = layout.authors
    licenseId = layout.licenseId
    modelRevision = layout.modelRevision
    usageRestrictions = layout.usageRestrictions
    self.isInstalled = isInstalled
  }
}

private struct LayoutModelManifest: Decodable {
  struct File: Decodable {
    let relativePath: String
    let sizeBytes: UInt64
    let sha256Hex: String

    enum CodingKeys: String, CodingKey {
      case relativePath = "relative_path"
      case sizeBytes = "size_bytes"
      case sha256Hex = "sha256_hex"
    }
  }

  let schemaVersion: UInt32
  let id: String
  let modelRevision: String
  let sourceRevision: String
  let sourceWeightsSHA256: String
  let purpose: String
  let authors: [String]
  let licenseId: String
  let usageRestrictions: [String]
  let runtimeId: String
  let quantization: String
  let bundledDirectory: String
  let files: [File]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id
    case modelRevision = "model_revision"
    case sourceRevision = "source_revision"
    case sourceWeightsSHA256 = "source_weights_sha256"
    case purpose, authors
    case licenseId = "license_id"
    case usageRestrictions = "usage_restrictions"
    case runtimeId = "runtime_id"
    case quantization
    case bundledDirectory = "bundled_directory"
    case files
  }

  var isValid: Bool {
    schemaVersion == 1 && id == "pp-doclayout-v3-coreml"
      && modelRevision == sourceRevision && sourceRevision.count == 40
      && sourceWeightsSHA256.count == 64 && purpose == "document_layout"
      && !authors.isEmpty && licenseId == "Apache-2.0" && runtimeId == "Core ML"
      && quantization == "fp32" && bundledDirectory == "PPDocLayoutV3-fp32.mlmodelc"
      && files.count == 4 && Set(files.map(\.relativePath)).count == 4
      && files.allSatisfy {
        !$0.relativePath.isEmpty && $0.sizeBytes > 0 && $0.sha256Hex.count == 64
      }
  }
}

/// Credits built from the manifests themselves — the ones shipped inside the bundle and the ones
/// the installer wrote into the reader's model store. A hand-kept list would state a licence the
/// installer never verified, which is exactly what AC2 forbids.
public enum ModelCredits {
  public static func credits(bundle: Bundle = .main, defaults: UserDefaults = .standard)
    -> [ModelCredit]
  {
    let storageRoot = ModelStorage.resolve(defaults: defaults)?.url
    let containerRoot = ModelStorage.containerRoot(storageRoot: storageRoot)
    let bundled = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
    let installed =
      (try? FileManager.default.contentsOfDirectory(
        at: containerRoot.appendingPathComponent("manifests", isDirectory: true),
        includingPropertiesForKeys: nil)) ?? []
    return credits(
      manifestURLs: bundled + installed, storageRoot: storageRoot, containerRoot: containerRoot)
  }

  /// Decodes every candidate manifest and keeps the ones that pass the same validation the
  /// installer applies. Anything else — a fixture, an unrelated JSON resource — is simply not a
  /// model and is dropped without complaint.
  public static func credits(manifestURLs: [URL], storageRoot: URL?, containerRoot: URL)
    -> [ModelCredit]
  {
    var byID = [String: ModelCredit]()
    for url in manifestURLs {
      guard url.pathExtension.lowercased() == "json",
        let data = try? Data(contentsOf: url)
      else { continue }
      if let manifest = try? ModelPackageInstaller.decodeManifest(data), byID[manifest.id] == nil {
        byID[manifest.id] = ModelCredit(
          manifest: manifest,
          isInstalled: isPackagePresent(
            id: manifest.id, storageRoot: storageRoot, containerRoot: containerRoot))
      } else if let layout = try? JSONDecoder().decode(LayoutModelManifest.self, from: data),
        layout.isValid, byID[layout.id] == nil
      {
        byID[layout.id] = ModelCredit(
          layout: layout,
          isInstalled: isDirectory(
            url.deletingLastPathComponent().appendingPathComponent(
              layout.bundledDirectory, isDirectory: true)))
      }
    }
    // Grouped by purpose, alphabetical inside each group: a stable order keeps the panel from
    // reshuffling between launches, which a dictionary's own order would do.
    return byID.values.sorted {
      ($0.purpose, $0.id) < ($1.purpose, $1.id)
    }
  }

  /// Presence, not integrity: re-hashing several gigabytes of weights every time the reader opens
  /// the About panel would freeze it. Integrity is verified where it matters, before synthesis.
  private static func isPackagePresent(id: String, storageRoot: URL?, containerRoot: URL) -> Bool {
    let candidates = [
      containerRoot.appendingPathComponent("installed/\(id)", isDirectory: true),
      storageRoot?.appendingPathComponent("verified-packages/\(id)", isDirectory: true),
    ].compactMap { $0 }
    return candidates.contains(where: isDirectory)
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      && directory.boolValue
  }
}
