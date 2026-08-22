import Foundation

@main
enum SwiftCanaryStateProbe {
  @MainActor
  static func main() async throws {
    let model = CanaryViewModel()
    await model.load()

    guard case .ready(let event) = model.state,
      event.result?.coreVersion == "0.1.0"
    else {
      throw ProbeError.stateMismatch
    }
  }
}

private enum ProbeError: Error {
  case stateMismatch
}
