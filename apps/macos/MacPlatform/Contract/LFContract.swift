import Foundation

public enum LFEventKind: String, Codable, Sendable {
  case accepted
  case progress
  case adapterRequested = "adapter_requested"
  case pageCompleted = "page_completed"
  case unitReady = "unit_ready"
  case paused
  case recoveryAvailable = "recovery_available"
  case completed
  case cancelled
  case failed
}

public enum LFJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([LFJSONValue])
  case object([String: LFJSONValue])

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let decoded = try? value.decode(Bool.self) {
      self = .bool(decoded)
    } else if let decoded = try? value.decode(Double.self) {
      self = .number(decoded)
    } else if let decoded = try? value.decode(String.self) {
      self = .string(decoded)
    } else if let decoded = try? value.decode([LFJSONValue].self) {
      self = .array(decoded)
    } else {
      self = .object(try value.decode([String: LFJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null:
      try value.encodeNil()
    case .bool(let decoded):
      try value.encode(decoded)
    case .number(let decoded):
      try value.encode(decoded)
    case .string(let decoded):
      try value.encode(decoded)
    case .array(let decoded):
      try value.encode(decoded)
    case .object(let decoded):
      try value.encode(decoded)
    }
  }
}

public struct LFCanaryResult: Codable, Equatable, Sendable {
  public let coreVersion: String
  public let message: String

  enum CodingKeys: String, CodingKey {
    case coreVersion = "core_version"
    case message
  }
}

public struct LFSpokenPart: Codable, Equatable, Sendable {
  public let kind: String
  public let value: String

  public init(kind: String, value: String) {
    self.kind = kind
    self.value = value
  }
}

public struct LFSpokenPlan: Codable, Equatable, Sendable {
  public let language: String
  public let frontendVoice: String
  public let normalizedText: String
  public let parts: [LFSpokenPart]

  enum CodingKeys: String, CodingKey {
    case language
    case frontendVoice = "frontend_voice"
    case normalizedText = "normalized_text"
    case parts
  }
}

public struct LFDocumentOpenedResult: Codable, Equatable, Sendable {
  public let documentID: String
  public let accessGrantID: String
  public let pageCount: UInt32
  public let firstPageMilliseconds: UInt64

  enum CodingKeys: String, CodingKey {
    case documentID = "document_id"
    case accessGrantID = "access_grant_id"
    case pageCount = "page_count"
    case firstPageMilliseconds = "first_page_ms"
  }
}

public enum LFIncrementalPageState: String, Codable, Sendable {
  case pending
  case processing
  case completed
  case failed
  case skipped

  public var nameKey: String {
    "reader.processing.state.\(rawValue)"
  }
}

public struct LFIncrementalPage: Codable, Equatable, Sendable {
  public let pageIndex: UInt32
  public let state: LFIncrementalPageState
  public let errorCode: String?

  enum CodingKeys: String, CodingKey {
    case pageIndex = "page_index"
    case state
    case errorCode = "error_code"
  }
}

public struct LFIncrementalSessionResult: Codable, Equatable, Sendable {
  public let documentID: String
  public let visiblePageIndex: UInt32
  public let cancelled: Bool
  public let pages: [LFIncrementalPage]

  enum CodingKeys: String, CodingKey {
    case documentID = "document_id"
    case visiblePageIndex = "visible_page_index"
    case cancelled
    case pages
  }
}

public struct LFNormalizationDecision: Codable, Equatable, Sendable {
  public let rule: String
  public let confidence: Double
  public let affectedSegments: [String]

  enum CodingKeys: String, CodingKey {
    case rule, confidence
    case affectedSegments = "affected_segments"
  }
}

public struct LFReadingUnit: Codable, Equatable, Sendable {
  public let unitID: String
  public let kind: String
  public let contentClass: String
  public let processingRoute: String
  public let orderKey: LFJSONValue
  public let text: String
  public let spokenText: String?
  public let sourceRegions: [DigitalSourceRegion]
  public let sourceBlockIDs: [String]
  public let parentUnitID: String?
  public let confidence: Double
  public let decisionTrace: [LFNormalizationDecision]

  enum CodingKeys: String, CodingKey {
    case unitID = "unit_id"
    case kind
    case contentClass = "content_class"
    case processingRoute = "processing_route"
    case orderKey = "order_key"
    case text
    case spokenText = "spoken_text"
    case sourceRegions = "source_regions"
    case sourceBlockIDs = "source_block_ids"
    case parentUnitID = "parent_unit_id"
    case confidence
    case decisionTrace = "decision_trace"
  }

  public var narrationText: String { spokenText ?? text }
}

public struct LFPageProcessingRecord: Codable, Equatable, Sendable {
  public let pageID: String
  public let pageIndex: UInt32
  public let route: String
  public let reasonCode: String
  public let status: String
  public let confidence: Double
  public let elapsedMilliseconds: UInt64
  public let processorRevision: String
  public let errorCode: String?

  enum CodingKeys: String, CodingKey {
    case pageID = "page_id"
    case pageIndex = "page_index"
    case route
    case reasonCode = "reason_code"
    case status, confidence
    case elapsedMilliseconds = "elapsed_ms"
    case processorRevision = "processor_revision"
    case errorCode = "error_code"
  }
}

public struct LFNormalizedPage: Codable, Equatable, Sendable {
  public let record: LFPageProcessingRecord
  public let units: [LFReadingUnit]
  public let anchors: [LFJSONValue]
  public let omissions: [LFNormalizationDecision]
}

public enum LFResult: Codable, Equatable, Sendable {
  case canary(LFCanaryResult)
  case spokenPlan(LFSpokenPlan)
  case documentOpened(LFDocumentOpenedResult)
  case incrementalSession(LFIncrementalSessionResult)
  case normalizedPage(LFNormalizedPage)

  public var canary: LFCanaryResult? {
    guard case .canary(let result) = self else { return nil }
    return result
  }

  public var spokenPlan: LFSpokenPlan? {
    guard case .spokenPlan(let result) = self else { return nil }
    return result
  }

  public var documentOpened: LFDocumentOpenedResult? {
    guard case .documentOpened(let result) = self else { return nil }
    return result
  }

  public var incrementalSession: LFIncrementalSessionResult? {
    guard case .incrementalSession(let result) = self else { return nil }
    return result
  }

  public var normalizedPage: LFNormalizedPage? {
    guard case .normalizedPage(let result) = self else { return nil }
    return result
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let result = try? container.decode(LFCanaryResult.self) {
      self = .canary(result)
    } else if let result = try? container.decode(LFSpokenPlan.self) {
      self = .spokenPlan(result)
    } else if let result = try? container.decode(LFDocumentOpenedResult.self) {
      self = .documentOpened(result)
    } else if let result = try? container.decode(LFIncrementalSessionResult.self) {
      self = .incrementalSession(result)
    } else {
      self = .normalizedPage(try container.decode(LFNormalizedPage.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .canary(let result): try container.encode(result)
    case .spokenPlan(let result): try container.encode(result)
    case .documentOpened(let result): try container.encode(result)
    case .incrementalSession(let result): try container.encode(result)
    case .normalizedPage(let result): try container.encode(result)
    }
  }
}

public struct LFErrorScope: Codable, Equatable, Sendable {
  public let jobID: String?
  public let documentID: String?
  public let pageIndex: UInt32?
  public let unitID: String?
  public let modelID: String?
  public let exportJobID: String?

  enum CodingKeys: String, CodingKey {
    case jobID = "job_id"
    case documentID = "document_id"
    case pageIndex = "page_index"
    case unitID = "unit_id"
    case modelID = "model_id"
    case exportJobID = "export_job_id"
  }
}

public struct LFError: Codable, Equatable, Error, Sendable {
  public let code: String
  public let messageKey: String
  public let scope: LFErrorScope
  public let details: [String: LFJSONValue]

  enum CodingKeys: String, CodingKey {
    case code
    case messageKey = "message_key"
    case scope
    case details
  }
}

public struct LFEvent: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let requestID: String
  public let jobID: String
  public let sequence: UInt64
  public let kind: LFEventKind
  public let progress: LFJSONValue?
  public let result: LFResult?
  public let error: LFError?
  public let recovery: LFJSONValue?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case jobID = "job_id"
    case sequence
    case kind
    case progress
    case result
    case error
    case recovery
  }
}

struct LFSubmissionAcceptance: Codable, Sendable {
  let schemaVersion: UInt32
  let requestID: String
  let jobID: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case jobID = "job_id"
  }
}
