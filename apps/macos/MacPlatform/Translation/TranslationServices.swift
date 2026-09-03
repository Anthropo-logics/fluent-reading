import Foundation
import os

public struct TranslationUnitRequest: Codable, Equatable, Sendable {
  public let unitId: String
  public let text: String

  public init(unitId: String, text: String) {
    self.unitId = unitId
    self.text = text
  }
}

public struct TranslationRequest: Codable, Equatable, Sendable {
  public let modelId: String
  public let modelRevision: String
  public let runtimeId: String
  public let runtimeVersion: String
  public let sourceLanguage: String
  public let targetLanguage: String
  public let units: [TranslationUnitRequest]

  public init(
    modelId: String, modelRevision: String, runtimeId: String, runtimeVersion: String,
    sourceLanguage: String, targetLanguage: String, units: [TranslationUnitRequest]
  ) {
    self.modelId = modelId
    self.modelRevision = modelRevision
    self.runtimeId = runtimeId
    self.runtimeVersion = runtimeVersion
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.units = units
  }
}

public struct TranslatedUnitResult: Codable, Equatable, Sendable {
  public let translatedUnitId: String
  public let sourceUnitIds: [String]
  public let orderKey: UInt32
  public let translatedText: String
}

public struct TranslationResult: Codable, Equatable, Sendable {
  public let modelId: String
  public let modelRevision: String
  public let runtimeId: String
  public let runtimeVersion: String
  public let sourceLanguage: String
  public let targetLanguage: String
  public let translatedUnits: [TranslatedUnitResult]
  public let failedUnitIds: [String]

  /// AC7 (Story 5.4): every requested source unit must be accounted for exactly once, as either a
  /// translated or a failed unit — never lost, never duplicated across the two sets.
  public func hasExactCorrespondence(toRequestedUnitIds requestedUnitIds: [String]) -> Bool {
    let inputIds = Set(requestedUnitIds)
    let coveredIds = Set(translatedUnits.flatMap(\.sourceUnitIds) + failedUnitIds)
    return coveredIds == inputIds
      && translatedUnits.flatMap(\.sourceUnitIds).count + failedUnitIds.count == inputIds.count
  }
}

/// Where a passage stands in the translation walk. It lives beside the translation service rather
/// than in the view model because what the next pass is allowed to take is decided from it.
public enum TranslationUnitStatus: Equatable, Sendable {
  case pending
  case translated(String)
  case failed
  case nonTranslatable
}

public enum TranslationServiceError: Error, Equatable, Sendable {
  case invalidPair
  case runtimeMissing
  case modelMissing
  case translationFailed
  case outputInvalid
}

/// Only the candidate fixed for Story 5.1's spike/harness (`translategemma-4b-it-4bit` via
/// `mlx-swift-lm`/`lectura-translate-runtime`) is wired here — production candidate selection
/// happens at Task 7's verdict, not in this adapter.
public enum TranslationServices {
  /// Pure presentation projection: only a confirmed translation may replace the source text.
  /// Choosing Original never removes the confirmed result, so choosing Translation again is free.
  public static func visibleText(
    source: String, status: TranslationUnitStatus?, showingOriginal: Bool
  ) -> String {
    guard !showingOriginal, case .translated(let translated) = status else { return source }
    return translated
  }

  /// AC6 (Story 5.4): complex/degraded content must keep its classification rather than being
  /// silently turned into "reliable translated prose" — same `["prose","note"]`/`>= 0.7` threshold
  /// already used by `exportDegradedUnits`/`exportNonNarrableUnits` for narration/export.
  public static func isEligibleForTranslation(contentClass: String, confidence: Double) -> Bool {
    ["prose", "note"].contains(contentClass) && confidence >= 0.7
  }

