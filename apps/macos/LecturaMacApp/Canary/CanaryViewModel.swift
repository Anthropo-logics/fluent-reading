import MacPlatform
import Observation

public struct CanaryFailure: Equatable, Sendable {
  public let code: String
  public let messageKey: String
}

public enum CanaryState: Equatable, Sendable {
  case loading
  case ready(LFEvent)
  case failed(CanaryFailure)
}

@MainActor
@Observable
public final class CanaryViewModel {
  public private(set) var state: CanaryState = .loading

  public init() {}

  public func load() async {
    state = .loading
    do {
      let event = try await EngineClient.canary()
      if event.kind == .completed {
        state = .ready(event)
      } else if let error = event.error {
        state = .failed(CanaryFailure(code: error.code, messageKey: error.messageKey))
      } else {
        state = .failed(
          CanaryFailure(
            code: "LF_INTERNAL_CANARY_EVENT",
            messageKey: "canary.event_unexpected"
          )
        )
      }
    } catch let failure as EngineClientError {
      state = .failed(Self.presentationFailure(for: failure))
    } catch {
      state = .failed(
        CanaryFailure(code: "LF_INTERNAL_CANARY_FAILED", messageKey: "canary.failed")
      )
    }
  }

  private static func presentationFailure(for failure: EngineClientError) -> CanaryFailure {
    if case .transport(_, let error?) = failure {
      return CanaryFailure(code: error.code, messageKey: error.messageKey)
    }
    return CanaryFailure(code: "LF_INTERNAL_CANARY_FAILED", messageKey: "canary.failed")
  }
}
