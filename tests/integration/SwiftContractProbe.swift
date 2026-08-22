import Foundation

@main
enum SwiftContractProbe {
  static func main() throws {
    let data = try Data(
      contentsOf: URL(fileURLWithPath: "contracts/lf-v1/fixtures/canary-completed.json")
    )
    let event = try JSONDecoder().decode(LFEvent.self, from: data)

    guard event.schemaVersion == 1,
      event.requestID == "req_opaque",
      event.kind == .completed,
      event.result?.coreVersion == "0.1.0",
      event.result?.message == "lectura-core ready",
      event.error == nil
    else {
      throw ProbeError.contractMismatch
    }
  }
}

private enum ProbeError: Error {
  case contractMismatch
}
