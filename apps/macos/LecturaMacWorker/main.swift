import Foundation
import PDFKit

private struct WorkerPayload: Decodable {
  let path: String?
  let language: String?
  let forceOcrPages: [UInt32]?
  let pageLimit: UInt32?
  let modelId: String?
  let modelRevision: String?
  let runtimeId: String?
  let runtimeVersion: String?
  let voiceId: String?
  let rawIpa: Bool?
  let units: [TTSUnitRequest]?
  let sourceLanguage: String?
  let targetLanguage: String?
  let translationUnits: [TranslationUnitRequest]?

}

private struct WorkerRequest: Decodable {
  let schemaVersion: UInt32
  let requestId: String
  let command: String
  let payload: WorkerPayload
}

private struct WorkerPageCandidate: Encodable {
  let pageIndex: UInt32
  let directBlocks: [DigitalTextBlock]
  let rasterContentDetected: Bool
  let ocrBlocks: [DigitalTextBlock]
  let ocrStatus: String?
  let ocrErrorCode: String?
  let ocrElapsedMs: UInt64
}

private struct WorkerResult: Encodable {
  let pages: [WorkerPageCandidate]?
  let tts: TTSSynthesisResult?
  let translation: TranslationResult?
  let system: WorkerSystemSample?
}

private struct WorkerSystemSample: Encodable {
  let thermalState: String
}

private struct WorkerError: Encodable {
  let code: String
  let messageKey: String
}

private struct WorkerResponse: Encodable {
  let schemaVersion: UInt32
  let requestId: String
  let kind: String
  let result: WorkerResult?
  let error: WorkerError?
}

