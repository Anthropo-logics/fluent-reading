import Foundation
import LecturaFFI

public enum EngineClientError: Error, Sendable {
  case unsupportedABIVersion(UInt32)
  case transport(Int32, LFError?)
  case invalidOwnedBuffer
  case invalidResponse
  case missingEngine
}

public enum EngineClient {
  #if compiler(>=6.2)
    @concurrent
  #endif
  public static func canary() async throws -> LFEvent {
    try invoke(
      Data(
        #"{"schema_version":1,"request_id":"req_macos_canary","command":"canary","payload":{}}"#
          .utf8)
    )
  }

  public static func spokenPlan(text: String, language: String) throws -> LFSpokenPlan {
    let request: [String: Any] = [
      "schema_version": 1,
      "request_id": "req_macos_spoken_plan",
      "command": "plan_spoken_text",
      "payload": ["text": text, "language": language],
    ]
    let event = try invoke(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
    guard let plan = event.result?.spokenPlan else { throw EngineClientError.invalidResponse }
    return plan
  }

  public static func phonemizedRequest(
    _ request: TTSSynthesisRequest, engineURL: URL?, dataRoot: URL
  ) -> TTSSynthesisRequest {
    guard request.modelId == "kokoro-82m-4bit", !request.rawIPA, let engineURL else {
      return request
    }
    var units = [TTSUnitRequest]()
    for unit in request.units {
      guard
        let plan = try? spokenPlan(text: unit.text, language: request.language),
        let phonemes = phonemize(plan, engineURL: engineURL, dataRoot: dataRoot)
      else { return request }
      units.append(TTSUnitRequest(unitId: unit.unitId, text: phonemes))
    }
    return TTSSynthesisRequest(
      modelId: request.modelId, modelRevision: request.modelRevision,
      runtimeId: request.runtimeId, runtimeVersion: request.runtimeVersion,
      voiceId: request.voiceId, language: request.language, rawIPA: true, units: units)
  }

  private static func phonemize(
    _ plan: LFSpokenPlan, engineURL: URL, dataRoot: URL
  ) -> String? {
    var output = [String]()
    for part in plan.parts {
      if part.kind == "punctuation" {
        output.append(part.value)
      } else if let value = ModelServices.phonemize(
        part.value, language: plan.frontendVoice, engineURL: engineURL, dataRoot: dataRoot)
      {
        output.append(value)
      } else {
        return nil
      }
    }
    return output.joined(separator: " ")
      .replacingOccurrences(of: " ,", with: ",")
      .replacingOccurrences(of: " .", with: ".")
      .replacingOccurrences(of: " ;", with: ";")
      .replacingOccurrences(of: " :", with: ":")
      .replacingOccurrences(of: " !", with: "!")
      .replacingOccurrences(of: " ?", with: "?")
      .replacingOccurrences(of: " —", with: "—")
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  /// - Parameter documentFingerprint: the SHA-256 of the file's own bytes, lowercase hex. The core
  ///   names the document after it, so the same file keeps the same session directory in every
  ///   launch and two different files never share one (Story 6.25).
  public static func openDocument(
    accessGrantID: String,
    documentFingerprint: String,
    pageCount: UInt32,
    firstPageMilliseconds: UInt64,
    furniturePages: [DigitalPageResult] = []
  ) async throws -> LFEvent {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let sampledPages: [[String: Any]] = try furniturePages.map { page in
      [
        "document_fingerprint": documentFingerprint,
        "generation_id": "generation_\(documentFingerprint.prefix(16))",
        "page_index": Int(page.pageIndex),
        "blocks": try JSONSerialization.jsonObject(with: encoder.encode(page.blocks)),
      ]
    }
    let payload: [String: Any] = [
      "access_grant_id": accessGrantID,
      "document_fingerprint": documentFingerprint,
      "page_count": pageCount,
      "first_page_ms": firstPageMilliseconds,
      "furniture_pages": sampledPages,
    ]
    let request: [String: Any] = [
      "schema_version": 1,
      "request_id": "req_macos_open_document",
      "command": "open_document",
      "payload": payload,
    ]
    return try invoke(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  public static func planSession(
    documentID: String,
    pageCount: UInt32,
    visiblePageIndex: UInt32
  ) async throws -> LFEvent {
    let payload: [String: Any] = [
      "document_id": documentID,
      "page_count": pageCount,
      "visible_page_index": visiblePageIndex,
    ]
    let request: [String: Any] = [
      "schema_version": 1,
      "request_id": "req_macos_plan_session",
      "command": "plan_session",
      "payload": payload,
    ]
    return try invoke(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  public static func mutateSession(
    _ session: LFIncrementalSessionResult,
    action: String,
    pageIndex: UInt32?,
    errorCode: String? = nil
  ) async throws -> LFEvent {
    let sessionData = try JSONEncoder().encode(session)
    let sessionObject = try JSONSerialization.jsonObject(with: sessionData)
    let request: [String: Any] = [
      "schema_version": 1,
      "request_id": "req_macos_mutate_session",
      "command": "mutate_session",
      "payload": [
        "session": sessionObject,
        "action": action,
        "page_index": pageIndex.map(Int.init) ?? NSNull(),
        "error_code": errorCode ?? NSNull(),
      ],
    ]
    return try invoke(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  public static func normalizePage(
    _ page: DigitalPageResult,
    documentFingerprint: String,
    generationID: String,
    language: String = DocumentLanguage.fallback,
    route: String = "direct_text",
    requestedUnit: String = "paragraph"
  ) async throws -> LFEvent {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let blocks = try JSONSerialization.jsonObject(with: encoder.encode(page.blocks))
    let request: [String: Any] = [
      "schema_version": 1,
      "request_id": "req_macos_normalize_page",
      "command": "normalize_page",
      "payload": [
        "page": [
          "document_fingerprint": documentFingerprint,
          "generation_id": generationID,
          "page_index": Int(page.pageIndex),
          "blocks": blocks,
        ],
        "language": language,
        "requested_unit": requestedUnit,
        "route": route,
        "adapter_status": page.status,
      ],
    ]
    return try invoke(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
  }

  private static func invoke(_ request: Data) throws -> LFEvent {
    let abiVersion = lf_abi_version()
    guard abiVersion == 1 else {
      throw EngineClientError.unsupportedABIVersion(abiVersion)
    }

    var engine: OpaquePointer?
    var createError = emptyOwnedBytes()
    let createCode = withInput(Data("{}".utf8)) { configuration in
      lf_engine_create(configuration, &engine, &createError)
    }
    guard createCode == LF_ABI_OK else {
      try throwFailure(code: createCode, owned: createError)
    }
    guard let engine else {
      throw EngineClientError.missingEngine
    }
    defer { lf_engine_destroy(engine) }

    var acceptanceBytes = emptyOwnedBytes()
    let submitCode = withInput(request) { input in
      lf_engine_submit(engine, input, &acceptanceBytes)
    }
    guard submitCode == LF_ABI_OK else {
      try throwFailure(code: submitCode, owned: acceptanceBytes)
    }
    let acceptance: LFSubmissionAcceptance = try decodeOwned(acceptanceBytes)

    var eventBytes = emptyOwnedBytes()
    let nextCode = withInput(Data(acceptance.jobID.utf8)) { jobID in
      lf_engine_next_event(engine, jobID, 0, &eventBytes)
    }
    guard nextCode == LF_ABI_OK else {
      try throwFailure(code: nextCode, owned: eventBytes)
    }
    return try decodeOwned(eventBytes)
  }

  private static func emptyOwnedBytes() -> LFOwnedBytes {
    LFOwnedBytes(ptr: nil, len: 0)
  }

  private static func withInput<T>(_ data: Data, body: (LFInputBytes) -> T) -> T {
    data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return body(LFInputBytes(ptr: bytes.baseAddress, len: bytes.count))
    }
  }

  private static func decodeOwned<T: Decodable>(_ owned: LFOwnedBytes) throws -> T {
    guard owned.len == 0 || owned.ptr != nil else {
      throw EngineClientError.invalidOwnedBuffer
    }
    defer { lf_owned_bytes_free(owned) }

    let data: Data
    if let pointer = owned.ptr {
      data = Data(bytes: pointer, count: owned.len)
    } else {
      data = Data()
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw EngineClientError.invalidResponse
    }
  }

  private static func throwFailure(code: Int32, owned: LFOwnedBytes) throws -> Never {
    if owned.ptr == nil, owned.len == 0 {
      throw EngineClientError.transport(code, nil)
    }
    let error: LFError = try decodeOwned(owned)
    throw EngineClientError.transport(code, error)
  }
}

/// Main-actor boundary used by the application and integration harnesses.
/// Domain decisions stay in Rust; this type only owns the Swift-side invocation.
@MainActor
public final class SessionHost {
  public init() {}

  public func openDocument(
    accessGrantID: String,
    documentFingerprint: String,
    pageCount: UInt32,
    firstPageMilliseconds: UInt64
  ) async throws -> LFEvent {
    try await EngineClient.openDocument(
      accessGrantID: accessGrantID,
      documentFingerprint: documentFingerprint,
      pageCount: pageCount,
      firstPageMilliseconds: firstPageMilliseconds)
  }

  public func planSession(
    documentID: String,
    pageCount: UInt32,
    visiblePageIndex: UInt32
  ) async throws -> LFEvent {
    try await EngineClient.planSession(
      documentID: documentID,
      pageCount: pageCount,
      visiblePageIndex: visiblePageIndex)
  }

  public func mutateSession(
    _ session: LFIncrementalSessionResult,
    action: String,
    pageIndex: UInt32?,
    errorCode: String? = nil
  ) async throws -> LFEvent {
    try await EngineClient.mutateSession(
      session, action: action, pageIndex: pageIndex, errorCode: errorCode)
  }
}
