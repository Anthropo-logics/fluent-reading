import AVFoundation
import CryptoKit
import PDFKit
import XCTest

@testable import MacPlatform

final class ModelServicesTests: XCTestCase {
  @MainActor
  func testAudiobookExporterPublishesOrderedUnitsAndRemovesCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("book.m4b")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let model = try ModelPackageInstaller.decodeManifest(
      installManifest(path: "data/voice.safetensors", payload: payload, hash: hash))
    var completed: [Int] = []

    let result = try await AudiobookExporter.export(
      AudiobookExportRequest(
        jobID: "job", sourceFingerprint: "source", title: "Book", language: "es",
        voiceID: "voice",
        units: [
          AudiobookExportUnit(unitID: "u1", text: "Uno", anchorID: "a1"),
          AudiobookExportUnit(unitID: "u2", text: "Dos", anchorID: "a2"),
        ], model: model, modelURL: root, runtimeURL: root, destinationURL: destination,
        workRoot: root.appendingPathComponent("jobs")),
      synthesize: { request, _, _, workRoot in
        try FileManager.default.createDirectory(
          at: workRoot, withIntermediateDirectories: true)
        let audio = workRoot.appendingPathComponent("unit.wav")
        try writeTestWave(at: audio)
        return TTSSynthesisResult(
          modelId: request.modelId, modelRevision: request.modelRevision,
          runtimeId: request.runtimeId, runtimeVersion: request.runtimeVersion,
          voiceId: request.voiceId, language: request.language, audioPath: audio.path,
          segments: [
            NarrationSegmentResult(
              unitId: request.units[0].unitId, segmentIndex: 0, unitSampleOffset: 0,
              sampleCount: 2_400, sampleRateHz: 24_000, elapsedMs: 1, artifactHash: nil,
              modelRevision: request.modelRevision, voiceId: request.voiceId)
          ], omittedUnitIds: [])
      },
      progress: { completed.append($0.completedUnits) })

