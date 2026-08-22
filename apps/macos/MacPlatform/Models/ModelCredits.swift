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
  public let manifest: InstallableModelManifest
  /// Whether a package for this manifest exists on this device right now.
  public let isInstalled: Bool

  public var id: String { manifest.id }

  public init(manifest: InstallableModelManifest, isInstalled: Bool) {
    self.manifest = manifest
    self.isInstalled = isInstalled
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
        let data = try? Data(contentsOf: url),
        let manifest = try? ModelPackageInstaller.decodeManifest(data),
        byID[manifest.id] == nil
      else { continue }
      byID[manifest.id] = ModelCredit(
        manifest: manifest,
        isInstalled: isPackagePresent(
          id: manifest.id, storageRoot: storageRoot, containerRoot: containerRoot))
    }
    // Grouped by purpose, alphabetical inside each group: a stable order keeps the panel from
    // reshuffling between launches, which a dictionary's own order would do.
    return byID.values.sorted {
      ($0.manifest.purpose, $0.manifest.id) < ($1.manifest.purpose, $1.manifest.id)
    }
  }

  /// Presence, not integrity: re-hashing several gigabytes of weights every time the reader opens
  /// the About panel would freeze it. Integrity is verified where it matters, before synthesis.
  private static func isPackagePresent(id: String, storageRoot: URL?, containerRoot: URL) -> Bool {
    let candidates = [
      containerRoot.appendingPathComponent("installed/\(id)", isDirectory: true),
      storageRoot?.appendingPathComponent("verified-packages/\(id)", isDirectory: true),
    ].compactMap { $0 }
    return candidates.contains { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
  }
}
