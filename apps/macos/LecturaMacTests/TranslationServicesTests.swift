import XCTest

@testable import MacPlatform

final class TranslationServicesTests: XCTestCase {
  func testEligibilityKeepsDegradedAndNonProseContentOutOfTranslation() {
    XCTAssertTrue(
      TranslationServices.isEligibleForTranslation(contentClass: "prose", confidence: 0.7))
    XCTAssertTrue(
      TranslationServices.isEligibleForTranslation(contentClass: "note", confidence: 1.0))
    XCTAssertFalse(
      TranslationServices.isEligibleForTranslation(contentClass: "prose", confidence: 0.69),
      "below the 0.7 confidence floor")
    XCTAssertFalse(
      TranslationServices.isEligibleForTranslation(contentClass: "table", confidence: 1.0),
      "non-prose/note content class, regardless of confidence")
    XCTAssertFalse(
      TranslationServices.isEligibleForTranslation(contentClass: "heading", confidence: 0.9))
  }

  /// Story 5.4 AC5: the retry the reader can actually press has to take the failed passage back.
  /// The automatic walk chained after every batch must not, or one bad passage would be retried for
  /// ever — which is exactly why failures were excluded from the window in the first place.
  func testExplicitRetryTakesFailedUnitsBackAndTheAutomaticWalkLeavesThemOut() {
    let ordered = ["u1", "u2", "u3", "u4"]
    let statuses: [String: TranslationUnitStatus] = [
      "u1": .translated("already done"), "u2": .failed, "u3": .nonTranslatable,
    ]

    XCTAssertEqual(
      TranslationServices.unitsToTranslate(
        orderedUnitIDs: ordered, startingAt: "u1", statuses: statuses, windowSize: 5,
        retryingFailures: false),
      ["u4"],
      "the progressive walk moves on to untouched text and never retries a failure")

    let retry = TranslationServices.unitsToTranslate(
      orderedUnitIDs: ordered, startingAt: "u1", statuses: statuses, windowSize: 5,
      retryingFailures: true)
    XCTAssertEqual(
      retry, ["u2", "u4"], "an explicit retry takes the failed passage back into the window")
    XCTAssertFalse(retry.contains("u1"), "a validated translation is kept, never redone")
    XCTAssertFalse(retry.contains("u3"), "non-translatable content stays classified")

    XCTAssertEqual(
      TranslationServices.unitsToTranslate(
        orderedUnitIDs: ordered, startingAt: "u3", statuses: statuses, windowSize: 5,
        retryingFailures: true),
      ["u4"],
      "the retry resumes at the passage being read instead of restarting the document")

    XCTAssertEqual(
      TranslationServices.unitsToTranslate(
        orderedUnitIDs: ordered, startingAt: "u2", statuses: ["u2": .pending], windowSize: 5,
        retryingFailures: true),
      ["u3", "u4"],
      "a batch already in flight is not requested a second time")

    XCTAssertEqual(
      TranslationServices.unitsToTranslate(
        orderedUnitIDs: ordered, startingAt: "u1", statuses: statuses, windowSize: 1,
        retryingFailures: true),
      ["u2"],
      "the window size still bounds the batch")
  }

  func testRejectsBatchesAboveTheSixtyFourUnitLimitWithoutTouchingTheRuntime() {
    let units = (0..<65).map { TranslationUnitRequest(unitId: "u\($0)", text: "hola") }
    let request = TranslationRequest(
      modelId: "translategemma-4b-it-4bit", modelRevision: "revision123",
      runtimeId: "mlx-swift-lm", runtimeVersion: "gemma3", sourceLanguage: "es",
      targetLanguage: "en", units: units)
    XCTAssertThrowsError(
      try TranslationServices.translate(
        request, runtimeURL: URL(fileURLWithPath: "/nonexistent-runtime"),
        modelURL: URL(fileURLWithPath: "/nonexistent-model"))
    ) {
      XCTAssertEqual($0 as? TranslationServiceError, .invalidPair)
    }
  }

  func testCorrespondenceIsExactAgainstARealBatchNoLossNoDuplication() throws {
    guard let packagePath = gateEnvironment("LECTURA_REAL_TRANSLATION_PACKAGE"),
      let runtimePath = gateEnvironment("LECTURA_REAL_TRANSLATION_RUNTIME")
    else { throw XCTSkip("Set real translation runtime and package paths") }
    let modelURL = URL(fileURLWithPath: packagePath, isDirectory: true)
      .appendingPathComponent("data", isDirectory: true)
    let runtimeURL = URL(fileURLWithPath: runtimePath)
    let units = [
      TranslationUnitRequest(unitId: "u1", text: "El gato duerme en la ventana."),
      TranslationUnitRequest(unitId: "u2", text: "Mañana viajaremos a la costa."),
      TranslationUnitRequest(unitId: "u3", text: "El café estaba demasiado caliente."),
    ]
    let request = TranslationRequest(
      modelId: "translategemma-4b-it-4bit",
      modelRevision: "5788ec08c047f3f2e17808101b8d9566ac930d58", runtimeId: "mlx-swift-lm",
      runtimeVersion: "gemma3", sourceLanguage: "es", targetLanguage: "en", units: units)

    let result = try TranslationServices.translate(
      request, runtimeURL: runtimeURL, modelURL: modelURL)

    XCTAssertTrue(result.hasExactCorrespondence(toRequestedUnitIds: units.map(\.unitId)))
    XCTAssertTrue(result.translatedUnits.allSatisfy { !$0.translatedText.isEmpty })
  }

  func testExactCorrespondenceDetectsLossAndDuplication() {
    let complete = TranslationResult(
      modelId: "m", modelRevision: "r", runtimeId: "mlx-swift-lm", runtimeVersion: "gemma3",
      sourceLanguage: "es", targetLanguage: "en",
      translatedUnits: [
        TranslatedUnitResult(
          translatedUnitId: "t-u1", sourceUnitIds: ["u1"], orderKey: 0, translatedText: "Hi")
      ], failedUnitIds: ["u2"])
    XCTAssertTrue(complete.hasExactCorrespondence(toRequestedUnitIds: ["u1", "u2"]))

    let lostUnit = TranslationResult(
      modelId: "m", modelRevision: "r", runtimeId: "mlx-swift-lm", runtimeVersion: "gemma3",
      sourceLanguage: "es", targetLanguage: "en",
      translatedUnits: [
        TranslatedUnitResult(
          translatedUnitId: "t-u1", sourceUnitIds: ["u1"], orderKey: 0, translatedText: "Hi")
      ], failedUnitIds: [])
    XCTAssertFalse(
      lostUnit.hasExactCorrespondence(toRequestedUnitIds: ["u1", "u2"]),
      "u2 is neither translated nor failed — a silent loss")

    let duplicatedUnit = TranslationResult(
      modelId: "m", modelRevision: "r", runtimeId: "mlx-swift-lm", runtimeVersion: "gemma3",
      sourceLanguage: "es", targetLanguage: "en",
      translatedUnits: [
        TranslatedUnitResult(
          translatedUnitId: "t-u1", sourceUnitIds: ["u1"], orderKey: 0, translatedText: "Hi")
      ], failedUnitIds: ["u1"])
    XCTAssertFalse(
      duplicatedUnit.hasExactCorrespondence(toRequestedUnitIds: ["u1"]),
      "u1 appears both translated and failed — a duplication")
  }
}