    XCTAssertEqual(result, destination)
    XCTAssertEqual(completed, [1, 2])
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs/job").path))
  }

  @MainActor
  func testAudiobookExporterEmbedsOrderedChapterMarksAtExpectedPositions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("book.m4b")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let model = try ModelPackageInstaller.decodeManifest(
      installManifest(path: "data/voice.safetensors", payload: payload, hash: hash))

    let result = try await AudiobookExporter.export(
      AudiobookExportRequest(
        jobID: "job-chapters", sourceFingerprint: "source", title: "Book", language: "es",
        voiceID: "voice",
        units: [
          AudiobookExportUnit(unitID: "u1", text: "Uno", anchorID: "a1"),
          AudiobookExportUnit(unitID: "u2", text: "Dos", anchorID: "a2"),
          AudiobookExportUnit(unitID: "u3", text: "Tres", anchorID: "a3"),
        ], model: model, modelURL: root, runtimeURL: root, destinationURL: destination,
        workRoot: root.appendingPathComponent("jobs"),
        chapters: [
          AudiobookChapterMark(title: "Prólogo", unitIndex: 0),
          AudiobookChapterMark(title: "Capítulo uno", unitIndex: 2),
        ]),
      synthesize: { request, _, _, workRoot in
        try FileManager.default.createDirectory(
          at: workRoot, withIntermediateDirectories: true)
        let audio = workRoot.appendingPathComponent("unit.wav")
        try writeTestWave(at: audio)
        return TTSSynthesisResult(
          modelId: request.modelId, modelRevision: request.modelRevision,
          runtimeId: request.runtimeId, runtimeVersion: request.runtimeVersion,
          voiceId: request.voiceId, language: request.language, audioPath: audio.path,
          segments: [
            NarrationSegmentResult(
              unitId: request.units[0].unitId, segmentIndex: 0, unitSampleOffset: 0,
              sampleCount: 2_400, sampleRateHz: 24_000, elapsedMs: 1, artifactHash: nil,
              modelRevision: request.modelRevision, voiceId: request.voiceId)
          ], omittedUnitIds: [])
      })

    let chapters = try AudiobookExporter.readChapterSamples(fromFileAt: result)
    XCTAssertEqual(chapters.map(\.title), ["Prólogo", "Capítulo uno"])
    XCTAssertEqual(chapters[0].startSeconds, 0, accuracy: 0.05)
    XCTAssertEqual(chapters[1].startSeconds, 0.2, accuracy: 0.05)
  }

  func testChapterMarksAcceptsMonotonicOutlineAboveConfidenceBarAndRejectsOtherwise() {
    let unitPages = [0, 0, 1, 1, 2, 3]
    let reliableOutline: [(title: String, pageIndex: Int)] = [
      ("Intro", 0), ("Capítulo 1", 1), ("Capítulo 2", 3),
    ]
    let reliable = AudiobookExporter.chapterMarks(outline: reliableOutline, unitPages: unitPages)
    XCTAssertEqual(reliable.map(\.title), ["Intro", "Capítulo 1", "Capítulo 2"])
    XCTAssertEqual(reliable.map(\.unitIndex), [0, 2, 5])

    let unreliableOutline: [(title: String, pageIndex: Int)] = [
      ("A", 0), ("B", 5), ("C", 5), ("D", 5), ("E", 5),
    ]
    XCTAssertTrue(
      AudiobookExporter.chapterMarks(outline: unreliableOutline, unitPages: unitPages).isEmpty)
  }

  @MainActor
  func testAudiobookExporterCancellationRemovesTemporariesWithoutPublishing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("book.m4b")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let model = try ModelPackageInstaller.decodeManifest(
      installManifest(path: "data/voice.safetensors", payload: payload, hash: hash))
    let request = AudiobookExportRequest(
      jobID: "job-cancel", sourceFingerprint: "source", title: "Book", language: "es",
      voiceID: "voice",
      units: [
        AudiobookExportUnit(unitID: "u1", text: "Uno", anchorID: "a1"),
        AudiobookExportUnit(unitID: "u2", text: "Dos", anchorID: "a2"),
      ], model: model, modelURL: root, runtimeURL: root, destinationURL: destination,
      workRoot: root.appendingPathComponent("jobs"))

    nonisolated(unsafe) var task: Task<URL, Error>!
    task = Task {
      try await AudiobookExporter.export(
        request,
        synthesize: { request, _, _, workRoot in
          try FileManager.default.createDirectory(
            at: workRoot, withIntermediateDirectories: true)
          let audio = workRoot.appendingPathComponent("unit.wav")
          try writeTestWave(at: audio)
          if request.units[0].unitId == "u1" { task.cancel() }
          return TTSSynthesisResult(
            modelId: request.modelId, modelRevision: request.modelRevision,
            runtimeId: request.runtimeId, runtimeVersion: request.runtimeVersion,
            voiceId: request.voiceId, language: request.language, audioPath: audio.path,
            segments: [
              NarrationSegmentResult(
                unitId: request.units[0].unitId, segmentIndex: 0, unitSampleOffset: 0,
                sampleCount: 2_400, sampleRateHz: 24_000, elapsedMs: 1, artifactHash: nil,
                modelRevision: request.modelRevision, voiceId: request.voiceId)
            ], omittedUnitIds: [])
        })
    }
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch let error as AudiobookExportError {
      XCTAssertEqual(error, .cancelled)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs/job-cancel").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  @MainActor
  func testAudiobookExporterRetryAfterSynthesisFailurePreservesVerifiedFragments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("book.m4b")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let model = try ModelPackageInstaller.decodeManifest(
      installManifest(path: "data/voice.safetensors", payload: payload, hash: hash))
    let request = AudiobookExportRequest(
      jobID: "job-retry", sourceFingerprint: "source", title: "Book", language: "es",
      voiceID: "voice",
      units: [
        AudiobookExportUnit(unitID: "u1", text: "Uno", anchorID: "a1"),
        AudiobookExportUnit(unitID: "u2", text: "Dos", anchorID: "a2"),
      ], model: model, modelURL: root, runtimeURL: root, destinationURL: destination,
      workRoot: root.appendingPathComponent("jobs"))

    nonisolated(unsafe) var calls: [String] = []
    do {
      _ = try await AudiobookExporter.export(
        request,
        synthesize: { request, _, _, workRoot in
          calls.append(request.units[0].unitId)
          if request.units[0].unitId == "u2" { throw AudiobookExportError.synthesisFailed }
          try FileManager.default.createDirectory(
            at: workRoot, withIntermediateDirectories: true)
          let audio = workRoot.appendingPathComponent("unit.wav")
          try writeTestWave(at: audio)
          return makeSingleUnitResult(request, audio)
        })
      XCTFail("expected synthesis failure")
    } catch let error as AudiobookExportError {
      XCTAssertEqual(error, .synthesisFailed)
    }
    XCTAssertEqual(calls, ["u1", "u2"])
    let manifestURL = root.appendingPathComponent("jobs/job-retry/manifest.json")
    let manifest = try JSONDecoder().decode(
      AudiobookJobManifest.self, from: Data(contentsOf: manifestURL))
    XCTAssertEqual(manifest.fragments.map(\.unitID), ["u1"])

    calls = []
    let result = try await AudiobookExporter.export(
      request,
      synthesize: { request, _, _, workRoot in
        calls.append(request.units[0].unitId)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let audio = workRoot.appendingPathComponent("unit.wav")
        try writeTestWave(at: audio)
        return makeSingleUnitResult(request, audio)
      })
    XCTAssertEqual(calls, ["u2"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
  }

  @MainActor
  func testAudiobookExporterThrowsDestinationExistsWhenNotReplacing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("book.m4b")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: destination)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let model = try ModelPackageInstaller.decodeManifest(
      installManifest(path: "data/voice.safetensors", payload: payload, hash: hash))
    do {
      _ = try await AudiobookExporter.export(
        AudiobookExportRequest(
          jobID: "job-exists", sourceFingerprint: "source", title: "Book", language: "es",
          voiceID: "voice", units: [AudiobookExportUnit(unitID: "u1", text: "Uno", anchorID: "a1")],
          model: model, modelURL: root, runtimeURL: root, destinationURL: destination,
          workRoot: root.appendingPathComponent("jobs")))
      XCTFail("expected destinationExists")
    } catch let error as AudiobookExportError {
      XCTAssertEqual(error, .destinationExists)
    }
  }

  func testPruneStaleJobsRemovesStructurallyInvalidManifestForMatchingDocumentOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func writeJob(id: String, sourceFingerprint: String) throws -> URL {
      let jobRoot = root.appendingPathComponent(id)
      try FileManager.default.createDirectory(
        at: jobRoot.appendingPathComponent("fragments"), withIntermediateDirectories: true)
      try Data("audio-bytes".utf8).write(
        to: jobRoot.appendingPathComponent("fragments/00000000.wav"))
      let manifest = AudiobookJobManifest(
        schemaVersion: 1, jobID: id, sourceFingerprint: sourceFingerprint, title: "Book",
        language: "es", voiceID: "voice", modelID: "model", modelRevision: "revision",
        format: "m4b-aac-lc-24000-mono", totalUnits: 2, destinationBookmark: nil,
        destinationName: "book.m4b",
        fragments: [
          AudiobookFragment(
            unitID: "u1", anchorID: "a1", startSeconds: 0, relativePath: "fragments/00000000.wav",
            sha256: "wrong-hash-so-this-is-structurally-invalid", durationSeconds: 1)
        ])
      try JSONEncoder().encode(manifest).write(to: jobRoot.appendingPathComponent("manifest.json"))
      return jobRoot
    }
    let matching = try writeJob(id: "job-a", sourceFingerprint: "doc")
    let other = try writeJob(id: "job-b", sourceFingerprint: "other-doc")

    AudiobookExporter.pruneStaleJobs(workRoot: root, sourceFingerprint: "doc")

    XCTAssertFalse(FileManager.default.fileExists(atPath: matching.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
  }

  @MainActor
  func testAudiobookExporterRejectsResumeWithTamperedFragmentAndStaysRecoverable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("book.m4b")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let model = try ModelPackageInstaller.decodeManifest(
      installManifest(path: "data/voice.safetensors", payload: payload, hash: hash))
    let request = AudiobookExportRequest(
      jobID: "job-tamper", sourceFingerprint: "source", title: "Book", language: "es",
      voiceID: "voice",
      units: [
        AudiobookExportUnit(unitID: "u1", text: "Uno", anchorID: "a1"),
        AudiobookExportUnit(unitID: "u2", text: "Dos", anchorID: "a2"),
      ], model: model, modelURL: root, runtimeURL: root, destinationURL: destination,
      workRoot: root.appendingPathComponent("jobs"))

    do {
      _ = try await AudiobookExporter.export(
        request,
        synthesize: { request, _, _, workRoot in
          if request.units[0].unitId == "u2" { throw AudiobookExportError.synthesisFailed }
          try FileManager.default.createDirectory(
            at: workRoot, withIntermediateDirectories: true)
          let audio = workRoot.appendingPathComponent("unit.wav")
          try writeTestWave(at: audio)
          return makeSingleUnitResult(request, audio)
        })
      XCTFail("expected synthesis failure")
    } catch let error as AudiobookExportError {
      XCTAssertEqual(error, .synthesisFailed)
    }

    let jobRoot = root.appendingPathComponent("jobs/job-tamper")
    try Data("corrupted-fragment-bytes".utf8).write(
      to: jobRoot.appendingPathComponent("fragments/00000000.wav"))

    do {
      _ = try await AudiobookExporter.export(
        request,
        synthesize: { _, _, _, _ in
          XCTFail("must not synthesize when a persisted fragment fails integrity validation")
          throw AudiobookExportError.synthesisFailed
        })
      XCTFail("expected missingFragment")
    } catch let error as AudiobookExportError {
      XCTAssertEqual(error, .missingFragment)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent("manifest.json").path),
      "a rejected resume must stay diagnosable/restartable, not silently vanish")
  }

  func testDetectsClippingRegressionFlagsNewFullScaleSamplesAndUnexpectedSilence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let quietSource = root.appendingPathComponent("quiet.wav")
    let clipped = root.appendingPathComponent("clipped.wav")
    let matched = root.appendingPathComponent("matched.wav")
    let silent = root.appendingPathComponent("silent.wav")
    try writeConstantWave(at: quietSource, amplitude: 0.5)
    try writeConstantWave(at: clipped, amplitude: 1.0)
    try writeConstantWave(at: matched, amplitude: 0.5)
    try writeConstantWave(at: silent, amplitude: 0)
    let fullRange = CMTimeRange(
      start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 24_000))

    let flaggedClipping = try await AudiobookExporter.detectsClippingRegression(
      sourceWav: quietSource, finalAsset: clipped, timeRange: fullRange)
    XCTAssertTrue(flaggedClipping)

    let flaggedSilence = try await AudiobookExporter.detectsClippingRegression(
      sourceWav: quietSource, finalAsset: silent, timeRange: fullRange)
    XCTAssertTrue(flaggedSilence)

    let clean = try await AudiobookExporter.detectsClippingRegression(
      sourceWav: quietSource, finalAsset: matched, timeRange: fullRange)
    XCTAssertFalse(clean)
  }

  func testAudiobookManifestTracesOrderedAnchorsWithoutDocumentText() throws {
    let manifest = AudiobookJobManifest(
      schemaVersion: 1, jobID: "job", sourceFingerprint: "source", title: "Book",
      language: "es", voiceID: "voice", modelID: "model", modelRevision: "revision",
      format: "m4b-aac-lc-24000-mono", totalUnits: 2, destinationBookmark: nil,
      destinationName: "book.m4b",
      fragments: [
        AudiobookFragment(
          unitID: "u1", anchorID: "a1", startSeconds: 0, relativePath: "fragments/0.wav",
          sha256: "hash1", durationSeconds: 1.25),
        AudiobookFragment(
          unitID: "u2", anchorID: "a2", startSeconds: 1.25,
          relativePath: "fragments/1.wav", sha256: "hash2", durationSeconds: 2),
      ])

    let encoded = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(AudiobookJobManifest.self, from: encoded)

    XCTAssertEqual(decoded.fragments.map(\.unitID), ["u1", "u2"])
    XCTAssertEqual(decoded.fragments.map(\.startSeconds), [0, 1.25])
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("document_text"))
  }

  func testInstalledManifestExposesOnlyLanguageCompatibleVoices() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifest = try ModelPackageInstaller.decodeManifest(
      Data(contentsOf: repository.appendingPathComponent("models/manifests/kokoro-82m-4bit.json")))
    XCTAssertEqual(manifest.voices(for: "es"), ["ef_dora"])
    XCTAssertEqual(manifest.voices(for: "en"), ["af_heart"])
    XCTAssertEqual(manifest.voices(for: "pt"), ["pf_dora"])
    XCTAssertTrue(manifest.voices(for: "fr").isEmpty)
  }

  func testDecodeManifestAcceptsRealTranslationManifestAndRejectsNonEmptyVoices() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifest = try ModelPackageInstaller.decodeManifest(
      Data(
        contentsOf: repository.appendingPathComponent(
          "models/manifests/translategemma-4b-it-4bit.json")))
    XCTAssertEqual(manifest.purpose, "translation")
    XCTAssertEqual(manifest.runtimeId, "mlx-swift-lm")
    XCTAssertEqual(manifest.runtimeVersion, "gemma3")
    XCTAssertTrue(manifest.voices.isEmpty)
    XCTAssertTrue(manifest.languages.contains("es"))
    XCTAssertTrue(manifest.languages.contains("en"))
    XCTAssertTrue(manifest.languages.contains("pt"))

    var withVoices =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: repository.appendingPathComponent(
            "models/manifests/translategemma-4b-it-4bit.json")))
      as! [String: Any]
    withVoices["voices"] = ["should-not-exist"]
    let invalidData = try JSONSerialization.data(withJSONObject: withVoices)
    XCTAssertThrowsError(try ModelPackageInstaller.decodeManifest(invalidData)) { error in
      XCTAssertEqual(error as? ModelInstallationError, .invalidManifest)
    }
  }

  func testTranslationDirectionsAndTargetsMatchTheRatifiedSixPairContract() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifest = try ModelPackageInstaller.decodeManifest(
      Data(
        contentsOf: repository.appendingPathComponent(
          "models/manifests/translategemma-4b-it-4bit.json")))
    XCTAssertEqual(
      Set(manifest.translationDirections), ["ES→EN", "ES→PT", "EN→ES", "EN→PT", "PT→ES", "PT→EN"])
    XCTAssertEqual(Set(manifest.translationTargets(from: "es")), ["en", "pt"])
    XCTAssertEqual(Set(manifest.translationTargets(from: "en")), ["es", "pt"])
    XCTAssertEqual(Set(manifest.translationTargets(from: "pt")), ["es", "en"])
    XCTAssertTrue(manifest.translationTargets(from: "fr").isEmpty, "unsupported source language")
    XCTAssertTrue(manifest.translationTargets(from: "").isEmpty, "no source language chosen yet")
  }

  func testTranslationTargetsAreEmptyWhenManifestIsMissingASupportedLanguage() throws {
    var object =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models/manifests/translategemma-4b-it-4bit.json")))
      as! [String: Any]
    object["languages"] = ["es", "en"]
    let manifest = try ModelPackageInstaller.decodeManifest(
      try JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(Set(manifest.translationDirections), ["ES→EN", "EN→ES"])
    XCTAssertTrue(
      manifest.translationTargets(from: "pt").isEmpty,
      "pt is not among the manifest's declared languages")
  }

  func testDecodeManifestRejectsUnsupportedPurposeRuntimePairing() throws {
    let payload = Data("weights".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let mismatchedRuntime = Data(
      """
      {"schema_version":1,"id":"test-translation","model_revision":"revision123","artifact_revision":"revision123","purpose":"translation","authors":["author"],"license_id":"Apache-2.0","usage_restrictions":["reviewed"],"languages":["es","en"],"voices":[],"runtime_id":"onnxruntime-swift-package-manager","runtime_version":"1.24.2","distribution_status":"pending_review","artifacts":[{"relative_path":"data/model.safetensors","role":"model_weights","source_url":"https://example.invalid/revision123/model.safetensors","publisher":"publisher","format":"safetensors","quantization":"4bit","size_bytes":\(payload.count),"sha256_hex":"\(hash)"}]}
      """.utf8)
    XCTAssertThrowsError(try ModelPackageInstaller.decodeManifest(mismatchedRuntime)) { error in
      XCTAssertEqual(error as? ModelInstallationError, .invalidManifest)
    }
  }

  func testRedirectPolicyPinsHTTPSHostAndImmutableRevision() throws {
    let revision = "e4468a460f6f70b9125a003e0adb1ab7d4904bbd"
    let delegate = PinnedRedirectDelegate(
      originURL: try XCTUnwrap(
        URL(string: "https://huggingface.co/models/\(revision)/config.json")))
    XCTAssertTrue(
      delegate.acceptsFinalURL(
        URL(string: "https://huggingface.co/api/cache/\(revision)/config.json")))
    XCTAssertFalse(
      delegate.acceptsFinalURL(URL(string: "https://evil.invalid/cache/\(revision)/config.json")))
    XCTAssertFalse(
      delegate.acceptsFinalURL(URL(string: "http://huggingface.co/cache/\(revision)/config.json")))
    XCTAssertFalse(
      delegate.acceptsFinalURL(URL(string: "https://huggingface.co/cache/other/config.json")))
  }

  func testModelInstallerPublishesOnlyVerifiedManifestArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let manifest = installManifest(path: "data/voice.safetensors", payload: payload, hash: digest)
    let result = try await ModelPackageInstaller.install(
      manifestData: manifest, containerRoot: root,
      fetch: { _ in
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: url)
        return url
      })

    XCTAssertEqual(result.totalSizeBytes, UInt64(payload.count))
    XCTAssertEqual(
      try Data(contentsOf: result.directory.appendingPathComponent("data/voice.safetensors")),
      payload)
    XCTAssertNotNil(ModelPackageInstaller.installedModel(id: "test-model", containerRoot: root))
    XCTAssertNotNil(
      ModelPackageInstaller.verifiedPackage(
        manifestData: manifest, packageRoot: result.directory,
        manifestURL: root.appendingPathComponent("manifest.json")))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("incoming/test-model").path))
  }

  @MainActor
  func testStoppingAudioRemovesPendingTemporaryBuffer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let audio = directory.appendingPathComponent("unit.wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeTestWave(at: audio)
    let player = BoundedAudioPlayer(capacity: 1)
    try player.enqueue(audio) {}

    player.stop()

    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  @MainActor
  func testAudioTransportPausesResumesAndClampsRate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let audio = directory.appendingPathComponent("unit.wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeTestWave(at: audio)
    let player = BoundedAudioPlayer(capacity: 1)
    try player.enqueue(audio) {}

    player.pause()
    XCTAssertFalse(player.isPlaying)
    player.seek(by: -15)
    XCTAssertFalse(player.isPlaying)
    player.setRate(3)
    XCTAssertEqual(player.rate, 2)
    let resumedAt = DispatchTime.now().uptimeNanoseconds
    player.resume()
    XCTAssertTrue(player.isPlaying)
    XCTAssertLessThanOrEqual(elapsedMilliseconds(since: resumedAt), 150)
    player.stop()
  }

  func testModelInstallerRejectsTraversalAndCorruptionWithoutPublishing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    XCTAssertThrowsError(
      try ModelPackageInstaller.decodeManifest(
        installManifest(path: "data/../escape", payload: payload, hash: digest))
    ) {
      XCTAssertEqual($0 as? ModelInstallationError, .invalidArtifactPath)
    }
    do {
      _ = try await ModelPackageInstaller.install(
        manifestData: installManifest(
          path: "data/voice.safetensors", payload: payload, hash: String(repeating: "0", count: 64)),
        containerRoot: root,
        fetch: { _ in
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          try payload.write(to: url)
          return url
        })
      XCTFail("A corrupt artifact must not be published")
    } catch {
      XCTAssertEqual(error as? ModelInstallationError, .hashMismatch)
    }
    XCTAssertNil(ModelPackageInstaller.installedModel(id: "test-model", containerRoot: root))
  }

  func testCancelledDownloadNeverPublishesAndCanRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("voice-data".utf8)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let manifest = installManifest(path: "data/voice.safetensors", payload: payload, hash: digest)
    let cancelled = Task {
      try await ModelPackageInstaller.install(
        manifestData: manifest, containerRoot: root,
        fetch: { _ in
          try await Task.sleep(for: .seconds(30))
          throw ModelInstallationError.downloadFailed
        })
    }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("Cancellation must stop publication")
    } catch {
      XCTAssertEqual(error as? ModelInstallationError, .cancelled)
    }
    XCTAssertNil(ModelPackageInstaller.installedModel(id: "test-model", containerRoot: root))

    _ = try await ModelPackageInstaller.install(
      manifestData: manifest, containerRoot: root,
      fetch: { _ in
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: url)
        return url
      })
    XCTAssertNotNil(ModelPackageInstaller.installedModel(id: "test-model", containerRoot: root))
  }

  func testInstallsCompleteRealKokoroPackageAndReopensOfflineWhenRequested() async throws {
    guard let packagePath = gateEnvironment("LECTURA_REAL_MODEL_PACKAGE"),
      let installRootPath = gateEnvironment("LECTURA_REAL_MODEL_INSTALL_ROOT")
    else { throw XCTSkip("Set real model package and install root") }
    let package = URL(fileURLWithPath: packagePath, isDirectory: true)
    let installRoot = URL(fileURLWithPath: installRootPath, isDirectory: true)
    // Only clean up a directory this test created. LECTURA_REAL_MODEL_INSTALL_ROOT is supplied by
    // hand, and pointing it at a real models folder used to wipe it recursively on the way out.
    let installRootExisted = FileManager.default.fileExists(atPath: installRoot.path)
    defer { if !installRootExisted { try? FileManager.default.removeItem(at: installRoot) } }
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifestURL = repository.appendingPathComponent(
      "models/manifests/kokoro-82m-4bit.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try ModelPackageInstaller.decodeManifest(data)
    let sources: [URL: URL] = Dictionary(
      uniqueKeysWithValues: manifest.artifacts.map {
        ($0.sourceURL, package.appendingPathComponent($0.relativePath))
      })

    let installed = try await ModelPackageInstaller.install(
      manifestData: data, containerRoot: installRoot,
      fetch: { url in
        guard let source = sources[url] else { throw ModelInstallationError.downloadFailed }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: temporary)
        return temporary
      })

    XCTAssertEqual(installed.totalSizeBytes, 284_318_454)
    XCTAssertNotNil(
      ModelPackageInstaller.installedModel(id: manifest.id, containerRoot: installRoot),
      "The verified installation must reopen without invoking the network fetcher")
  }

  func testInstallsCompleteRealTranslateGemmaPackageAndReopensOfflineWhenRequested() async throws {
    guard
      let packagePath = gateEnvironment("LECTURA_REAL_TRANSLATION_PACKAGE"),
      let installRootPath = gateEnvironment("LECTURA_REAL_MODEL_INSTALL_ROOT")
    else { throw XCTSkip("Set real translation model package and install root") }
    let package = URL(fileURLWithPath: packagePath, isDirectory: true)
    let installRoot = URL(fileURLWithPath: installRootPath, isDirectory: true)
    // Only clean up a directory this test created. LECTURA_REAL_MODEL_INSTALL_ROOT is supplied by
    // hand, and pointing it at a real models folder used to wipe it recursively on the way out.
    let installRootExisted = FileManager.default.fileExists(atPath: installRoot.path)
    defer { if !installRootExisted { try? FileManager.default.removeItem(at: installRoot) } }
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifestURL = repository.appendingPathComponent(
      "models/manifests/translategemma-4b-it-4bit.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try ModelPackageInstaller.decodeManifest(data)
    XCTAssertEqual(manifest.purpose, "translation")
    let sources: [URL: URL] = Dictionary(
      uniqueKeysWithValues: manifest.artifacts.map {
        ($0.sourceURL, package.appendingPathComponent($0.relativePath))
      })

    let installed = try await ModelPackageInstaller.install(
      manifestData: data, containerRoot: installRoot,
      fetch: { url in
        guard let source = sources[url] else { throw ModelInstallationError.downloadFailed }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: temporary)
        return temporary
      })

    XCTAssertEqual(installed.totalSizeBytes, 2_222_625_422)
    XCTAssertNotNil(
      ModelPackageInstaller.installedModel(id: manifest.id, containerRoot: installRoot),
      "The verified translation installation must reopen without invoking the network fetcher")
  }

  func testDownloadsImmutableRealArtifactAndReopensOfflineWhenRequested() async throws {
    guard gateEnvironment("LECTURA_REAL_NETWORK_TEST") == "1",
      let installRootPath = gateEnvironment("LECTURA_REAL_MODEL_INSTALL_ROOT")
    else { throw XCTSkip("Set real network test and install root") }
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let canonical = try Data(
      contentsOf: repository.appendingPathComponent(
        "models/manifests/kokoro-82m-4bit.json"))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any])
    let artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
    object["id"] = "kokoro-82m-4bit-network-check"
    object["artifacts"] = [try XCTUnwrap(artifacts.first)]
    let manifestData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let installRoot = URL(fileURLWithPath: installRootPath, isDirectory: true)
    // Only clean up a directory this test created. LECTURA_REAL_MODEL_INSTALL_ROOT is supplied by
    // hand, and pointing it at a real models folder used to wipe it recursively on the way out.
    let installRootExisted = FileManager.default.fileExists(atPath: installRoot.path)
    defer { if !installRootExisted { try? FileManager.default.removeItem(at: installRoot) } }

    let installed = try await ModelPackageInstaller.install(
      manifestData: manifestData, containerRoot: installRoot)

    XCTAssertEqual(installed.totalSizeBytes, 2_412)
    XCTAssertNotNil(
      ModelPackageInstaller.installedModel(
        id: "kokoro-82m-4bit-network-check", containerRoot: installRoot))
  }

  @MainActor
  func testGateAHarnessUsesSessionHostPdfKitRustPlanAndRealKokoroRuntime() async throws {
    try await runNativeHarness(pdfName: "es-single-digital.pdf", forceOCR: false) { document in
      try XCTUnwrap(DocumentServices.extractDigitalPages(from: document).first?.blocks.first)
    }
  }

  @MainActor
  func testGateAHarnessUsesVisionOCRAndRealKokoroRuntime() async throws {
    try await runNativeHarness(pdfName: "es-single-scanned.pdf", forceOCR: true) { document in
      try XCTUnwrap(
        DocumentServices.extractOCRPages(from: document, pageIndexes: [0], language: "es")
          .first?.blocks.first)
    }
  }

  @MainActor
  func testNarratesTextExtractedFromRealBibliographyPDF() throws {
    let modelRoot =
      gateEnvironment("LECTURA_MODEL_ROOT") ?? "/Volumes/Extreme SSD/LecturaFluida-Models"
    let pdfPath =
      gateEnvironment("LECTURA_REAL_PDF")
      ?? "/Users/jailiivinaibuelvasdiaz/Proyectos/academico/projects/children-of-the-state/02-literature/bibliography/sources/TH-DC/Moreno2000-fulltext.pdf"
    guard FileManager.default.fileExists(atPath: modelRoot),
      FileManager.default.fileExists(atPath: pdfPath)
    else { throw XCTSkip("Real bibliography PDF and external Kokoro model are required") }
    let document = try DocumentServices.openReadOnly(at: URL(fileURLWithPath: pdfPath))
    let text = try XCTUnwrap(
      DocumentServices.extractDigitalPages(from: document, pageLimit: 5)
        .flatMap(\.blocks).map(\.text).first(where: { $0.count >= 80 }))
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "real-bibliography-narration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }

    let result = try ModelServices.synthesize(
      TTSSynthesisRequest(
        modelId: "kokoro-82m-4bit",
        modelRevision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
        runtimeId: "mlx-audio-swift", runtimeVersion: "v0.1.3",
        voiceId: "ef_dora", language: "es", rawIPA: false,
        units: [TTSUnitRequest(unitId: "real-pdf-unit", text: String(text.prefix(300)))]),
      runtimeURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
        "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts"),
      modelURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
        "verified-packages/kokoro-82m-4bit/data", isDirectory: true), workRoot: work)

    XCTAssertEqual(result.segments.first?.unitId, "real-pdf-unit")
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))
  }

  @MainActor
  func testAudiobookExporterUsesRealBibliographyAndKokoroWithinNFR5() async throws {
    guard gateEnvironment("LECTURA_EXPORT_RUNTIME_TEST") == "1" else {
      throw XCTSkip("Set LECTURA_EXPORT_RUNTIME_TEST=1 for the bounded real export gate")
    }
    let modelRoot =
      gateEnvironment("LECTURA_MODEL_ROOT") ?? "/Volumes/Extreme SSD/LecturaFluida-Models"
    let pdfPath =
      gateEnvironment("LECTURA_REAL_PDF")
      ?? "/Users/jailiivinaibuelvasdiaz/Proyectos/academico/projects/children-of-the-state/02-literature/bibliography/sources/TH-DC/Moreno2000-fulltext.pdf"
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifest = try ModelPackageInstaller.decodeManifest(
      Data(contentsOf: root.appendingPathComponent("models/manifests/kokoro-82m-4bit.json")))
    let pdfURL = URL(fileURLWithPath: pdfPath)
    let document = try DocumentServices.openReadOnly(at: pdfURL)
    let source = DocumentServices.extractDigitalPages(from: document, pageLimit: 5)
      .flatMap(\.blocks).map(\.text).joined(separator: " ")
    guard source.count >= 600 else { throw XCTSkip("The real PDF did not yield enough text") }
    let units = stride(from: 0, to: 600, by: 200).map { (offset: Int) -> AudiobookExportUnit in
      let start = source.index(source.startIndex, offsetBy: offset)
      let end = source.index(
        start, offsetBy: min(200, source.distance(from: start, to: source.endIndex)))
      let id = "real-unit-\(offset / 200 + 1)"
      return AudiobookExportUnit(unitID: id, text: String(source[start..<end]), anchorID: id)
    }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "real-audiobook-export-\(UUID().uuidString)")
    let destination = work.appendingPathComponent("real-validation.m4b")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let initialSwap = try swapoutPages()
    let initialThermal = thermalStateName(ProcessInfo.processInfo.thermalState)
    let memory = ProcessTreeSampler(rootPID: ProcessInfo.processInfo.processIdentifier)
    let started = DispatchTime.now().uptimeNanoseconds

    let output = try await AudiobookExporter.export(
      AudiobookExportRequest(
        jobID: "real-export", sourceFingerprint: sha256(Data(contentsOf: pdfURL)),
        title: "Real export validation", language: "es", voiceID: "ef_dora", units: units,
        model: manifest,
        modelURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
          "verified-packages/kokoro-82m-4bit/data", isDirectory: true),
        runtimeURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
          "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts"),
        destinationURL: destination, workRoot: work.appendingPathComponent("jobs")))

    let elapsedMs = elapsedMilliseconds(since: started)
    let peakRSS = memory.stop()
    let asset = AVURLAsset(url: output)
    let durationMs = try await asset.load(.duration).seconds * 1_000
    let finalSwap = try swapoutPages()
    let finalThermal = thermalStateName(ProcessInfo.processInfo.thermalState)
    let rtf = Double(elapsedMs) / max(1, durationMs)
    let checks = [
      "unit_count": units.count == 3,
      "real_time_factor": rtf <= 0.5,
      "memory": peakRSS <= 6 * 1_024 * 1_024 * 1_024,
      "swap": finalSwap == initialSwap,
      "thermal": finalThermal != "critical",
    ]
    let evidence: [String: Any] = try [
      "schema_version": 1, "scenario": "bounded_real_audiobook_export",
      "source_sha256": sha256(Data(contentsOf: pdfURL)), "unit_count": units.count,
      "elapsed_ms": elapsedMs, "audio_duration_ms": durationMs, "real_time_factor": rtf,
      "peak_rss_bytes": peakRSS, "swapout_pages_delta": max(0, finalSwap - initialSwap),
      "initial_thermal_state": initialThermal, "final_thermal_state": finalThermal,
      "output_bytes": output.resourceValues(forKeys: Set<URLResourceKey>([.fileSizeKey]))
        .fileSize ?? 0,
      "checks": checks,
    ]
    let evidenceURL = URL(
      fileURLWithPath: gateEnvironment("LECTURA_EXPORT_EVIDENCE")
        ?? "/private/tmp/lectura-story43-export-evidence.json")
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidenceURL, options: .atomic)
    XCTAssertTrue(checks.values.allSatisfy { $0 })
  }

  /// Story 5.9 AC1/AC3/AC4: a real, small translated export — TranslateGemma resolving each unit's
  /// text one at a time (never pre-translating the whole batch) interleaved with real Kokoro
  /// synthesis in the target language. Verifies the exporter actually narrates the *translation*
  /// (not the source) and that each fragment's id traces back to its source unit.
  func testAudiobookExporterNarratesARealTranslationOneUnitAtATimeWithTraceableFragments()
    async throws
  {
    guard gateEnvironment("LECTURA_EXPORT_RUNTIME_TEST") == "1" else {
      throw XCTSkip("Set LECTURA_EXPORT_RUNTIME_TEST=1 for the bounded real export gate")
    }
    let modelRoot =
      gateEnvironment("LECTURA_MODEL_ROOT") ?? "/Volumes/Extreme SSD/LecturaFluida-Models"
    // Must be the copy embedded (and ad-hoc re-signed) inside the app bundle's Contents/Helpers —
    // the sandbox's temporary exception for "/" grants read access to external volumes but not
    // execute, so a raw build product on /Volumes fails Process.run() with no diagnosis worth
    // trusting. There is deliberately no computed fallback path here for the same reason
    // TranslationServicesTests requires it explicitly.
    guard let translationRuntimePath = gateEnvironment("LECTURA_REAL_TRANSLATION_RUNTIME") else {
      throw XCTSkip("Set LECTURA_REAL_TRANSLATION_RUNTIME to the app bundle's embedded runtime")
    }
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let voiceManifest = try ModelPackageInstaller.decodeManifest(
      Data(contentsOf: root.appendingPathComponent("models/manifests/kokoro-82m-4bit.json")))
    let translationManifest = try ModelPackageInstaller.decodeManifest(
      Data(
        contentsOf: root.appendingPathComponent(
          "models/manifests/translategemma-4b-it-4bit.json")))

    // Two short, distinct Spanish sentences — small enough to keep this gate fast, long enough to
    // catch a batch/order mixup between them.
    let sourceUnits = [
      AudiobookExportUnit(
        unitID: "u1", text: "El Estado moderno reproduce desigualdades heredadas del colonialismo.",
        anchorID: "u1"),
      AudiobookExportUnit(
        unitID: "u2", text: "Las políticas públicas rara vez cuestionan ese origen.", anchorID: "u2"
      ),
    ]
    let translateCallCount = LockedCounter()
    let translate: AudiobookExporter.Translate = { unit in
      translateCallCount.increment()
      let workRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "real-export-translate-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: workRoot) }
      let result = try TranslationServices.translate(
        TranslationRequest(
          modelId: translationManifest.id, modelRevision: translationManifest.modelRevision,
          runtimeId: translationManifest.runtimeId,
          runtimeVersion: translationManifest.runtimeVersion,
          sourceLanguage: "es", targetLanguage: "en",
          units: [TranslationUnitRequest(unitId: unit.unitID, text: unit.text)]),
        runtimeURL: URL(fileURLWithPath: translationRuntimePath),
        modelURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
          "verified-packages/translategemma-4b-it-4bit/data", isDirectory: true),
        workRoot: workRoot)
      guard
        let translated = result.translatedUnits.first(where: { $0.sourceUnitIds == [unit.unitID] }
        )
      else { throw XCTSkip("translation produced no matching unit") }
      return translated.translatedText
    }

    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "real-translated-export-\(UUID().uuidString)")
    let destination = work.appendingPathComponent("real-translated.m4b")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let output = try await AudiobookExporter.export(
      AudiobookExportRequest(
        jobID: "real-translated-export", sourceFingerprint: "translated-test",
        title: "Real translated export", language: "en", voiceID: "af_heart",
        units: sourceUnits, model: voiceManifest,
        modelURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
          "verified-packages/kokoro-82m-4bit/data", isDirectory: true),
        runtimeURL: URL(
          fileURLWithPath: gateEnvironment("LECTURA_REAL_KOKORO_RUNTIME")
            ?? "/Volumes/Extreme SSD/LecturaFluida-DerivedData/Build/Products/Debug/LecturaFluida.app/Contents/Helpers/mlx-audio-swift-tts"
        ),
        destinationURL: destination, workRoot: work.appendingPathComponent("jobs")),
      translate: translate)

    XCTAssertEqual(translateCallCount.value, 2, "cada unidad se traduce una vez, no por adelantado")
    let asset = AVURLAsset(url: output)
    let duration = try await asset.load(.duration).seconds
    XCTAssertGreaterThan(duration, 0.5, "el audio exportado debe tener contenido real")
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  /// Story 4.7 bounded resistance evidence: a real, sustained Kokoro export capped at
  /// `LECTURA_EXPORT_STRESS_CAP_SECONDS` (default 35 min) wall clock via `shouldPause`,
  /// then resumed from the on-disk checkpoint for a second bounded window — proving
  /// checkpoint/resume integrity across a real, sustained run without ever running past
  /// the owner-authorized 45-minute ceiling for this session.
  @MainActor
  func testAudiobookExporterSustainedRealExportPausesAndResumesWithinBoundedCeiling() async throws {
    guard gateEnvironment("LECTURA_EXPORT_STRESS_TEST") == "1" else {
      throw XCTSkip("Set LECTURA_EXPORT_STRESS_TEST=1 for the bounded real resistance gate")
    }
    let modelRoot =
      gateEnvironment("LECTURA_MODEL_ROOT") ?? "/Volumes/Extreme SSD/LecturaFluida-Models"
    let pdfPath =
      gateEnvironment("LECTURA_REAL_PDF")
      ?? "/Users/jailiivinaibuelvasdiaz/Proyectos/academico/projects/children-of-the-state/02-literature/bibliography/sources/TH-SL/Santos2002-fulltext.pdf"
    let phaseOneCapSeconds =
      Double(gateEnvironment("LECTURA_EXPORT_STRESS_PHASE1_SECONDS") ?? "") ?? (18 * 60)
    let phaseTwoCapSeconds =
      Double(gateEnvironment("LECTURA_EXPORT_STRESS_PHASE2_SECONDS") ?? "") ?? (15 * 60)
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifest = try ModelPackageInstaller.decodeManifest(
      Data(contentsOf: root.appendingPathComponent("models/manifests/kokoro-82m-4bit.json")))
    let pdfURL = URL(fileURLWithPath: pdfPath)
    let document = try DocumentServices.openReadOnly(at: pdfURL)
    let source = DocumentServices.extractDigitalPages(from: document, pageLimit: 80)
      .flatMap(\.blocks).map(\.text).joined(separator: " ")
    guard source.count >= 100_000 else {
      throw XCTSkip("The real PDF did not yield enough text for a sustained run")
    }
    let unitSize = 400
    let units = stride(from: 0, to: source.count - (source.count % unitSize), by: unitSize).map {
      (offset: Int) -> AudiobookExportUnit in
      let start = source.index(source.startIndex, offsetBy: offset)
      let end = source.index(
        start, offsetBy: min(unitSize, source.distance(from: start, to: source.endIndex)))
      let id = "stress-unit-\(offset / unitSize + 1)"
      return AudiobookExportUnit(unitID: id, text: String(source[start..<end]), anchorID: id)
    }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "real-audiobook-stress-\(UUID().uuidString)")
    let destination = work.appendingPathComponent("stress-validation.m4b")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let sourceHash = try sha256(Data(contentsOf: pdfURL))
    let modelURL = URL(fileURLWithPath: modelRoot).appendingPathComponent(
      "verified-packages/kokoro-82m-4bit/data", isDirectory: true)
    let runtimeURL = URL(fileURLWithPath: modelRoot).appendingPathComponent(
      "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts")
    let jobsRoot = work.appendingPathComponent("jobs")

    func request() -> AudiobookExportRequest {
      AudiobookExportRequest(
        jobID: "stress-export", sourceFingerprint: sourceHash, title: "Stress export validation",
        language: "en", voiceID: "af_heart", units: units, model: manifest, modelURL: modelURL,
        runtimeURL: runtimeURL, destinationURL: destination, workRoot: jobsRoot)
    }

    let initialSwap = try swapoutPages()
    let initialThermal = thermalStateName(ProcessInfo.processInfo.thermalState)
    let memory = ProcessTreeSampler(
      rootPID: ProcessInfo.processInfo.processIdentifier, interval: 1.0)
    let started = ProcessInfo.processInfo.systemUptime

    let manifestURL = jobsRoot.appendingPathComponent("stress-export/manifest.json")
    func fragmentCount() -> Int {
      (try? JSONDecoder().decode(
        AudiobookJobManifest.self, from: Data(contentsOf: manifestURL)))?.fragments.count ?? 0
    }

    var synthesisRetries = 0
    /// Runs export until it pauses at the deadline or completes; a real, organic
    /// `.synthesisFailed` (observed during this story's own sustained run) is treated the
    /// same way the production UI treats it (Story 4.5's `retryExport()`): retried
    /// immediately from the last verified checkpoint, bounded by the same deadline.
    func runPhase(deadline: TimeInterval) async throws -> URL? {
      while true {
        do {
          return try await AudiobookExporter.export(
            request(),
            shouldPause: { ProcessInfo.processInfo.systemUptime - started > deadline })
        } catch AudiobookExportError.paused {
          return nil
        } catch AudiobookExportError.synthesisFailed {
          synthesisRetries += 1
          guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        }
      }
    }

    var phaseOnePaused = false
    var output: URL?
    output = try await runPhase(deadline: phaseOneCapSeconds)
    if output == nil { phaseOnePaused = true }
    let unitsAfterPhaseOne = output != nil ? units.count : fragmentCount()

    var phaseTwoCompleted = output != nil
    if output == nil {
      let phaseTwoDeadline = ProcessInfo.processInfo.systemUptime - started + phaseTwoCapSeconds
      output = try await runPhase(deadline: phaseTwoDeadline)
      phaseTwoCompleted = output != nil
    }
    let unitsAfterPhaseTwo = output != nil ? units.count : fragmentCount()

    let elapsedMs = UInt64((ProcessInfo.processInfo.systemUptime - started) * 1_000)
    let peakRSS = memory.stop()
    let finalSwap = try swapoutPages()
    let finalThermal = thermalStateName(ProcessInfo.processInfo.thermalState)

    var durationMs: Double = 0
    var outputBytes = 0
    if let output {
      let asset = AVURLAsset(url: output)
      durationMs = try await asset.load(.duration).seconds * 1_000
      outputBytes =
        try output.resourceValues(forKeys: Set<URLResourceKey>([.fileSizeKey]))
        .fileSize ?? 0
    }
    let rtf = durationMs > 0 ? Double(elapsedMs) / durationMs : 0

    let checks: [String: Bool] = [
      "phase1_made_progress": unitsAfterPhaseOne > 0,
      "phase1_paused_or_completed": phaseOnePaused || output != nil,
      "resume_never_repeats_verified_units": unitsAfterPhaseTwo >= unitsAfterPhaseOne,
      "memory": peakRSS <= 6 * 1_024 * 1_024 * 1_024,
      "swap": finalSwap == initialSwap,
      "thermal": finalThermal != "critical",
      "real_time_factor_if_completed": output == nil || rtf <= 0.5,
    ]
    let evidence: [String: Any] = [
      "schema_version": 1, "scenario": "bounded_real_sustained_audiobook_export",
      "source_sha256": sourceHash, "total_units": units.count,
      "units_after_phase1": unitsAfterPhaseOne, "units_after_phase2": unitsAfterPhaseTwo,
      "phase1_paused_cleanly": phaseOnePaused, "phase2_completed": phaseTwoCompleted,
      "synthesis_retries": synthesisRetries,
      "elapsed_ms": elapsedMs, "audio_duration_ms": durationMs, "real_time_factor": rtf,
      "peak_rss_bytes": peakRSS, "swapout_pages_delta": max(0, finalSwap - initialSwap),
      "initial_thermal_state": initialThermal, "final_thermal_state": finalThermal,
      "output_bytes": outputBytes, "checks": checks,
    ]
    let evidenceURL = URL(
      fileURLWithPath: gateEnvironment("LECTURA_EXPORT_STRESS_EVIDENCE")
        ?? "/private/tmp/lectura-story47-stress-evidence.json")
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidenceURL, options: .atomic)
    XCTAssertTrue(checks.values.allSatisfy { $0 }, "\(checks)")
  }

  @MainActor
  private func runNativeHarness(
    pdfName: String,
    forceOCR: Bool,
    extract: (PDFDocument) throws -> DigitalTextBlock
  ) async throws {
    let modelRoot =
      gateEnvironment("LECTURA_MODEL_ROOT") ?? "/Volumes/Extreme SSD/LecturaFluida-Models"
    guard FileManager.default.fileExists(atPath: modelRoot) else {
      throw XCTSkip("real Kokoro artifacts are external; set LECTURA_MODEL_ROOT")
    }
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let pdfURL = root.appendingPathComponent("tests/corpus/documents/\(pdfName)")
    let appExtractionStarted = DispatchTime.now().uptimeNanoseconds
    let document = try DocumentServices.openReadOnly(at: pdfURL)
    let block = try extract(document)
    let appExtractionMilliseconds = elapsedMilliseconds(since: appExtractionStarted)
    let originalText = block.text
    let cliExtraction = try processPDFWithCLI(pdfURL, projectRoot: root, forceOCR: forceOCR)
    let cliPage = try XCTUnwrap(cliExtraction.value.pages.first)
    XCTAssertEqual(cliPage.record.route, forceOCR ? "ocr" : "direct_text")
    XCTAssertFalse(cliPage.units.isEmpty)

    let transportStarted = DispatchTime.now().uptimeNanoseconds
    let fingerprint = SHA256.hash(data: try Data(contentsOf: pdfURL))
      .map { String(format: "%02x", $0) }.joined()
    let event = try await SessionHost().openDocument(
      accessGrantID: "gate-a-harness", documentFingerprint: fingerprint,
      pageCount: UInt32(document.pageCount),
      firstPageMilliseconds: 1)
    let transportMilliseconds = elapsedMilliseconds(since: transportStarted)
    XCTAssertEqual(event.kind, .completed)
    let plan = try spokenPlan(block.text, projectRoot: root)
    XCTAssertEqual(block.text, originalText)
    let phoneticFrontendVersion = try eSpeakVersion()
    XCTAssertEqual(phoneticFrontendVersion, "1.52.0")
    let ipa = try plan.parts.map { part in
      part.kind == "punctuation" ? part.value : try phonemize(part.value, voice: plan.frontendVoice)
    }.joined(separator: " ").replacingOccurrences(of: " ".appending("."), with: ".")

    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gate-a-native-\(UUID())")
    defer { try? FileManager.default.removeItem(at: output) }
    let appMemory = ProcessTreeSampler(rootPID: ProcessInfo.processInfo.processIdentifier)
    let appStarted = DispatchTime.now().uptimeNanoseconds
    let result = try ModelServices.synthesize(
      TTSSynthesisRequest(
        modelId: "kokoro-82m-4bit", modelRevision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
        runtimeId: "mlx-audio-swift", runtimeVersion: "v0.1.3", voiceId: "ef_dora",
        language: "es", rawIPA: true, units: [TTSUnitRequest(unitId: "gate-a-unit", text: ipa)]),
      runtimeURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
        "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts"),
      modelURL: URL(fileURLWithPath: modelRoot).appendingPathComponent(
        "verified-packages/kokoro-82m-4bit/data", isDirectory: true), workRoot: output)
    let appRuntimeMilliseconds = elapsedMilliseconds(since: appStarted)
    let appPeakRSSBytes = appMemory.stop()
    XCTAssertFalse(result.segments.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))

    let cliMemory = ProcessTreeSampler(rootPID: ProcessInfo.processInfo.processIdentifier)
    let cli = try synthesizeWithCLI(ipa, projectRoot: root, modelRoot: modelRoot)
    let cliPeakRSSBytes = cliMemory.stop()
    XCTAssertEqual(cli.value.modelId, result.modelId)
    XCTAssertEqual(cli.value.modelRevision, result.modelRevision)
    XCTAssertEqual(cli.value.runtimeId, result.runtimeId)
    XCTAssertEqual(cli.value.runtimeVersion, result.runtimeVersion)
    XCTAssertEqual(cli.value.voiceId, result.voiceId)
    XCTAssertEqual(cli.value.language, result.language)
    XCTAssertEqual(cli.value.segments.map(\.sampleRateHz), result.segments.map(\.sampleRateHz))
    attachParityReport(
      RuntimeParityReport(
        route: forceOCR ? "ocr" : "direct_text", runtimeID: result.runtimeId,
        runtimeVersion: result.runtimeVersion, phoneticFrontendVersion: phoneticFrontendVersion,
        appExtractionMilliseconds: appExtractionMilliseconds,
        cliExtractionMilliseconds: cliExtraction.elapsedMilliseconds,
        transportMilliseconds: transportMilliseconds,
        appRuntimeMilliseconds: appRuntimeMilliseconds,
        cliRuntimeMilliseconds: cli.elapsedMilliseconds, appPeakRSSBytes: appPeakRSSBytes,
        cliPeakRSSBytes: cliPeakRSSBytes))
  }
  func testChunksPreferNearbyPunctuationWithoutExceedingThirtyWords() {
    var words = (0..<85).map { "palabra\($0)" }
    words[25] += ","
    words[55] += "."

    let chunks = ModelServices.chunks(words.joined(separator: " "))

    XCTAssertEqual(chunks.count, 3)
    XCTAssertTrue(chunks[0].hasSuffix(","))
    XCTAssertTrue(chunks[1].hasSuffix("."))
    XCTAssertTrue(chunks.allSatisfy { $0.split(separator: " ").count <= 30 })
  }

  func testRepeatedEarlyPunctuationCannotOverflowTheLastChunk() {
    let words = (0..<2_300).map { index in
      index % 22 == 21 ? "palabra\(index)." : "palabra\(index)"
    }

    let chunks = ModelServices.chunks(words.joined(separator: " "))

    XCTAssertTrue(chunks.allSatisfy { $0.split(separator: " ").count <= 30 })
    XCTAssertEqual(chunks.flatMap { $0.split(separator: " ") }.count, words.count)
  }

  func testManualRenderPauseResumeMeetsNFR4WithoutAudioOutput() throws {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()
    defer { engine.stop() }

    let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    source.frameLength = 4_800
    player.scheduleBuffer(source)
    player.play()
    let rendered = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
    XCTAssertEqual(try engine.renderOffline(512, to: rendered), .success)
    XCTAssertGreaterThan(rendered.frameLength, 0)

    player.pause()
    XCTAssertFalse(player.isPlaying)
    let resumedAt = DispatchTime.now().uptimeNanoseconds
    player.play()
    let resumeMilliseconds = elapsedMilliseconds(since: resumedAt)
    rendered.frameLength = 0
    XCTAssertEqual(try engine.renderOffline(512, to: rendered), .success)
    XCTAssertGreaterThan(rendered.frameLength, 0)
    XCTAssertLessThanOrEqual(resumeMilliseconds, 150)
    print("STORY_1_7_PAUSE_RESUME_MS \(resumeMilliseconds)")
    let report = try JSONEncoder().encode(["pause_resume_ms": resumeMilliseconds])
    let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
    attachment.name = "manual-pause-resume.json"
    add(attachment)
  }

  func testBalancesChunksAndProducesContiguousTrace() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("model-services-test-\(UUID().uuidString)", isDirectory: true)
    let model = root.appendingPathComponent("model", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let source = root.appendingPathComponent("source.wav")
    let runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTestWave(at: source)
    try Data(
      "#!/bin/sh\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"--output\" ]; then cp \"$SOURCE_WAV\" \"$2\"; exit 0; fi\n  shift\ndone\nexit 2\n"
        .utf8
    ).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    setenv("SOURCE_WAV", source.path, 1)
    defer { unsetenv("SOURCE_WAV") }
    let text = (0..<85).map { "palabra\($0)" }.joined(separator: " ")

    let result = try ModelServices.synthesize(
      TTSSynthesisRequest(
        modelId: "kokoro-82m-4bit",
        modelRevision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
        runtimeId: "mlx-audio-swift",
        runtimeVersion: "v0.1.3",
        voiceId: "ef_dora",
        language: "es",
        rawIPA: false,
        units: [TTSUnitRequest(unitId: "unit", text: text)]),
      runtimeURL: runtime, modelURL: model, workRoot: work)

    XCTAssertEqual(result.segments.count, 3)
    XCTAssertEqual(result.segments.map(\.segmentIndex), [0, 1, 2])
    XCTAssertEqual(result.segments.map(\.unitSampleOffset), [0, 2_400, 4_800])
    XCTAssertEqual(result.segments.map(\.sampleCount), [2_400, 2_400, 2_400])
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioPath))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: work.path).sorted(), ["narration.wav"])
  }

  func testRuntimeFailureRemovesOwnedWorkRoot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("model-services-failure-\(UUID().uuidString)", isDirectory: true)
    let model = root.appendingPathComponent("model", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)

    XCTAssertThrowsError(
      try ModelServices.synthesize(
        TTSSynthesisRequest(
          modelId: "kokoro-82m-4bit",
          modelRevision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
          runtimeId: "mlx-audio-swift",
          runtimeVersion: "v0.1.3",
          voiceId: "ef_dora",
          language: "es",
          rawIPA: false,
          units: [TTSUnitRequest(unitId: "unit", text: "Texto verificable")]),
        runtimeURL: runtime, modelURL: model, workRoot: work)
    ) { error in
      XCTAssertEqual(error as? ModelServiceError, .synthesisFailed)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
  }

  func testRawIPAIsForwardedOnlyToKokoroRuntime() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("model-services-ipa-\(UUID().uuidString)", isDirectory: true)
    let model = root.appendingPathComponent("model", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let source = root.appendingPathComponent("source.wav")
    let arguments = root.appendingPathComponent("arguments.txt")
    let runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTestWave(at: source)
    try Data(
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGUMENTS_FILE\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"--output\" ]; then cp \"$SOURCE_WAV\" \"$2\"; exit 0; fi\n  shift\ndone\nexit 2\n"
        .utf8
    ).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    setenv("SOURCE_WAV", source.path, 1)
    setenv("ARGUMENTS_FILE", arguments.path, 1)
    defer {
      unsetenv("SOURCE_WAV")
      unsetenv("ARGUMENTS_FILE")
    }

    _ = try ModelServices.synthesize(
      TTSSynthesisRequest(
        modelId: "kokoro-82m-4bit",
        modelRevision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
        runtimeId: "mlx-audio-swift", runtimeVersion: "v0.1.3",
        voiceId: "ef_dora", language: "es", rawIPA: true,
        units: [TTSUnitRequest(unitId: "unit", text: "tˈeksto.")]),
      runtimeURL: runtime, modelURL: model, workRoot: work)

    XCTAssertTrue(try String(contentsOf: arguments, encoding: .utf8).contains("--raw-ipa"))
  }

  private struct SpokenPlan: Decodable {
    let frontendVoice: String
    let parts: [SpokenPart]
    enum CodingKeys: String, CodingKey {
      case frontendVoice = "frontend_voice"
      case parts
    }
  }

  private struct SpokenPart: Decodable {
    let kind: String
    let value: String
  }
  private struct CLIResponse: Decodable {
    let kind: String
    let result: TTSSynthesisResult?
  }
  private struct CLIExtractionResponse: Decodable {
    let kind: String
    let result: CLIProcessedDocument?
  }
  private struct CLIProcessedDocument: Decodable { let pages: [CLIProcessedPage] }
  private struct CLIProcessedPage: Decodable {
    let record: CLIPageRecord
    let units: [CLIUnit]
  }
  private struct CLIPageRecord: Decodable { let route: String }
  private struct CLIUnit: Decodable { let unitId: String }
  private struct Measured<T> {
    let value: T
    let elapsedMilliseconds: UInt64
  }
  private struct RuntimeParityReport: Encodable {
    let route: String
    let runtimeID: String
    let runtimeVersion: String
    let phoneticFrontendVersion: String
    let appExtractionMilliseconds: UInt64
    let cliExtractionMilliseconds: UInt64
    let transportMilliseconds: UInt64
    let appRuntimeMilliseconds: UInt64
    let cliRuntimeMilliseconds: UInt64
    let appPeakRSSBytes: UInt64
    let cliPeakRSSBytes: UInt64
  }

  private func spokenPlan(_ text: String, projectRoot: URL) throws -> SpokenPlan {
    let process = Process()
    process.executableURL = projectRoot.appendingPathComponent("target/release/lectura")
    process.arguments = ["spoken", "plan", "--language", "es", "--json"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data(text.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ModelServiceError.synthesisFailed }
    return try JSONDecoder().decode(SpokenPlan.self, from: data)
  }

  private func phonemize(_ text: String, voice: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/espeak-ng")
    process.arguments = ["-q", "--ipa=3", "-v", voice, "--stdin"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data("\(text)\n".utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ModelServiceError.synthesisFailed }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func eSpeakVersion() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/espeak-ng")
    process.arguments = ["--version"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let banner = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0,
      let marker = banner.range(of: "text-to-speech:"),
      let version = banner[marker.upperBound...].split(whereSeparator: \.isWhitespace).first
    else { throw ModelServiceError.synthesisFailed }
    return String(version)
  }

  private func synthesizeWithCLI(
    _ ipa: String, projectRoot: URL, modelRoot: String
  ) throws -> Measured<TTSSynthesisResult> {
    let process = Process()
    process.executableURL = projectRoot.appendingPathComponent("target/release/lectura")
    process.arguments = ["tts", "synthesize", "--request", "-", "--json"]
    var environment = ProcessInfo.processInfo.environment
    environment["LECTURA_MACOS_WORKER"] =
      projectRoot.appendingPathComponent("target/lectura-macos-worker").path
    environment["LECTURA_TTS_MANIFEST"] =
      projectRoot.appendingPathComponent(
        "models/manifests/kokoro-82m-4bit.json"
      ).path
    environment["LECTURA_TTS_PACKAGE"] = "\(modelRoot)/verified-packages/kokoro-82m-4bit"
    environment["LECTURA_TTS_RUNTIME"] =
      "\(modelRoot)/runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts"
    environment["LECTURA_TTS_MODEL"] = "\(modelRoot)/verified-packages/kokoro-82m-4bit/data"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let started = DispatchTime.now().uptimeNanoseconds
    try process.run()
    let request = TTSSynthesisRequest(
      modelId: "kokoro-82m-4bit", modelRevision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
      runtimeId: "mlx-audio-swift", runtimeVersion: "v0.1.3", voiceId: "ef_dora",
      language: "es", rawIPA: true, units: [TTSUnitRequest(unitId: "runtime-parity", text: ipa)])
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    input.fileHandleForWriting.write(try encoder.encode(request))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ModelServiceError.synthesisFailed }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = try decoder.decode(CLIResponse.self, from: data)
    guard response.kind == "completed", let result = response.result else {
      throw ModelServiceError.synthesisFailed
    }
    return Measured<TTSSynthesisResult>(
      value: result, elapsedMilliseconds: elapsedMilliseconds(since: started))
  }

  private func processPDFWithCLI(
    _ pdfURL: URL, projectRoot: URL, forceOCR: Bool
  ) throws -> Measured<CLIProcessedDocument> {
    let process = Process()
    process.executableURL = projectRoot.appendingPathComponent("target/release/lectura")
    process.arguments = [
      "pdf", "process", "--input", pdfURL.path, "--language", "es", "--unit", "paragraph", "--json",
    ]
    if forceOCR { process.arguments?.append(contentsOf: ["--force-ocr-page", "0"]) }
    var environment = ProcessInfo.processInfo.environment
    environment["LECTURA_MACOS_WORKER"] =
      projectRoot.appendingPathComponent("target/lectura-macos-worker").path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    let started = DispatchTime.now().uptimeNanoseconds
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ModelServiceError.synthesisFailed }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = try decoder.decode(CLIExtractionResponse.self, from: data)
    guard response.kind == "completed", let result = response.result else {
      throw ModelServiceError.synthesisFailed
    }
    return Measured<CLIProcessedDocument>(
      value: result, elapsedMilliseconds: elapsedMilliseconds(since: started))
  }

  private func elapsedMilliseconds(since started: UInt64) -> UInt64 {
    (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
  }

  private func installManifest(path: String, payload: Data, hash: String) -> Data {
    Data(
      """
      {"schema_version":1,"id":"test-model","model_revision":"revision123","artifact_revision":"revision123","purpose":"tts","authors":["author"],"license_id":"Apache-2.0","usage_restrictions":["reviewed"],"languages":["es"],"voices":["voice"],"runtime_id":"mlx-audio-swift","runtime_version":"v0.1.3","distribution_status":"pending_review","artifacts":[{"relative_path":"\(path)","role":"voice_embedding","source_url":"https://example.invalid/revision123/voice.safetensors","publisher":"publisher","format":"safetensors","quantization":"f32","size_bytes":\(payload.count),"sha256_hex":"\(hash)"}]}
      """.utf8)
  }

  @MainActor
  private func attachParityReport(_ report: RuntimeParityReport) {
    guard let data = try? JSONEncoder().encode(report) else { return }
    XCTContext.runActivity(named: "gate-a runtime parity") { activity in
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "runtime-parity.json"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
  }
}

private func makeSingleUnitResult(_ request: TTSSynthesisRequest, _ audio: URL)
  -> TTSSynthesisResult
{
  TTSSynthesisResult(
    modelId: request.modelId, modelRevision: request.modelRevision,
    runtimeId: request.runtimeId, runtimeVersion: request.runtimeVersion,
    voiceId: request.voiceId, language: request.language, audioPath: audio.path,
    segments: [
      NarrationSegmentResult(
        unitId: request.units[0].unitId, segmentIndex: 0, unitSampleOffset: 0,
        sampleCount: 2_400, sampleRateHz: 24_000, elapsedMs: 1, artifactHash: nil,
        modelRevision: request.modelRevision, voiceId: request.voiceId)
    ], omittedUnitIds: [])
}

private func writeTestWave(at url: URL) throws {
  let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
  buffer.frameLength = 2_400
  try file.write(from: buffer)
}

private func writeConstantWave(
  at url: URL, amplitude: Float, frameCount: AVAudioFrameCount = 24_000
)
  throws
{
  let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
  buffer.frameLength = frameCount
  if let channelData = buffer.floatChannelData {
    for index in 0..<Int(frameCount) { channelData[0][index] = amplitude }
  }
  try file.write(from: buffer)
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func swapoutPages() throws -> Int {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
  let output = Pipe()
  process.standardOutput = output
  try process.run()
  let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  process.waitUntilExit()
  guard process.terminationStatus == 0,
    let value = text.firstMatch(of: /Swapouts:\s+(\d+)\./)?.1,
    let pages = Int(value)
  else { throw CocoaError(.fileReadUnknown) }
  return pages
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
  switch state {
  case .nominal: "nominal"
  case .fair: "fair"
  case .serious: "serious"
  case .critical: "critical"
  @unknown default: "unknown"
  }
}

private final class ProcessTreeSampler: @unchecked Sendable {
  private let rootPID: Int32
  private let interval: TimeInterval
  private let lock = NSLock()
  private var active = true
  private var peak: UInt64 = 0

  /// `interval` trades sampling resolution for `/bin/ps` spawn volume: the default 20ms
  /// suits short bounded tests, but sustained runs of many minutes must widen it — spawning
  /// tens of thousands of subprocesses eventually exhausts file descriptors (observed as a
  /// real "Bad file descriptor" failure during Story 4.7's sustained resistance test).
  init(rootPID: Int32, interval: TimeInterval = 0.02) {
    self.rootPID = rootPID
    self.interval = interval
    sample()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      while let self, self.isActive {
        self.sample()
        Thread.sleep(forTimeInterval: self.interval)
      }
    }
  }

  func stop() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    active = false
    return peak
  }

  private var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  private func sample() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,rss="]
    let output = Pipe()
    process.standardOutput = output
    guard (try? process.run()) != nil else { return }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
      line -> (Int32, Int32, UInt64)? in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
        let rss = UInt64(fields[2])
      else { return nil }
      return (pid, parent, rss * 1_024)
    }
    var children = [Int32: [Int32]]()
    var rss = [Int32: UInt64]()
    for (pid, parent, bytes) in rows {
      children[parent, default: []].append(pid)
      rss[pid] = bytes
    }
    var pending = [rootPID]
    var total: UInt64 = 0
    while let pid = pending.popLast() {
      total += rss[pid] ?? 0
      pending.append(contentsOf: children[pid] ?? [])
    }
    lock.lock()
    peak = max(peak, total)
    lock.unlock()
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
