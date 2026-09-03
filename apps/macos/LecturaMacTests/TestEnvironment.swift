import Foundation

/// Reads an environment variable that gates an optional test, treating an empty value as absent.
///
/// `CI-Fast.xctestplan` declares its gate variables with `$(NAME)` substitution, and Xcode
/// substitutes an *empty string* — not nothing — when the variable is missing from the shell that
/// launched `xcodebuild`. That silently defeats both gating idioms: `guard let` succeeds on `""`
/// and runs the test against an empty path, and `?? "default"` never fires so the working default
/// is never used. Funnelling every gate through this helper makes "unset" and "empty" the same
/// case, which is what every call site already meant.
func gateEnvironment(
  _ key: String, environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
  guard let value = environment[key], !value.isEmpty else { return nil }
  return value
}

func gateEnabled(
  _ key: String, environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
  gateEnvironment(key, environment: environment) == "1"
}

enum GatePreflightError: LocalizedError {
  case missingVariable(String)
  case missingArtifact(String)
  case nonExecutableArtifact(String)

  var errorDescription: String? {
    switch self {
    case .missingVariable(let key):
      "Set \(key) to an existing local artifact before running this real gate"
    case .missingArtifact(let label):
      "Real gate artifact is missing: \(label)"
    case .nonExecutableArtifact(let label):
      "Real gate artifact is not executable: \(label)"
    }
  }
}

@discardableResult
func requiredGateArtifact(
  _ url: URL, label: String, executable: Bool = false,
  fileManager: FileManager = .default
) throws -> URL {
  guard fileManager.fileExists(atPath: url.path) else {
    throw GatePreflightError.missingArtifact(label)
  }
  guard !executable || fileManager.isExecutableFile(atPath: url.path) else {
    throw GatePreflightError.nonExecutableArtifact(label)
  }
  return url
}

func requiredGateURL(
  _ key: String, executable: Bool = false,
  environment: [String: String] = ProcessInfo.processInfo.environment,
  fileManager: FileManager = .default
) throws -> URL {
  guard let path = gateEnvironment(key, environment: environment) else {
    throw GatePreflightError.missingVariable(key)
  }
  return try requiredGateArtifact(
    URL(fileURLWithPath: path), label: key, executable: executable, fileManager: fileManager)
}
