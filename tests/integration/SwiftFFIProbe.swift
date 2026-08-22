import Foundation

@main
enum SwiftFFIProbe {
  static func main() async throws {
    let event = try await EngineClient.canary()
    guard event.kind == .completed,
      event.result?.coreVersion == "0.1.0",
      event.result?.message == "lectura-core ready"
    else {
      throw ProbeError.canaryMismatch
    }
  }
}

private enum ProbeError: Error {
  case canaryMismatch
}