@main
@MainActor
private struct LecturaMacWorker {
  static func main() async {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase

    while let line = readLine() {
      let response: WorkerResponse
      do {
        let request = try decoder.decode(WorkerRequest.self, from: Data(line.utf8))
        guard request.schemaVersion == 1 else {
          throw WorkerFailure.invalidRequest
        }
        if request.command == "system_sample" {
          response = WorkerResponse(
            schemaVersion: 1, requestId: request.requestId, kind: "completed",
            result: WorkerResult(
              pages: nil, tts: nil, translation: nil,
              system: WorkerSystemSample(
                thermalState: thermalState())), error: nil)
          guard let data = try? encoder.encode(response) else { exit(70) }
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data([0x0A]))
          continue
        }
        if request.command == "tts_synthesize" {
          response = try synthesize(request)
          guard let data = try? encoder.encode(response) else { exit(70) }
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data([0x0A]))
          continue
        }
        if request.command == "translate" {
          response = try translate(request)
          guard let data = try? encoder.encode(response) else { exit(70) }
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data([0x0A]))
          continue
        }
        guard request.command == "extract_document", let path = request.payload.path else {
          throw WorkerFailure.invalidRequest
        }
        let document = try DocumentServices.openReadOnly(at: URL(fileURLWithPath: path))
        let pageCount = min(
          document.pageCount, request.payload.pageLimit.map(Int.init) ?? document.pageCount)
        var directPages = [DigitalPageResult]()
        for pageIndex in 0..<pageCount {
          directPages.append(
            await DocumentServices.extractDigitalPage(
              at: URL(fileURLWithPath: path), pageIndex: pageIndex))
        }
        let ocrIndexes = Set((request.payload.forceOcrPages ?? []).map(Int.init))
        var ocrPages = [(DigitalPageResult, UInt64)]()
        for pageIndex in ocrIndexes.sorted() {
          let started = ContinuousClock.now
          let page = await DocumentServices.extractOCRPage(
            at: URL(fileURLWithPath: path), pageIndex: pageIndex,
            language: request.payload.language ?? "en")
          let elapsed = started.duration(to: .now)
          let elapsedMs = UInt64(
            max(
              0,
              elapsed.components.seconds * 1_000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            ))
          ocrPages.append((page, elapsedMs))
        }
        let candidates = directPages.map { direct in
          let ocr = ocrPages.first { $0.0.pageIndex == direct.pageIndex }
          let repaired =
            ocr.map { DocumentServices.repairDigitalText(direct, with: $0.0) } ?? direct
          return WorkerPageCandidate(
            pageIndex: direct.pageIndex,
            directBlocks: repaired.blocks,
            rasterContentDetected: direct.rasterContentDetected ?? false,
            ocrBlocks: ocr?.0.blocks ?? [],
            ocrStatus: ocr?.0.status,
            ocrErrorCode: ocr?.0.errorCode,
            ocrElapsedMs: ocr?.1 ?? 0)
        }
        response = WorkerResponse(
          schemaVersion: 1, requestId: request.requestId, kind: "completed",
          result: WorkerResult(pages: candidates, tts: nil, translation: nil, system: nil),
          error: nil)
      } catch let error as DocumentOpenError {
        let code = error == .encrypted ? "LF_PDF_ENCRYPTED" : "LF_PDF_UNREADABLE"
        response = failed(code: code, requestId: requestId(from: line, decoder: decoder))
      } catch let error as ModelServiceError {
        let code: String
        switch error {
        case .invalidPair: code = "LF_MODEL_RUNTIME_INCOMPATIBLE"
        case .runtimeMissing, .modelMissing: code = "LF_MODEL_REQUIRED"
        case .synthesisFailed: code = "LF_TTS_SYNTHESIS_FAILED"
        case .outputInvalid: code = "LF_TTS_OUTPUT_INVALID"
        }
        response = failed(code: code, requestId: requestId(from: line, decoder: decoder))
      } catch let error as TranslationServiceError {
        let code: String
        switch error {
        case .invalidPair: code = "LF_MODEL_RUNTIME_INCOMPATIBLE"
        case .runtimeMissing, .modelMissing: code = "LF_MODEL_REQUIRED"
        case .translationFailed: code = "LF_TRANSLATION_FAILED"
        case .outputInvalid: code = "LF_TRANSLATION_OUTPUT_INVALID"
        }
        response = failed(code: code, requestId: requestId(from: line, decoder: decoder))
      } catch {
        response = failed(
          code: "LF_CONTRACT_PAYLOAD_INVALID", requestId: requestId(from: line, decoder: decoder))
      }
      guard let data = try? encoder.encode(response) else { exit(70) }
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([0x0A]))
    }
  }

  private static func failed(code: String, requestId: String) -> WorkerResponse {
    WorkerResponse(
      schemaVersion: 1, requestId: requestId, kind: "failed", result: nil,
      error: WorkerError(code: code, messageKey: "worker.request_failed"))
  }

  private static func synthesize(_ request: WorkerRequest) throws -> WorkerResponse {
    guard
      let modelID = request.payload.modelId,
      let modelRevision = request.payload.modelRevision,
      let runtimeID = request.payload.runtimeId,
      let runtimeVersion = request.payload.runtimeVersion,
      let voiceID = request.payload.voiceId,
      let language = request.payload.language,
      let units = request.payload.units,
      let runtimePath = ProcessInfo.processInfo.environment["LECTURA_TTS_RUNTIME"],
      let modelPath = ProcessInfo.processInfo.environment["LECTURA_TTS_MODEL"]
    else { throw WorkerFailure.invalidRequest }
    let result = try ModelServices.synthesize(
      TTSSynthesisRequest(
        modelId: modelID,
        modelRevision: modelRevision,
        runtimeId: runtimeID,
        runtimeVersion: runtimeVersion,
        voiceId: voiceID,
        language: language,
        rawIPA: request.payload.rawIpa ?? false,
        units: units),
      runtimeURL: URL(fileURLWithPath: runtimePath),
      modelURL: URL(fileURLWithPath: modelPath),
      workRoot: ProcessInfo.processInfo.environment["LECTURA_TTS_WORK_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      })
    return WorkerResponse(
      schemaVersion: 1, requestId: request.requestId, kind: "completed",
      result: WorkerResult(pages: nil, tts: result, translation: nil, system: nil), error: nil)
  }

  private static func translate(_ request: WorkerRequest) throws -> WorkerResponse {
    guard
      let modelID = request.payload.modelId,
      let modelRevision = request.payload.modelRevision,
      let runtimeID = request.payload.runtimeId,
      let runtimeVersion = request.payload.runtimeVersion,
      let sourceLanguage = request.payload.sourceLanguage,
      let targetLanguage = request.payload.targetLanguage,
      let units = request.payload.translationUnits,
      let runtimePath = ProcessInfo.processInfo.environment["LECTURA_TRANSLATE_RUNTIME"],
      let modelPath = ProcessInfo.processInfo.environment["LECTURA_TRANSLATE_MODEL"]
    else { throw WorkerFailure.invalidRequest }
    let result = try TranslationServices.translate(
      TranslationRequest(
        modelId: modelID,
        modelRevision: modelRevision,
        runtimeId: runtimeID,
        runtimeVersion: runtimeVersion,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        units: units),
      runtimeURL: URL(fileURLWithPath: runtimePath),
      modelURL: URL(fileURLWithPath: modelPath),
      workRoot: ProcessInfo.processInfo.environment["LECTURA_TRANSLATE_WORK_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      })
    return WorkerResponse(
      schemaVersion: 1, requestId: request.requestId, kind: "completed",
      result: WorkerResult(pages: nil, tts: nil, translation: result, system: nil), error: nil)
  }

  private static func thermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private static func requestId(from line: String, decoder: JSONDecoder) -> String {
    (try? decoder.decode(WorkerRequest.self, from: Data(line.utf8)))?.requestId ?? "req_invalid"
  }
}

private enum WorkerFailure: Error {
  case invalidRequest
}
