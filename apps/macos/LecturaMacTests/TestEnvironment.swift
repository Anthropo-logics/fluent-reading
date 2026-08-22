import Foundation

/// Reads an environment variable that gates an optional test, treating an empty value as absent.
///
/// `CI-Fast.xctestplan` declares its gate variables with `$(NAME)` substitution, and Xcode
/// substitutes an *empty string* — not nothing — when the variable is missing from the shell that
/// launched `xcodebuild`. That silently defeats both gating idioms: `guard let` succeeds on `""`
/// and runs the test against an empty path, and `?? "default"` never fires so the working default
/// is never used. Funnelling every gate through this helper makes "unset" and "empty" the same
/// case, which is what every call site already meant.
func gateEnvironment(_ key: String) -> String? {
  guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
  return value
}