  /// The passages the next translation pass should take, walking forward from the one being read.
  ///
  /// `retryingFailures` is true only for a pass the reader asked for explicitly. That pass takes
  /// back the units left `.failed`, which is what makes the retry button retry instead of skipping
  /// ahead to untouched text (Story 5.4 AC5). The automatic walk chained after each batch leaves
  /// them out on purpose: a passage the runtime cannot handle would otherwise be retried for ever.
  ///
  /// Units already resolved (`.translated`, `.nonTranslatable`) and those still `.pending` are
  /// never taken again, so no finished work is thrown away and no batch is requested twice; and the
  /// walk starts at the unit being read, so a retry never restarts the document (Story 5.7 AC2).
  public static func unitsToTranslate(
    orderedUnitIDs: [String],
    startingAt currentUnitID: String,
    statuses: [String: TranslationUnitStatus],
    windowSize: Int,
    retryingFailures: Bool
  ) -> [String] {
    guard let start = orderedUnitIDs.firstIndex(of: currentUnitID) else { return [] }
    return Array(
      orderedUnitIDs[start...]
        .filter { unitID in
          switch statuses[unitID] {
          case nil: return true
          case .failed: return retryingFailures
          default: return false
          }
        }
        .prefix(windowSize))
  }

  public static func translate(
    _ request: TranslationRequest,
    runtimeURL: URL,
    modelURL: URL,
    workRoot: URL? = nil
  ) throws -> TranslationResult {
    guard request.runtimeId == "mlx-swift-lm", request.runtimeVersion == "gemma3",
      request.modelId == "translategemma-4b-it-4bit",
      !request.units.isEmpty, request.units.count <= 64,
      Set(request.units.map(\.unitId)).count == request.units.count,
      request.units.allSatisfy({
        !$0.unitId.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw TranslationServiceError.invalidPair }
    guard runtimeURL.isFileURL, FileManager.default.isExecutableFile(atPath: runtimeURL.path)
    else { throw TranslationServiceError.runtimeMissing }
    var isDirectory: ObjCBool = false
    guard modelURL.isFileURL,
      FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw TranslationServiceError.modelMissing }

    let root =
      workRoot
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // Create it whichever way it was chosen. A caller-supplied work root was taken on trust and
    // never created, so the runtime had nowhere to write its output and every unit came back
    // failed with the reason discarded.
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var translatedUnits: [TranslatedUnitResult] = []
    var failedUnitIds: [String] = []
    for (index, unit) in request.units.enumerated() {
      let outputURL = root.appendingPathComponent("\(unit.unitId).txt")
      let process = Process()
      process.executableURL = runtimeURL
      process.arguments = [
        "--model", modelURL.path,
        "--source-language", request.sourceLanguage,
        "--target-language", request.targetLanguage,
        "--text", unit.text,
        "--output", outputURL.path,
      ]
      process.standardOutput = FileHandle.nullDevice
      // Keep the runtime's own diagnosis. Discarding it meant a batch could come back with every
      // unit failed and no way to tell why.
      let diagnostics = Pipe()
      process.standardError = diagnostics
      do {
        try process.run()
      } catch {
        throw TranslationServiceError.translationFailed
      }
      let errorOutput = diagnostics.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0,
        let text = try? String(contentsOf: outputURL, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        let reason =
          String(data: errorOutput, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        runtimeLog.error(
          "translation.unit_failed status=\(process.terminationStatus, privacy: .public) reason=\(reason.suffix(400), privacy: .public)"
        )
        failedUnitIds.append(unit.unitId)
        continue
      }
      translatedUnits.append(
        TranslatedUnitResult(
          translatedUnitId: "t-\(unit.unitId)",
          sourceUnitIds: [unit.unitId],
          orderKey: UInt32(index),
          translatedText: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return TranslationResult(
      modelId: request.modelId,
      modelRevision: request.modelRevision,
      runtimeId: request.runtimeId,
      runtimeVersion: request.runtimeVersion,
      sourceLanguage: request.sourceLanguage,
      targetLanguage: request.targetLanguage,
      translatedUnits: translatedUnits,
      failedUnitIds: failedUnitIds)
  }
}
