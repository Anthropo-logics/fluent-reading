import AppKit
import MacPlatform
import OSLog
import Observation
import PDFKit

enum ReaderState: Equatable {
  case empty
  case opening
  case reading
  case failed(DocumentOpenError)
}

enum ReadingSurface: String, CaseIterable, Identifiable {
  case pdf
  case immersion

  var id: Self { self }
}

enum TrackingUnit: String, CaseIterable, Identifiable {
  case paragraph
  case sentence

  var id: Self { self }
}

enum VoicePreparationState: Equatable {
  case available
  case ready
  case downloading
  case installed
  case cancelled
  case failed
}

enum VoicePreparationFailure: Equatable {
  case missingModel
  case incompatible
  case corruptArtifact
  case interruptedDownload
  case insufficientSpace
  case loadFailed
}

enum TranslationProgressState: Equatable {
  case idle
  case translating
  case cancelled
  case failed
}

enum NarrationState: Equatable {
  case idle
  case preparing
  case playing
  case paused
  case awaitingContent
  case finished
  case failed
  case awaitingTranslation
  case translationFailed
  case missingTranslationVoice
  case missingVoiceRuntime
  case missingVoiceModel
}

enum NarrationSource: Equatable {
  case original
  case translation
}

enum AudiobookExportState: Equatable {
  case idle
  case preparing
  case exporting
  case paused
  case completed(URL)
  case cancelled
  case failed(AudiobookExportError)
}

@MainActor
@Observable
final class ReaderViewModel {
  private static let metrics = Logger(subsystem: "com.lecturafluida.app", category: "performance")
  /// Story 6.17/6.18: writing outside the app's own container is where this app fails in ways the
  /// interface cannot describe — an export that never starts, a recognised-text write that is only
  /// ever reported as "could not be kept". Both paths say here, in the log, what actually happened.
  private static let exportLog = Logger(subsystem: "com.lecturafluida.app", category: "writing")
  private(set) var state: ReaderState = .empty
  private(set) var document: PDFDocument?
  private(set) var pageIndex = 0
  private(set) var firstPageMilliseconds: UInt64?
  private(set) var processingSession: LFIncrementalSessionResult?
  private(set) var processingCancelled = false
  private(set) var processingStorageFailed = false
  private(set) var firstUnitAvailable = false
  private(set) var normalizedPages: [UInt32: LFNormalizedPage] = [:]
  private(set) var normalizedSentencePages: [UInt32: LFNormalizedPage] = [:]
  var readingSurface: ReadingSurface = .pdf {
    didSet { ReaderSurfaceCoordinator.shared.surface = readingSurface }
  }
  var trackingUnit: TrackingUnit = .paragraph {
    didSet { selectFirstUnitForCurrentPage() }
  }
  private(set) var currentUnitID: String?
  private(set) var storageBytes: UInt64 = 0
  /// What the open document turned out to be written in, or nil while that is unknown — either
  /// because nothing has been read yet or because the document could not say (Story 6.11).
  private(set) var identifiedDocumentLanguage: DocumentLanguage.Identification?
  /// The language every engine call for this document uses. Falls back to the value the whole app
  /// used to hardcode, so an unidentifiable document behaves exactly as it did before (AC3).
  var documentLanguage: String {
    identifiedDocumentLanguage?.language ?? DocumentLanguage.fallback
  }
  private(set) var voiceManifest: InstallableModelManifest?
  private(set) var voicePreparationState: VoicePreparationState = .available
  private(set) var voicePreparationFailure: VoicePreparationFailure?
  private(set) var voiceCompletedBytes: UInt64 = 0
  var selectedVoiceLanguage = ""
  var selectedVoiceID = ""
  private(set) var translationManifest: InstallableModelManifest?
  private(set) var translationPreparationState: VoicePreparationState = .available
  private(set) var translationPreparationFailure: VoicePreparationFailure?
  private(set) var translationCompletedBytes: UInt64 = 0
  var translationTargetLanguage = ""
  private(set) var translationRequested = false
  /// Lets the reader hold the original in view while a translation exists, to compare the two.
  private(set) var showingOriginalText = false
  private(set) var translationStatuses: [String: TranslationUnitStatus] = [:]
  private(set) var translationProgressState: TranslationProgressState = .idle
  private(set) var narrationState: NarrationState = .idle
  private(set) var narrationSkippedCount = 0
  private(set) var narrationSource: NarrationSource = .original
  var narrationRate = 1.0 {
    didSet { audioPlayer.setRate(Float(narrationRate)) }
  }
  var exportTitle = ""
  private(set) var exportDestination: URL?
  private(set) var exportState: AudiobookExportState = .idle
  private(set) var exportCompletedUnits = 0
  private(set) var exportTotalUnits = 0
  private(set) var exportStartedAt: Date?
  @ObservationIgnored private var grant: ReadAccessGrant?
  @ObservationIgnored private var openedAt: ContinuousClock.Instant?
  @ObservationIgnored private var reportingTask: Task<Void, Never>?
  @ObservationIgnored private var documentFingerprint: String?
  /// Reads the head of the document's text layer while it opens; awaited once, before the first
  /// page reaches the engine, so no page is ever normalised under a language that later changes.
  @ObservationIgnored
  private var languageIdentification: Task<DocumentLanguage.Identification?, Never>?
  @ObservationIgnored private var outlinePrescanTask: Task<Void, Never>?
  /// A scan has no text layer to identify from, so the first recognised pages stand in for it. The
  /// count runs down, which is what stops a book with a long quotation in another language from
  /// re-deciding its language as the reader moves through it (AC5).
  @ObservationIgnored private var languagePagesLeftToSample = 0
  @ObservationIgnored private var recognisedLanguageSample = ""
  /// Set once the reader picks a language by hand, so a voice model finishing its install later
  /// does not overrule the choice with the document's language.
  @ObservationIgnored private var voiceLanguageChosenByReader = false
  @ObservationIgnored private var forcedOCRPages: Set<UInt32> = []
  /// The orientation the reader chose for a page, when the document's own `/Rotate` does not match
  /// how the page is actually printed — a landscape table set across a portrait page, a sheet fed
  /// into the scanner the wrong way round. Kept for this reading only; the file is never modified.
  private(set) var pageRotationOverrides: [UInt32: Int] = [:]
  /// Pages this reading session had to recognise with OCR because the document's own text layer was
  /// unusable, and which could take that text permanently. Offered back to the reader when the
  /// document closes (Story 6.6); dropped, never written, if the reader declines.
  @ObservationIgnored private var recognisedPagesToKeep: [UInt32: DigitalPageResult] = [:] {
    didSet {
      DocumentCloseCoordinator.shared.hasRecognisedTextToKeep = !recognisedPagesToKeep.isEmpty
    }
  }
  /// The pages the reader has just agreed to keep, between the confirmation and the write.
  @ObservationIgnored private var pagesAwaitingWrite: [UInt32: DigitalPageResult] = [:]
  /// Identifies the current run of narration. Stopping bumps it, which is what lets a playback
  /// completion handler from the previous run tell that it is stale and stay quiet.
  @ObservationIgnored private var narrationGeneration = 0
  /// Table of contents read off the PDF text layer when the document opens; see
  /// `DocumentServices.prescanHeadings`.
  private var prescannedOutline: [DocumentOutlineEntry] = []
  @ObservationIgnored private var voicePreparationTask: Task<Void, Never>?
  @ObservationIgnored private var translationPreparationTask: Task<Void, Never>?
  @ObservationIgnored private var translationProgressTask: Task<Void, Never>?
  private static let translationWindowSize = 5
  @ObservationIgnored private var modelStorageRoot: URL?
  @ObservationIgnored private var modelStorageHasSecurityScope = false
  @ObservationIgnored private let audioPlayer = BoundedAudioPlayer(capacity: 2)
  @ObservationIgnored private var narrationTask: Task<Void, Never>?
  @ObservationIgnored private var exportTask: Task<Void, Never>?
  @ObservationIgnored private var exportJobID: String?
  @ObservationIgnored private var exportPauseRequested = false
  @ObservationIgnored private var exportReplaceExisting = false
  @ObservationIgnored private var exportDestinationHasSecurityScope = false
  @ObservationIgnored private var exportDestinationScopeURL: URL?
  @ObservationIgnored private var narrationUnits: [LFReadingUnit] = []
  @ObservationIgnored private var narrationIndex = 0
  #if STRESS_TEST
    @ObservationIgnored private var stressFailureInjected = false
  #endif

  init() {
    restoreModelStorage()
    guard let url = Bundle.main.url(forResource: "kokoro-82m-4bit", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let manifest = try? ModelPackageInstaller.decodeManifest(data)
    else {
      voicePreparationState = .failed
      voicePreparationFailure = .missingModel
      return
    }
    voiceManifest = manifest
    voicePreparationState = installedVoiceModel == nil ? .ready : .installed
    preselectVoiceIfPossible()
    if let url = Bundle.main.url(forResource: "translategemma-4b-it-4bit", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let manifest = try? ModelPackageInstaller.decodeManifest(data)
    {
      translationManifest = manifest
      translationPreparationState = installedTranslationModel == nil ? .ready : .installed
    }
  }

  var pageCount: Int { document?.pageCount ?? 0 }
  var canGoPrevious: Bool { pageIndex > 0 }
  var canGoNext: Bool { pageIndex + 1 < pageCount }
  var immersionUnits: [LFReadingUnit] {
    let pages = trackingUnit == .paragraph ? normalizedPages : normalizedSentencePages
    return pages[UInt32(pageIndex)]?.units ?? []
  }
  /// Every normalized unit in reading order, across pages. Immersion scrolls through the book
  /// rather than through one page at a time: stopping the scroll at a page boundary made the reader
  /// reach for the toolbar arrows in the middle of a sentence.
  var immersionStream: [(unit: LFReadingUnit, pageIndex: Int)] {
    let pages = trackingUnit == .paragraph ? normalizedPages : normalizedSentencePages
    return pages.keys.sorted().flatMap { key in
      (pages[key]?.units ?? []).map { ($0, Int(key)) }
    }
  }

  /// How far into the document the reader is, 0...1. Immersion shows this instead of a page
  /// number: the surface is a continuous scroll, so a page count is noise there.
  var readingProgress: Double {
    guard pageCount > 1 else { return 0 }
    return min(1, max(0, Double(pageIndex) / Double(pageCount - 1)))
  }

  /// Brings the reader's page in line with a unit chosen anywhere in the continuous scroll.
  private func alignPage(withUnit unitID: String) {
    guard let entry = immersionStream.first(where: { $0.unit.unitID == unitID }),
      entry.pageIndex != pageIndex
    else { return }
    pageIndex = entry.pageIndex
  }

  var currentSourceRegion: DigitalSourceRegion? {
    let pages = trackingUnit == .paragraph ? normalizedPages : normalizedSentencePages
    return pages[UInt32(pageIndex)]?.units
      .first(where: { $0.unitID == currentUnitID })?.sourceRegions.first
  }

  /// Automatic audio follows the same policy on screen and in an exported audiobook. Notes remain
  /// visible and traceable, but neither route inserts them into the argument being read.
  static let exportableContentClasses: Set<String> = ["prose", "heading"]

  private var exportReadyUnitsWithPages: [(unit: LFReadingUnit, pageIndex: Int)] {
    normalizedPages.keys.sorted().flatMap { key in
      (normalizedPages[key]?.units ?? [])
        .filter { ReaderViewModel.exportableContentClasses.contains($0.contentClass) }
        .map { ($0, Int(key)) }
    }
  }

  var exportReadyUnits: [LFReadingUnit] { exportReadyUnitsWithPages.map(\.unit) }

  private var exportReadyUnitPages: [Int] { exportReadyUnitsWithPages.map(\.pageIndex) }

  var exportChapters: [AudiobookChapterMark] {
    guard let document else { return [] }
    let outline = DocumentServices.outlineEntries(from: document)
    return AudiobookExporter.chapterMarks(outline: outline, unitPages: exportReadyUnitPages)
  }

  var exportDegradedUnits: Int {
    normalizedPages.values.flatMap(\.units).filter { $0.confidence < 0.7 }.count
  }

  var exportNonNarrableUnits: Int {
    normalizedPages.values.flatMap(\.units)
      .filter { !ReaderViewModel.exportableContentClasses.contains($0.contentClass) }
      .count
  }

  var exportPendingPages: Int {
    processingSession?.pages.filter { $0.state == .pending || $0.state == .processing }.count ?? 0
  }

  var exportEstimatedDurationSeconds: Double {
    Double(
      exportReadyUnits.reduce(0) {
        $0 + $1.narrationText.split(whereSeparator: \.isWhitespace).count
      })
      / 180 * 60
  }

  var exportEstimatedBytes: UInt64 { UInt64(max(0, exportEstimatedDurationSeconds * 8_000)) }

  /// Document-wide translation counts for the export preflight (Story 5.9 AC2) — how much of
  /// `exportReadyUnits` already has a translation cached from reading versus what export would still
  /// have to translate. Unlike `translationTranslatedCount`/`translationPendingCount`, which only look
  /// at the current page, exporting narrates the whole document.
  var exportTranslatedUnitsCount: Int {
    exportReadyUnits.filter {
      if case .translated = translationStatuses[$0.unitID] { return true }
      return false
    }.count
  }

  var exportTranslationFailedUnitsCount: Int {
    exportReadyUnits.filter { translationStatuses[$0.unitID] == .failed }.count
  }

  var exportTranslationPendingUnitsCount: Int {
    exportReadyUnits.count - exportTranslatedUnitsCount - exportTranslationFailedUnitsCount
  }

  var exportEstimatedDurationDescription: String {
    Duration.seconds(exportEstimatedDurationSeconds).formatted(.time(pattern: .hourMinuteSecond))
  }

  var exportEstimatedSizeDescription: String {
    ByteCountFormatter.string(fromByteCount: Int64(exportEstimatedBytes), countStyle: .file)
  }

  var exportProgress: Double {
    guard exportTotalUnits > 0 else { return 0 }
    return Double(exportCompletedUnits) / Double(exportTotalUnits)
  }

  var exportRemainingDescription: String {
    guard let exportStartedAt, exportCompletedUnits > 0 else { return "—" }
    let elapsed = Date().timeIntervalSince(exportStartedAt)
    let remaining =
      elapsed / Double(exportCompletedUnits)
      * Double(exportTotalUnits - exportCompletedUnits)
    return Duration.seconds(max(0, remaining)).formatted(.time(pattern: .hourMinuteSecond))
  }

  var exportAvailableSpaceDescription: String {
    guard let directory = exportDestination?.deletingLastPathComponent(),
      let capacity = try? directory.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ])
      .volumeAvailableCapacityForImportantUsage
    else { return "—" }
    return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
  }

  var voiceProgress: Double {
    guard let total = voiceManifest?.totalSizeBytes, total > 0 else { return 0 }
    return min(1, Double(voiceCompletedBytes) / Double(total))
  }

  var voiceStorageDescription: String {
    ByteCountFormatter.string(
      fromByteCount: Int64(voiceManifest?.totalSizeBytes ?? 0), countStyle: .file)
  }

  var availableVoiceLanguages: [String] {
    guard voicePreparationState == .installed, let voiceManifest else { return [] }
    return voiceManifest.languages.filter { !voiceManifest.voices(for: $0).isEmpty }
  }

  var availableVoiceIDs: [String] {
    voiceManifest?.voices(for: selectedVoiceLanguage) ?? []
  }

  var hasCompatibleVoiceSelection: Bool { availableVoiceIDs.contains(selectedVoiceID) }

  func selectVoiceLanguage(_ language: String) {
    guard availableVoiceLanguages.contains(language) else { return }
    voiceLanguageChosenByReader = true
    selectedVoiceLanguage = language
    if !availableVoiceIDs.contains(selectedVoiceID) { selectedVoiceID = "" }
    if !availableTranslationTargetLanguages.contains(translationTargetLanguage) {
      translationTargetLanguage = ""
    }
  }

  func selectVoice(_ voiceID: String) {
    guard availableVoiceIDs.contains(voiceID) else { return }
    selectedVoiceID = voiceID
  }

  /// An installed voice with nothing selected made Play fail with "audio unavailable" and no hint
  /// that a language and voice still had to be picked by hand. Preselect the system's preferred
  /// language when the model offers it, otherwise the first one, and its first voice.
  ///
  /// Since Story 6.11 the open document's own language comes first, which is what the reader who
  /// opened a Spanish book and heard it narrated in English was actually asking for. It only
  /// overrules a selection the reader has not made by hand for this document.
  private func preselectVoiceIfPossible() {
    guard voicePreparationState == .installed, !availableVoiceLanguages.isEmpty else { return }
    let identified = voiceLanguageChosenByReader ? nil : identifiedDocumentLanguage?.language
    if identified != nil || !availableVoiceLanguages.contains(selectedVoiceLanguage) {
      let systemPreferred = Locale.preferredLanguages
        .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
      let chosen = DocumentLanguage.preferredVoiceLanguage(
        document: identified, available: availableVoiceLanguages,
        systemPreferred: systemPreferred)
      if let chosen, chosen != selectedVoiceLanguage {
        selectedVoiceLanguage = chosen
        selectedVoiceID = ""
        if !availableTranslationTargetLanguages.contains(translationTargetLanguage) {
          translationTargetLanguage = ""
        }
      }
    }
    if !availableVoiceIDs.contains(selectedVoiceID) {
      selectedVoiceID = availableVoiceIDs.first ?? ""
    }
  }

  func prepareVoice() {
    guard let voiceManifest,
      let manifestURL = Bundle.main.url(forResource: "kokoro-82m-4bit", withExtension: "json"),
      let manifestData = try? Data(contentsOf: manifestURL),
      voicePreparationState != .downloading
    else { return }
    voicePreparationTask?.cancel()
    voicePreparationState = .downloading
    voicePreparationFailure = nil
    voiceCompletedBytes = 0
    voicePreparationTask = Task {
      do {
        _ = try await ModelPackageInstaller.install(
          manifestData: manifestData, containerRoot: modelContainerRoot,
          progress: { [weak self] update in
            Task { @MainActor in self?.voiceCompletedBytes = update.completedBytes }
          })
        voiceCompletedBytes = voiceManifest.totalSizeBytes
        voicePreparationState = .installed
        preselectVoiceIfPossible()
      } catch ModelInstallationError.cancelled {
        voicePreparationState = .cancelled
      } catch let error as ModelInstallationError {
        voicePreparationFailure = Self.voiceFailure(for: error)
        voicePreparationState = .failed
      } catch {
        voicePreparationFailure = .loadFailed
        voicePreparationState = .failed
      }
    }
  }

  func cancelVoicePreparation() {
    voicePreparationTask?.cancel()
    voicePreparationTask = nil
    voicePreparationState = .cancelled
  }

  var translationProgress: Double {
    guard let total = translationManifest?.totalSizeBytes, total > 0 else { return 0 }
    return min(1, Double(translationCompletedBytes) / Double(total))
  }

  var translationStorageDescription: String {
    ByteCountFormatter.string(
      fromByteCount: Int64(translationManifest?.totalSizeBytes ?? 0), countStyle: .file)
  }

  var translationDirections: [String] { translationManifest?.translationDirections ?? [] }

  /// Target languages available given the document's source language (AC1, AC3): the source stays
  /// the language shown in the `Voz…` flow (`selectedVoiceLanguage`), which is the one the reader
  /// can see and review. Since Story 6.11 that is the document's own identified language unless the
  /// reader changed it, so the source now follows the document without this having to read it
  /// twice.
  var availableTranslationTargetLanguages: [String] {
    translationManifest?.translationTargets(from: selectedVoiceLanguage) ?? []
  }

  func selectTranslationTargetLanguage(_ language: String) {
    guard availableTranslationTargetLanguages.contains(language) else { return }
    translationTargetLanguage = language
  }

  /// The voice used to narrate translated text (AC3, Story 5.5) — auto-selected, not a second
  /// visible voice picker: AC3 only requires "a compatible installed voice", not manual choice.
  var translationVoiceID: String? {
    guard let voiceManifest, voicePreparationState == .installed, !translationTargetLanguage.isEmpty
    else { return nil }
    return voiceManifest.voices(for: translationTargetLanguage).first
  }

  var hasVoiceForTranslationTarget: Bool { translationVoiceID != nil }

  func selectNarrationSource(_ source: NarrationSource) {
    narrationSource = source
  }

  /// Lets the reader choose where narration begins. Without it a book could only be listened to
  /// from wherever extraction happened to leave the anchor, forcing anyone who wanted a single
  /// chapter to sit through the front matter first.
  func beginReading(at unitID: String, onRequiresVoice: () -> Void) {
    alignPage(withUnit: unitID)
    guard immersionUnits.contains(where: { $0.unitID == unitID }) else { return }
    stopNarration()
    currentUnitID = unitID
    // "Read from here" starts reading. It used to resume only when narration was already playing,
    // which left the gesture doing nothing at all for a reader who had not pressed play yet — the
    // exact situation in which choosing a starting point matters most. Use `selectUnit` to move the
    // anchor without reading.
    startNarration(onRequiresVoice: onRequiresVoice)
  }

  func selectUnit(_ unitID: String) {
    alignPage(withUnit: unitID)
    guard immersionUnits.contains(where: { $0.unitID == unitID }) else { return }
    currentUnitID = unitID
  }

  /// Starts reading from the passage under a point on the rendered PDF page, so the PDF surface
  /// offers the same "read from here" gesture as the immersion view. Falls back to the closest
  /// passage when the click lands in a margin rather than exactly on a line.
  func beginReading(atPagePoint point: CGPoint, onPage page: Int, onRequiresVoice: () -> Void) {
    // The click carries the page it happened on. Matching it against the reader's current page
    // meant that after continuous narration had moved on, a double click read a passage from
    // whatever page the model had reached rather than the one on screen.
    if page != pageIndex, page >= 0, page < pageCount {
      pageIndex = page
      requestMutation(action: "reprioritize", pageIndex: UInt32(page))
    }
    let units = immersionUnits
    Self.metrics.notice(
      "narration.beginAtPoint page=\(page, privacy: .public) modelPage=\(self.pageIndex, privacy: .public) units=\(units.count, privacy: .public) y=\(Int(point.y), privacy: .public)"
    )
    guard !units.isEmpty else { return }
    let contains: (LFReadingUnit) -> Bool = { unit in
      unit.sourceRegions.contains { region in
        let rect = region.rectPDFPoints
        guard rect.count == 4 else { return false }
        return point.x >= rect[0] && point.x <= rect[0] + rect[2] && point.y >= rect[1]
          && point.y <= rect[1] + rect[3]
      }
    }
    let verticalDistance: (LFReadingUnit) -> Double = { unit in
      unit.sourceRegions
        .map { region -> Double in
          let rect = region.rectPDFPoints
          guard rect.count == 4 else { return .greatestFiniteMagnitude }
          return abs(Double(point.y) - (rect[1] + rect[3] / 2))
        }
        .min() ?? .greatestFiniteMagnitude
    }
    let hit = units.first(where: contains)
    let target = hit ?? units.min(by: { verticalDistance($0) < verticalDistance($1) })
    guard let target else { return }
    Self.metrics.notice(
      "narration.beginAtPoint.target index=\(units.firstIndex(where: { $0.unitID == target.unitID }) ?? -1, privacy: .public) of=\(units.count, privacy: .public) exactHit=\(hit != nil, privacy: .public) targetY=\(Int(target.sourceRegions.first?.rectPDFPoints[1] ?? -1), privacy: .public)"
    )
    beginReading(at: target.unitID, onRequiresVoice: onRequiresVoice)
  }

  /// The document's table of contents, used by the navigator so a reader can jump straight to a
  /// chapter instead of paging through the front matter.
  var documentOutline: [DocumentOutlineEntry] {
    if let document {
      let embedded = DocumentServices.outlineOutline(from: document)
      if !embedded.isEmpty { return embedded }
    }
    // Headings the core recovered from pages already normalized. Their text went through Vision, so
    // it keeps the diacritics a degraded PDF text layer drops.
    let recovered = normalizedPages.keys.sorted().flatMap { key in
      (normalizedPages[key]?.units ?? [])
        .filter { $0.contentClass == "heading" }
        .map { DocumentOutlineEntry(title: $0.text, pageIndex: Int(key), level: 0) }
    }
    guard !prescannedOutline.isEmpty else { return recovered }

    // The prescan gives the whole table of contents from the moment the document opens; OCR only
    // improves the wording of the pages it has reached so far.
    var betterTitles: [Int: String] = [:]
    for entry in recovered where betterTitles[entry.pageIndex] == nil {
      betterTitles[entry.pageIndex] = entry.title
    }
    return prescannedOutline.map { entry in
      guard let candidate = betterTitles[entry.pageIndex] else { return entry }
      // OCR groups a title by geometry, so it often recovers only one line of it ("El negro" out of
      // "VI El negro y la psicopatología"). Its text is only an improvement when it is at least as
      // complete as the prescan's — otherwise fixing the diacritics would truncate the title.
      guard candidate.filter(\.isLetter).count >= entry.title.filter(\.isLetter).count else {
        return entry
      }
      // Same words in a different order is not an improvement, it is the page's block order. A
      // chapter numeral is set as a large drop capital away from the title, and OCR reads it
      // wherever the geometry puts it: once titles arrive whole (Story 6.22) this rule started
      // firing and turned "IV Del supuesto complejo de dependencia del colonizado" into "Del
      // supuesto complejo IV de dependencia del colonizado" in the navigator. Only the wording is
      // adopted, never the ordering.
      guard !ReaderViewModel.isReordering(candidate, of: entry.title) else { return entry }
      return DocumentOutlineEntry(title: candidate, pageIndex: entry.pageIndex, level: entry.level)
    }
  }

  /// Whether `candidate` is `original`'s own words in another order — the same title shuffled, not a
  /// better reading of it. Compared with accents and case removed, so that recovering the diacritics
  /// a degraded text layer dropped still counts as an improvement and is still adopted.
  static func isReordering(_ candidate: String, of original: String) -> Bool {
    let words = { (text: String) -> [String] in
      text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
    }
    let candidateWords = words(candidate)
    let originalWords = words(original)
    return candidateWords != originalWords && candidateWords.sorted() == originalWords.sorted()
  }

  /// Reads the whole text layer off the main thread so opening stays responsive. Only applied while
  /// the same document is still open — a fast reopen must not adopt the previous document's index.
  private func startOutlinePrescan(for document: PDFDocument) {
    outlinePrescanTask = Task { [weak self] in
      let headings = await DocumentServices.prescanHeadingsAsync(from: document)
      guard let self, self.document === document else { return }
      self.prescannedOutline = headings
    }
  }

  func goToOutlineEntry(_ entry: DocumentOutlineEntry) {
    guard entry.pageIndex >= 0, entry.pageIndex < pageCount else { return }
    let wasNarrating = narrationState == .playing || narrationState == .preparing
    stopNarration()
    pageIndex = entry.pageIndex
    currentUnitID = nil
    selectFirstUnitForCurrentPage()
    requestMutation(action: "reprioritize", pageIndex: UInt32(entry.pageIndex))
    if wasNarrating { startNarration {} }
  }

  func requestTranslation() {
    guard !translationTargetLanguage.isEmpty,
      availableTranslationTargetLanguages.contains(translationTargetLanguage)
    else { return }
    translationRequested = true
    // Asking for a translation has to start one. Until now the request only raised a flag, and
    // work began solely as a side effect of narrating with the translated source selected, so
    // pressing the button appeared to do nothing at all.
    if currentUnitID == nil { selectFirstUnitForCurrentPage() }
    // This is the only entry point the reader can press — the start button and the one offered
    // beside the failure notice — so it is also the retry: it takes the failed passages back
    // instead of walking past them (Story 5.4 AC5).
    beginTranslationProgress(retryingFailures: true)
  }

  /// Passages of the current page still waiting for the runtime, and those already translated.
  /// The reader needs to see that something is happening: a batch takes a while on device.
  var translationPendingCount: Int {
    immersionUnits.filter { translationStatuses[$0.unitID] == .pending }.count
  }

  var translationTranslatedCount: Int {
    immersionUnits.filter {
      if case .translated = translationStatuses[$0.unitID] { return true }
      return false
    }.count
  }

  var translationTranslatableCount: Int {
    immersionUnits.filter {
      TranslationServices.isEligibleForTranslation(
        contentClass: $0.contentClass, confidence: $0.confidence)
    }.count
  }

  /// The text to show for a passage: the translation once it exists, the original until then — or
  /// always the original while the reader is comparing against it.
  func displayText(for unit: LFReadingUnit) -> String {
    guard !showingOriginalText, case .translated(let translated) = translationStatuses[unit.unitID]
    else { return unit.text }
    return translated
  }

  func isShowingTranslation(_ unit: LFReadingUnit) -> Bool {
    guard !showingOriginalText, case .translated = translationStatuses[unit.unitID] else {
      return false
    }
    return true
  }

  /// True when a translation exists somewhere in the document, which is what makes the
  /// original/translation switch worth showing at all.
  var hasAnyTranslation: Bool {
    translationStatuses.values.contains {
      if case .translated = $0 { return true } else { return false }
    }
  }

  func toggleShowingOriginalText() { showingOriginalText.toggle() }

  /// Translated passages of the current page, positioned over the blocks they came from, so the
  /// PDF surface shows the translation on the page itself rather than only beside it.
  var translatedOverlayBlocks: [TranslatedOverlayBlock] {
    guard !showingOriginalText else { return [] }
    let pages = trackingUnit == .paragraph ? normalizedPages : normalizedSentencePages
    guard let units = pages[UInt32(pageIndex)]?.units else { return [] }
    return units.compactMap { unit in
      guard case .translated(let text) = translationStatuses[unit.unitID],
        let region = unit.sourceRegions.first, region.rectPDFPoints.count == 4
      else { return nil }
      // Cover the whole passage, not just its first line.
      let rects = unit.sourceRegions.filter { $0.rectPDFPoints.count == 4 }
      let minX = rects.map { $0.rectPDFPoints[0] }.min() ?? region.rectPDFPoints[0]
      let minY = rects.map { $0.rectPDFPoints[1] }.min() ?? region.rectPDFPoints[1]
      let maxX = rects.map { $0.rectPDFPoints[0] + $0.rectPDFPoints[2] }.max() ?? minX
      let maxY = rects.map { $0.rectPDFPoints[1] + $0.rectPDFPoints[3] }.max() ?? minY
      return TranslatedOverlayBlock(
        pageIndex: pageIndex,
        rectPDFPoints: [minX, minY, maxX - minX, maxY - minY],
        text: text)
    }
  }

  func cancelTranslationRequest() {
    translationRequested = false
  }

  /// Mirrors `startNarration`'s windowing (current unit + nearby prose/note units), but for
  /// text translation rather than audio synthesis (AC1). Degraded/non-prose units are classified
  /// `.nonTranslatable` without ever reaching the runtime (AC6), using the same threshold already
  /// established by `exportDegradedUnits`/`exportNonNarrableUnits`.
  /// `retryingFailures` is set only by `requestTranslation()`, the reader's own button: an explicit
  /// pass takes the `.failed` passages back, the automatic chaining below never does.
  func beginTranslationProgress(retryingFailures: Bool = false) {
    guard translationRequested, !translationTargetLanguage.isEmpty,
      let manifest = translationManifest, let installed = installedTranslationModel,
      let runtimeURL = translationRuntimeURL,
      translationProgressState != .translating
    else { return }
    // Walk the whole document, not just the page on screen: translation is meant to keep pace with
    // reading, and stopping at the page boundary left the rest of the book in the source language.
    let units = immersionStream.map(\.unit)
    guard let currentUnitID else { return }
    let window = Set(
      TranslationServices.unitsToTranslate(
        orderedUnitIDs: units.map(\.unitID), startingAt: currentUnitID,
        statuses: translationStatuses, windowSize: Self.translationWindowSize,
        retryingFailures: retryingFailures))
    guard !window.isEmpty else { return }

    var pendingUnits: [TranslationUnitRequest] = []
    for unit in units where window.contains(unit.unitID) {
      if TranslationServices.isEligibleForTranslation(
        contentClass: unit.contentClass, confidence: unit.confidence)
      {
        translationStatuses[unit.unitID] = .pending
        pendingUnits.append(TranslationUnitRequest(unitId: unit.unitID, text: unit.narrationText))
      } else {
        translationStatuses[unit.unitID] = .nonTranslatable
      }
    }
    guard !pendingUnits.isEmpty else { return }

    translationProgressTask?.cancel()
    translationProgressState = .translating
    Self.metrics.notice(
      "translation.begin pending=\(pendingUnits.count, privacy: .public) window=\(window.count, privacy: .public) retry=\(retryingFailures, privacy: .public) target=\(self.translationTargetLanguage, privacy: .public) source=\(self.selectedVoiceLanguage, privacy: .public)"
    )
    let workRoot = temporaryWorkRoot.appendingPathComponent(
      "temporary-translation/\(UUID().uuidString)", isDirectory: true)
    let modelURL = installed.directory.appendingPathComponent("data", isDirectory: true)
    translationProgressTask = Task {
      let request = TranslationRequest(
        modelId: manifest.id, modelRevision: manifest.modelRevision,
        runtimeId: manifest.runtimeId, runtimeVersion: manifest.runtimeVersion,
        sourceLanguage: selectedVoiceLanguage, targetLanguage: translationTargetLanguage,
        units: pendingUnits)
      defer { try? FileManager.default.removeItem(at: workRoot) }
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try TranslationServices.translate(
            request, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot)
        }.value
        guard !Task.isCancelled else { return }
        applyTranslationResult(result, requestedUnits: pendingUnits)
      } catch {
        Self.metrics.error(
          "translation.error \(String(describing: error), privacy: .public)")
        for unit in pendingUnits { translationStatuses[unit.unitId] = .failed }
        translationProgressState = .failed
      }
    }
  }

  /// Correspondence check (AC7): any loss or duplication fails the whole batch rather than
  /// publishing a partial result without that guarantee.
  private func applyTranslationResult(
    _ result: TranslationResult, requestedUnits: [TranslationUnitRequest]
  ) {
    Self.metrics.notice(
      "translation.result translated=\(result.translatedUnits.count, privacy: .public) failed=\(result.failedUnitIds.count, privacy: .public) requested=\(requestedUnits.count, privacy: .public)"
    )
    guard result.hasExactCorrespondence(toRequestedUnitIds: requestedUnits.map(\.unitId)) else {
      Self.metrics.error("translation.correspondence_mismatch")
      for unit in requestedUnits { translationStatuses[unit.unitId] = .failed }
      translationProgressState = .failed
      return
    }
    for translated in result.translatedUnits {
      for sourceID in translated.sourceUnitIds {
        translationStatuses[sourceID] = .translated(translated.translatedText)
      }
    }
    for failedID in result.failedUnitIds { translationStatuses[failedID] = .failed }
    translationProgressState = .idle
    // Keep going through the page a window at a time; `beginTranslationProgress` stops by itself
    // once every passage in reach already has a status. Deliberately without `retryingFailures`:
    // an automatic pass that took failures back would retry a bad passage for ever.
    beginTranslationProgress()
  }

  /// Cancelling preserves already-resolved units (`.translated`/`.nonTranslatable`); only units
  /// still `.pending` are cleared so a retry can pick them up cleanly (AC5).
  func cancelTranslationProgress() {
    translationProgressTask?.cancel()
    translationProgressTask = nil
    for (unitID, status) in translationStatuses where status == .pending {
      translationStatuses.removeValue(forKey: unitID)
    }
    translationProgressState = .cancelled
  }

  func prepareTranslation() {
    guard let translationManifest,
      let manifestURL = Bundle.main.url(
        forResource: "translategemma-4b-it-4bit", withExtension: "json"),
      let manifestData = try? Data(contentsOf: manifestURL),
      translationPreparationState != .downloading
    else { return }
    translationPreparationTask?.cancel()
    translationPreparationState = .downloading
    translationPreparationFailure = nil
    translationCompletedBytes = 0
    translationPreparationTask = Task {
      do {
        _ = try await ModelPackageInstaller.install(
          manifestData: manifestData, containerRoot: modelContainerRoot,
          progress: { [weak self] update in
            Task { @MainActor in self?.translationCompletedBytes = update.completedBytes }
          })
        translationCompletedBytes = translationManifest.totalSizeBytes
        translationPreparationState = .installed
      } catch ModelInstallationError.cancelled {
        translationPreparationState = .cancelled
      } catch let error as ModelInstallationError {
        translationPreparationFailure = Self.voiceFailure(for: error)
        translationPreparationState = .failed
      } catch {
        translationPreparationFailure = .loadFailed
        translationPreparationState = .failed
      }
    }
  }

  func cancelTranslationPreparation() {
    translationPreparationTask?.cancel()
    translationPreparationTask = nil
    translationPreparationState = .cancelled
  }

  private static func voiceFailure(for error: ModelInstallationError) -> VoicePreparationFailure {
    switch error {
    case .invalidManifest, .incompatibleRuntime: .incompatible
    case .hashMismatch, .sizeMismatch, .invalidArtifactPath, .unexpectedArtifact:
      .corruptArtifact
    case .downloadFailed: .interruptedDownload
    case .insufficientSpace: .insufficientSpace
    case .unauthorizedDestination: .loadFailed
    case .cancelled: .interruptedDownload
    }
  }

  func startNarration(onRequiresVoice: () -> Void) {
    if narrationState == .paused {
      resumeNarration()
      return
    }
    guard narrationState != .preparing, narrationState != .playing else { return }
    Self.metrics.notice(
      """
      narration.start installedVoice=\(self.installedVoiceModel != nil) \
      runtime=\(self.voiceRuntimeURL?.path ?? "nil") \
      runtimeExecutable=\(self.voiceRuntimeURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false) \
      lang=\(self.selectedVoiceLanguage) voice=\(self.selectedVoiceID) \
      compatible=\(self.hasCompatibleVoiceSelection) unit=\(self.currentUnitID ?? "nil") \
      units=\(self.immersionUnits.count)
      """)
    // A missing engine is not a missing selection: sending the reader to the voice sheet for it
    // produced an endless loop where picking a voice changed nothing. Each cause gets its own
    // honest state, and only a genuinely missing selection opens the sheet.
    guard installedVoiceModel != nil else {
      // The engine ships with the app, so a failure here means the voice *model* is not reachable
      // — usually the models folder has not been chosen yet, or its bookmark no longer resolves.
      narrationState = .missingVoiceModel
      return
    }
    guard let installedVoiceModel, let voiceRuntimeURL,
      FileManager.default.isExecutableFile(atPath: voiceRuntimeURL.path)
    else {
      narrationState = .missingVoiceRuntime
      return
    }
    if narrationSource == .original {
      guard hasCompatibleVoiceSelection else {
        onRequiresVoice()
        return
      }
    } else {
      guard hasVoiceForTranslationTarget else {
        narrationState = .missingTranslationVoice
        return
      }
    }
    let units = immersionUnits
    if let currentUnitID, let start = units.firstIndex(where: { $0.unitID == currentUnitID }) {
      let available = Array(units[start...])
      narrationSkippedCount =
        available.filter {
          !ReaderViewModel.isNarrable($0)
        }.count
      narrationUnits = Array(
        available.filter(ReaderViewModel.isNarrable).prefix(3))
      narrationIndex = 0
    } else {
      narrationUnits = []
      narrationIndex = 0
    }
    // Starting (or resuming) on a page with nothing readable — a blank verso the voice already
    // stepped onto — must roll forward to the next page that has text, not stop the reading.
    guard !narrationUnits.isEmpty || loadNextNarrationBatch() else {
      narrationState = .awaitingContent
      return
    }
    narrationState = .preparing
    synthesizeNext(
      modelURL: installedVoiceModel.directory.appendingPathComponent("data", isDirectory: true),
      runtimeURL: voiceRuntimeURL)
  }

  func toggleNarration(onRequiresVoice: () -> Void) {
    switch narrationState {
    case .playing: pauseNarration()
    case .paused: resumeNarration()
    default: startNarration(onRequiresVoice: onRequiresVoice)
    }
  }

  func pauseNarration() {
    guard narrationState == .playing else { return }
    audioPlayer.pause()
    narrationState = .paused
  }

  func resumeNarration() {
    guard narrationState == .paused else { return }
    audioPlayer.resume()
    narrationState = .playing
  }

  func seekNarration(by seconds: Double) {
    guard narrationState == .playing || narrationState == .paused else { return }
    audioPlayer.seek(by: seconds)
  }

  func moveNarrationUnit(by offset: Int) {
    let units = immersionUnits
    guard let currentUnitID,
      let current = units.firstIndex(where: { $0.unitID == currentUnitID }),
      units.indices.contains(current + offset)
    else { return }
    let wasActive = narrationState != .idle
    stopNarration()
    self.currentUnitID = units[current + offset].unitID
    if wasActive { startNarration {} }
  }

  func stopNarration() {
    // Bump first: `audioPlayer.stop()` fires the completion handler of whatever buffer is playing,
    // and that handler used to advance the old queue and synthesize its next unit. Reading then
    // carried on from where it was instead of from the passage the reader had just chosen.
    narrationGeneration &+= 1
    narrationTask?.cancel()
    narrationTask = nil
    audioPlayer.stop()
    narrationUnits = []
    narrationIndex = 0
    narrationSkippedCount = 0
    narrationState = .idle
  }

  func retryFailedNarration() {
    guard narrationState == .failed, let installedVoiceModel, let voiceRuntimeURL else { return }
    narrationState = .preparing
    synthesizeNext(
      modelURL: installedVoiceModel.directory.appendingPathComponent("data", isDirectory: true),
      runtimeURL: voiceRuntimeURL)
  }

  func skipFailedNarrationUnit() {
    guard narrationState == .failed || narrationState == .translationFailed else { return }
    narrationIndex += 1
    guard let installedVoiceModel, let voiceRuntimeURL else { return }
    narrationState = .preparing
    synthesizeNext(
      modelURL: installedVoiceModel.directory.appendingPathComponent("data", isDirectory: true),
      runtimeURL: voiceRuntimeURL)
  }

  /// Retries fetching the translation for the current unit (AC6) without advancing the index.
  func retryTranslationForCurrentNarrationUnit() {
    guard narrationState == .translationFailed, narrationIndex < narrationUnits.count,
      let installedVoiceModel, let voiceRuntimeURL
    else { return }
    let unit = narrationUnits[narrationIndex]
    let modelURL = installedVoiceModel.directory.appendingPathComponent("data", isDirectory: true)
    narrationState = .awaitingTranslation
    translateUnitAndApply(unit) { [weak self] in
      guard let self, self.narrationState == .awaitingTranslation else { return }
      self.synthesizeNext(modelURL: modelURL, runtimeURL: voiceRuntimeURL)
    }
  }

  /// Switches the current narration to Original (AC6's "volver a Original") and resynthesizes
  /// the current unit from the source text.
  func revertNarrationToOriginal() {
    guard narrationState == .translationFailed || narrationState == .missingTranslationVoice
    else { return }
    narrationSource = .original
    guard hasCompatibleVoiceSelection, let installedVoiceModel, let voiceRuntimeURL else { return }
    narrationState = .preparing
    synthesizeNext(
      modelURL: installedVoiceModel.directory.appendingPathComponent("data", isDirectory: true),
      runtimeURL: voiceRuntimeURL)
  }

  /// Shared single-unit translation call reused by Story 5.4's retry and by narration's
  /// wait-for-translation path (AC6) — both need "translate exactly this one unit, apply the
  /// correspondence-checked result", differing only in what happens afterward.
  private func translateUnitAndApply(_ unit: LFReadingUnit, completion: (() -> Void)? = nil) {
    guard let manifest = translationManifest, let installed = installedTranslationModel,
      let runtimeURL = translationRuntimeURL
    else {
      translationStatuses[unit.unitID] = .failed
      completion?()
      return
    }
    translationStatuses[unit.unitID] = .pending
    let requestUnit = TranslationUnitRequest(unitId: unit.unitID, text: unit.narrationText)
    let workRoot = temporaryWorkRoot.appendingPathComponent(
      "temporary-translation/\(UUID().uuidString)", isDirectory: true)
    let modelURL = installed.directory.appendingPathComponent("data", isDirectory: true)
    Task {
      let request = TranslationRequest(
        modelId: manifest.id, modelRevision: manifest.modelRevision,
        runtimeId: manifest.runtimeId, runtimeVersion: manifest.runtimeVersion,
        sourceLanguage: selectedVoiceLanguage, targetLanguage: translationTargetLanguage,
        units: [requestUnit])
      defer { try? FileManager.default.removeItem(at: workRoot) }
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try TranslationServices.translate(
            request, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot)
        }.value
        applyTranslationResult(result, requestedUnits: [requestUnit])
      } catch {
        translationStatuses[unit.unitID] = .failed
      }
      completion?()
    }
  }

  /// What the voice reads aloud. Footnotes stay in the text and on screen — they are real content,
  /// often the source a reader wants to check — but hearing a bibliographic note dropped into the
  /// middle of a paragraph breaks the thread of listening, so narration steps over them and counts
  /// them in `narrationSkippedCount` rather than dropping them silently.
  ///
  /// A chapter title is the opposite case: it is the one line that tells a listener where they are,
  /// and skipping it is how the reader ended up hearing "y la blanca" out of nowhere at the opening
  /// of chapter III — the rest of that title was classed `heading` and never spoken. The core has
  /// always said so in as many words (`ContentClass::Heading`: "Headings are still narratable
  /// content, not something to skip"); this filter was the one place that disagreed.
  static func isNarrable(_ unit: LFReadingUnit) -> Bool {
    unit.contentClass == "prose" || unit.contentClass == "heading"
  }

  /// Continuous reading: when the current batch runs out, keep going with the rest of the page and
  /// then roll onto the next page, moving the reader's page with the voice. Stopping at the end of
  /// every page is what made narration feel broken rather than fluid.
  private func loadNextNarrationBatch() -> Bool {
    let narrable = ReaderViewModel.isNarrable
    let units = immersionUnits
    if let currentUnitID,
      let index = units.firstIndex(where: { $0.unitID == currentUnitID })
    {
      let remaining = Array(units[(index + 1)...]).filter(narrable)
      if !remaining.isEmpty {
        narrationUnits = Array(remaining.prefix(3))
        narrationIndex = 0
        return true
      }
    }
    // Blank pages are ordinary in books (title versos, section breaks). Narration skips over every
    // already-processed page without readable text instead of stopping on the first one, and only
    // pauses when it catches up with pages that have not been extracted yet.
    let pages = trackingUnit == .paragraph ? normalizedPages : normalizedSentencePages
    while canGoNext {
      guard let page = pages[UInt32(pageIndex + 1)] else {
        // The incremental session only plans a window of pages, so reading eventually reaches one
        // that is neither extracted nor queued. Asking for it keeps the book advancing instead of
        // declaring the narration finished with hundreds of pages still unread.
        requestMutation(action: "reprioritize", pageIndex: UInt32(pageIndex + 1))
        return false
      }
      pageIndex += 1
      currentUnitID = nil
      let next = page.units.filter(narrable)
      if !next.isEmpty {
        narrationUnits = Array(next.prefix(3))
        narrationIndex = 0
        return true
      }
    }
    return false
  }

  private func synthesizeNext(modelURL: URL, runtimeURL: URL) {
    if narrationIndex >= narrationUnits.count, !loadNextNarrationBatch() {
      // Reading is only "finished" at the end of the document. Anywhere else the voice is simply
      // waiting for pages to be extracted, and saying "finished" stranded the reader mid-book.
      narrationState = canGoNext ? .awaitingContent : .finished
      return
    }
    guard narrationIndex < narrationUnits.count, let manifest = voiceManifest else {
      narrationState = .finished
      return
    }
    let unit = narrationUnits[narrationIndex]

    let text: String
    let voiceID: String
    let language: String
    if narrationSource == .translation {
      switch translationStatuses[unit.unitID] {
      case .translated(let translatedText):
        guard let translationVoiceID else {
          narrationState = .missingTranslationVoice
          return
        }
        text = translatedText
        voiceID = translationVoiceID
        language = translationTargetLanguage
      case .nonTranslatable:
        narrationIndex += 1
        synthesizeNext(modelURL: modelURL, runtimeURL: runtimeURL)
        return
      case .failed:
        narrationState = .translationFailed
        return
      case .pending, nil:
        narrationState = .awaitingTranslation
        translateUnitAndApply(unit) { [weak self] in
          guard let self, self.narrationState == .awaitingTranslation else { return }
          self.synthesizeNext(modelURL: modelURL, runtimeURL: runtimeURL)
        }
        return
      }
    } else {
      text = unit.narrationText
      voiceID = selectedVoiceID
      language = selectedVoiceLanguage
    }

    let request = TTSSynthesisRequest(
      modelId: manifest.id, modelRevision: manifest.modelRevision,
      runtimeId: manifest.runtimeId, runtimeVersion: manifest.runtimeVersion,
      voiceId: voiceID, language: language, rawIPA: false,
      units: [TTSUnitRequest(unitId: unit.unitID, text: text)])
    let workRoot = temporaryWorkRoot.appendingPathComponent(
      "temporary-audio/\(UUID().uuidString)", isDirectory: true)
    let frontendURL = phoneticFrontendURL
    let dataRootURL = phoneticDataRootURL
    let generation = narrationGeneration
    narrationTask = Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          let preparedRequest = EngineClient.phonemizedRequest(
            request, engineURL: frontendURL, dataRoot: dataRootURL)
          return try ModelServices.synthesize(
            preparedRequest, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot)
        }.value
        guard !Task.isCancelled, generation == narrationGeneration else { return }
        let audioURL = URL(fileURLWithPath: result.audioPath)
        currentUnitID = unit.unitID
        narrationState = .playing
        try audioPlayer.enqueue(audioURL) { [weak self] in
          guard let self, generation == self.narrationGeneration else { return }
          self.narrationIndex += 1
          self.narrationState = .preparing
          self.synthesizeNext(modelURL: modelURL, runtimeURL: runtimeURL)
        }
      } catch {
        try? FileManager.default.removeItem(at: workRoot)
        guard generation == narrationGeneration else { return }
        narrationState = .failed
      }
    }
  }

  var modelStorageDescription: String {
    modelStorageRoot?.lastPathComponent ?? String(localized: "voice.storage.default")
  }

  func chooseModelStorage() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "voice.storage.choose")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if modelStorageHasSecurityScope { modelStorageRoot?.stopAccessingSecurityScopedResource() }
    modelStorageRoot = url
    modelStorageHasSecurityScope = url.startAccessingSecurityScopedResource()
    if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
      UserDefaults.standard.set(bookmark, forKey: ModelStorage.bookmarkKey)
    }
    voicePreparationState = installedVoiceModel == nil ? .ready : .installed
    preselectVoiceIfPossible()
    if translationManifest != nil {
      translationPreparationState = installedTranslationModel == nil ? .ready : .installed
    }
  }

  var installedVoiceModel: InstalledModel? {
    guard let manifest = voiceManifest,
      let manifestURL = Bundle.main.url(forResource: "kokoro-82m-4bit", withExtension: "json"),
      let manifestData = try? Data(contentsOf: manifestURL)
    else { return nil }
    if let installed = ModelPackageInstaller.installedModel(
      id: manifest.id, containerRoot: modelContainerRoot)
    {
      return installed
    }
    guard let modelStorageRoot else { return nil }
    return ModelPackageInstaller.verifiedPackage(
      manifestData: manifestData,
      packageRoot: modelStorageRoot.appendingPathComponent(
        "verified-packages/\(manifest.id)", isDirectory: true),
      manifestURL: manifestURL)
  }

  var installedTranslationModel: InstalledModel? {
    guard let manifest = translationManifest,
      let manifestURL = Bundle.main.url(
        forResource: "translategemma-4b-it-4bit", withExtension: "json"),
      let manifestData = try? Data(contentsOf: manifestURL)
    else { return nil }
    if let installed = ModelPackageInstaller.installedModel(
      id: manifest.id, containerRoot: modelContainerRoot)
    {
      return installed
    }
    guard let modelStorageRoot else { return nil }
    return ModelPackageInstaller.verifiedPackage(
      manifestData: manifestData,
      packageRoot: modelStorageRoot.appendingPathComponent(
        "verified-packages/\(manifest.id)", isDirectory: true),
      manifestURL: manifestURL)
  }

  /// Helper engines ship inside the app bundle. The sandbox grants read access to an external
  /// models folder but never the right to execute binaries there, so a runtime living outside the
  /// bundle reports itself as non-executable and narration can never start. The external path is
  /// kept only as a development fallback for unsandboxed runs.
  private func runtimeURL(named name: String, developmentPath: String) -> URL? {
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/\(name)", isDirectory: false)
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    return modelStorageRoot?.appendingPathComponent(developmentPath)
  }

  /// eSpeak NG and its dictionaries ship with the app: a reader's machine has no Homebrew install,
  /// and the sandbox would not let the app execute one anyway.
  var phoneticFrontendURL: URL? {
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/espeak-ng", isDirectory: false)
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    let developmentPath = URL(fileURLWithPath: "/opt/homebrew/bin/espeak-ng")
    return FileManager.default.isExecutableFile(atPath: developmentPath.path)
      ? developmentPath : nil
  }

  var phoneticDataRootURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
  }

  var voiceRuntimeURL: URL? {
    runtimeURL(
      named: "mlx-audio-swift-tts",
      developmentPath:
        "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts")
  }

  var translationRuntimeURL: URL? {
    runtimeURL(
      named: "lectura-translate-runtime",
      developmentPath:
        "runtime/xcode-derived-mlx-swift-lm-gemma3/Build/Products/Release/lectura-translate-runtime"
    )
  }

  /// Scratch space for synthesis and translation always belongs to the app's own container: the
  /// model folder may live on a volume the sandbox only grants read access to, so writing work
  /// files there fails and surfaces to the reader as "audio unavailable".
  private var temporaryWorkRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LecturaFluida/Work", isDirectory: true)
  }

  private var modelContainerRoot: URL {
    ModelStorage.containerRoot(storageRoot: modelStorageRoot)
  }

  private func restoreModelStorage() {
    guard let resolved = ModelStorage.resolve() else { return }
    modelStorageRoot = resolved.url
    guard resolved.isSecurityScoped else { return }
    modelStorageHasSecurityScope = resolved.url.startAccessingSecurityScopedResource()
    // A stale bookmark still resolves and still grants access; discarding it made the app forget
    // the reader's models folder — which happens routinely, for instance every time the app is
    // rebuilt or re-signed. Refresh it instead of losing the choice.
    if resolved.isStale, let refreshed = try? resolved.url.bookmarkData(options: .withSecurityScope)
    {
      UserDefaults.standard.set(refreshed, forKey: ModelStorage.bookmarkKey)
    }
  }

  func open() {
    guard let selected = FileServices.selectPDF() else { return }
    // The document the reader is leaving is the one being asked about, so the question comes after
    // the new one has been chosen: until the panel returns, nothing is closing.
    Task {
      await offerToKeepRecognisedText()
      open(selected)
    }
  }

  func chooseExportDestination() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      "\(exportTitle.isEmpty ? grant?.displayName ?? "Audiobook" : exportTitle).m4b"
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "export.destination.choose")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let destination =
      url.pathExtension.lowercased() == "m4b"
      ? url : url.appendingPathExtension("m4b")
    // Story 6.17: the export used to take the panel's answer and nothing else, and then refused
    // every destination the reader offered it with "cannot write to that destination". A sandboxed
    // app reaches a chosen file only while it holds security-scoped access to it, and a save panel
    // grants exactly **that file** — nothing around it. Measured through a real panel:
    //
    //     folderScope=false  fileScope=true  folderWritable=false
    //     canCreateDestination=true  canCreateSibling=false
    //     folderBookmark=false  fileBookmark=true
    //
    // So the access is taken on the destination itself, and the export's preflight had to stop
    // asking the enclosing folder whether it was writable — a question that can only be answered
    // "no" for every destination a reader would actually pick (`AudiobookExporter.export`).
    releaseExportDestinationScope()
    exportDestinationScopeURL = destination
    exportDestinationHasSecurityScope = destination.startAccessingSecurityScopedResource()
    Self.exportLog.notice(
      "export destination chosen: scope=\(self.exportDestinationHasSecurityScope, privacy: .public)"
    )
    exportDestination = destination
    exportReplaceExisting = FileManager.default.fileExists(atPath: destination.path)
  }

  /// AC1 (Story 5.9): exporting the translation reuses this exact preparation/progress/recovery flow;
  /// Original's behaviour below is otherwise untouched.
  var exportingTranslation: Bool { narrationSource == .translation }

  /// AC1-3: everything the translated export needs beyond what Original already requires. `nil`
  /// while any piece is missing, which `beginExport` treats the same as an incomplete Original setup
  /// — the export simply does not start.
  private var translationExportContext:
    (
      manifest: InstallableModelManifest, model: InstalledModel, runtimeURL: URL, voiceID: String,
      targetLanguage: String
    )?
  {
    guard let translationManifest, let installedTranslationModel, let translationRuntimeURL,
      let translationVoiceID, !translationTargetLanguage.isEmpty
    else { return nil }
    return (
      translationManifest, installedTranslationModel, translationRuntimeURL, translationVoiceID,
      translationTargetLanguage
    )
  }

  /// AC2: whether the export preflight can proceed for a translated export — everything
  /// `translationExportContext` requires, exposed for the view without leaking the tuple itself.
  var hasTranslationExportPrerequisites: Bool { translationExportContext != nil }

  /// One translated unit for the exporter (Story 5.9 AC3): the already-cached translation when
  /// reading produced one, otherwise a single fresh call to the runtime — never the whole document
  /// translated ahead of the export starting. Failure throws `.translationFailed` rather than
  /// falling back to the source text (AC5).
  private nonisolated func makeExportTranslateClosure(
    context: (
      manifest: InstallableModelManifest, model: InstalledModel, runtimeURL: URL, voiceID: String,
      targetLanguage: String
    ),
    sourceLanguage: String, workRoot: URL
  ) -> AudiobookExporter.Translate {
    { [weak self] (unit: AudiobookExportUnit) async throws -> String in
      guard let self else { throw AudiobookExportError.translationFailed }
      if let cached = await MainActor.run(body: { () -> String? in
        if case .translated(let text) = self.translationStatuses[unit.unitID] { return text }
        return nil
      }) {
        return cached
      }
      let unitWorkRoot = workRoot.appendingPathComponent(
        "temporary-translation/\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: unitWorkRoot) }
      let request = TranslationRequest(
        modelId: context.manifest.id, modelRevision: context.manifest.modelRevision,
        runtimeId: context.manifest.runtimeId, runtimeVersion: context.manifest.runtimeVersion,
        sourceLanguage: sourceLanguage, targetLanguage: context.targetLanguage,
        units: [TranslationUnitRequest(unitId: unit.unitID, text: unit.text)])
      let result = try TranslationServices.translate(
        request, runtimeURL: context.runtimeURL,
        modelURL: context.model.directory.appendingPathComponent("data", isDirectory: true),
        workRoot: unitWorkRoot)
      guard result.hasExactCorrespondence(toRequestedUnitIds: [unit.unitID]),
        let translated = result.translatedUnits.first(where: {
          $0.sourceUnitIds.contains(unit.unitID)
        })
      else { throw AudiobookExportError.translationFailed }
      await MainActor.run {
        self.translationStatuses[unit.unitID] = .translated(translated.translatedText)
      }
      return translated.translatedText
    }
  }

  func beginExport(resuming: Bool = false) {
    guard exportTask == nil, let destination = exportDestination,
      let voiceManifest, let installedVoiceModel, let voiceRuntimeURL,
      hasCompatibleVoiceSelection, let grant
    else { return }
    let translationContext = exportingTranslation ? translationExportContext : nil
    guard !exportingTranslation || translationContext != nil else { return }
    if narrationState == .playing { pauseNarration() }
    exportState = .preparing
    let jobID =
      resuming
      ? exportJobID ?? "export_\(UUID().uuidString.lowercased())"
      : "export_\(UUID().uuidString.lowercased())"
    exportJobID = jobID
    exportPauseRequested = false
    if !resuming {
      exportCompletedUnits = 0
      exportStartedAt = Date()
    }
    let sourceLanguage = selectedVoiceLanguage
    let workRoot = temporaryWorkRoot
    let exportPhoneticFrontendURL = phoneticFrontendURL
    let exportPhoneticDataRootURL = phoneticDataRootURL
    exportTask = Task {
      if exportPendingPages > 0 { await prepareDocumentForExport() }
      guard !Task.isCancelled else { return }
      let units = exportReadyUnits.map {
        AudiobookExportUnit(unitID: $0.unitID, text: $0.narrationText, anchorID: $0.unitID)
      }
      let chapters = exportChapters
      exportTotalUnits = units.count
      let fingerprint = (try? await grant.documentFingerprint()) ?? "unavailable"
      let root = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LecturaFluida/Exports", isDirectory: true)
      exportState = .exporting
      // The export always narrates through Kokoro — `translationContext`'s model/runtime are the
      // *translation* engine, used only inside `translateUnit` below to resolve each unit's text.
      // Passing them here instead was a real bug: it made the exporter try to synthesize audio
      // through the translation runtime, and export failed on the very first unit ("No se pudo
      // narrar la unidad actual") exactly as caught testing this against the running app. Only the
      // voice id and language change for a translated export; the voice model itself does not.
      let exportModel = voiceManifest
      let exportRuntimeURL = voiceRuntimeURL
      let exportModelURL = installedVoiceModel.directory.appendingPathComponent(
        "data", isDirectory: true)
      let baseTitle = exportTitle.isEmpty ? grant.displayName : exportTitle
      let exportTitleResolved =
        translationContext.map { "\(baseTitle) — \($0.targetLanguage.uppercased())" } ?? baseTitle
      // AC3: resolves one unit's translation at a time, interleaved with synthesis — reusing
      // whatever the reader already produced while reading rather than discarding it.
      let translateUnit: AudiobookExporter.Translate? = translationContext.map {
        makeExportTranslateClosure(context: $0, sourceLanguage: sourceLanguage, workRoot: workRoot)
      }
      do {
        let url = try await AudiobookExporter.export(
          AudiobookExportRequest(
            jobID: jobID, sourceFingerprint: fingerprint,
            title: exportTitleResolved,
            language: translationContext?.targetLanguage ?? selectedVoiceLanguage,
            voiceID: translationContext?.voiceID ?? selectedVoiceID, units: units,
            model: exportModel,
            modelURL: exportModelURL,
            runtimeURL: exportRuntimeURL, destinationURL: destination, workRoot: root,
            replaceExisting: exportReplaceExisting, chapters: chapters),
          shouldPause: { await MainActor.run { self.exportPauseRequested } },
          synthesize: { request, runtimeURL, modelURL, workRoot in
            let preparedRequest = EngineClient.phonemizedRequest(
              request, engineURL: exportPhoneticFrontendURL,
              dataRoot: exportPhoneticDataRootURL)
            return try ModelServices.synthesize(
              preparedRequest, runtimeURL: runtimeURL, modelURL: modelURL, workRoot: workRoot)
          },
          translate: translateUnit,
          progress: { progress in
            self.exportCompletedUnits = progress.completedUnits
            self.exportTotalUnits = progress.totalUnits
          })
        exportState = .completed(url)
        releaseExportDestinationScope()
      } catch let error as AudiobookExportError {
        // Story 6.17: which of the eight ways an export can refuse to start actually fired is
        // invisible from the alert, which says the same thing for several of them.
        Self.exportLog.error("export failed: \(String(describing: error), privacy: .public)")
        exportState =
          error == .cancelled ? .cancelled : error == .paused ? .paused : .failed(error)
      } catch {
        Self.exportLog.error(
          "export failed (unclassified): \(error as NSError, privacy: .public)")
        exportState = .failed(.encodingFailed)
      }
      exportTask = nil
    }
  }

  func pauseExport() {
    guard exportState == .exporting || exportState == .preparing else { return }
    exportPauseRequested = true
  }

  func resumeExport() { beginExport(resuming: true) }

  func retryExport() { beginExport(resuming: true) }

  func restartExport() {
    if let exportJobID { AudiobookExporter.cancel(jobID: exportJobID, workRoot: exportWorkRoot) }
    self.exportJobID = nil
    beginExport()
  }

  func revealCompletedExport() {
    guard case .completed(let url) = exportState else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func openCompletedExport() {
    guard case .completed(let url) = exportState else { return }
    NSWorkspace.shared.open(url)
  }

  func cancelExport() {
    exportTask?.cancel()
    if exportTask == nil, let exportJobID {
      AudiobookExporter.cancel(jobID: exportJobID, workRoot: exportWorkRoot)
    }
    exportState = .cancelled
    releaseExportDestinationScope()
  }

  private var exportWorkRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LecturaFluida/Exports", isDirectory: true)
  }

  private func releaseExportDestinationScope() {
    guard exportDestinationHasSecurityScope else { return }
    exportDestinationScopeURL?.stopAccessingSecurityScopedResource()
    exportDestinationHasSecurityScope = false
    exportDestinationScopeURL = nil
  }

  private func open(_ selected: ReadAccessGrant) {
    let openedAt = ContinuousClock.now
    reportingTask?.cancel()
    outlinePrescanTask?.cancel()
    languageIdentification?.cancel()
    // Story 6.20: reading aloud belongs to the document being left, so it ends here — before the
    // new one is even read from disk, not somewhere inside the load. Everything else this function
    // clears is document state; narration is the one piece of it that keeps making noise on its
    // own, and it used to carry on over the new document, which showed nothing highlighted while
    // the transport still said "Reading aloud".
    stopNarration()
    state = .opening
    Task {
      do {
        let document = try await DocumentServices.openReadOnlyAsync(with: selected)
        releaseExportDestinationScope()
        grant = selected
        self.openedAt = openedAt
        self.document = document
        pageIndex = 0
        firstPageMilliseconds = nil
        processingSession = nil
        processingCancelled = false
        processingStorageFailed = false
        firstUnitAvailable = false
        normalizedPages = [:]
        normalizedSentencePages = [:]
        #if STRESS_TEST
          readingSurface = .immersion
        #else
          readingSurface = .pdf
        #endif
        trackingUnit = .paragraph
        currentUnitID = nil
        exportTitle = selected.displayName
        exportDestination = nil
        exportState = .idle
        storageBytes = 0
        documentFingerprint = nil
        forcedOCRPages = []
        pageRotationOverrides = [:]
        recognisedPagesToKeep = [:]
        pagesAwaitingWrite = [:]
        let coordinator = DocumentCloseCoordinator.shared
        coordinator.confirmKeepingRecognisedText = { [weak self] in
          self?.confirmKeepingRecognisedText() ?? false
        }
        coordinator.writeRecognisedText = { [weak self] in await self?.writeRecognisedText() }
        prescannedOutline = []
        startOutlinePrescan(for: document)
        identifiedDocumentLanguage = nil
        voiceLanguageChosenByReader = false
        recognisedLanguageSample = ""
        languagePagesLeftToSample = DocumentLanguage.sampledPages
        languageIdentification = Task { await DocumentLanguage.identifyAsync(in: document) }
        #if STRESS_TEST
          stressFailureInjected = false
        #endif
        state = .reading
      } catch let error as DocumentOpenError {
        grant = nil
        document = nil
        state = .failed(error)
      } catch {
        grant = nil
        document = nil
        state = .failed(.unreadable)
      }
    }
  }

  func previousPage() {
    guard canGoPrevious else { return }
    pageIndex -= 1
    selectFirstUnitForCurrentPage()
    requestPlan()
  }

  func nextPage() {
    guard canGoNext else { return }
    pageIndex += 1
    selectFirstUnitForCurrentPage()
    requestPlan()
  }

  func dismissError() { state = .empty }

  func cancelProcessing() {
    reportingTask?.cancel()
    processingCancelled = true
    requestMutation(action: "cancel", pageIndex: nil)
  }

  func resumeProcessing() {
    guard processingSession != nil else { return }
    reportingTask?.cancel()
    reportingTask = Task {
      guard await applyMutation(action: "resume", pageIndex: nil) else { return }
      processingCancelled = false
      await processPendingPages()
    }
  }

  var processingProgress: Double {
    guard let processingSession, !processingSession.pages.isEmpty else { return 0 }
    let finished = processingSession.pages.filter {
      $0.state == .completed || $0.state == .skipped
    }.count
    return Double(finished) / Double(processingSession.pages.count)
  }

  var failedPages: [LFIncrementalPage] {
    processingSession?.pages.filter { $0.state == .failed } ?? []
  }

  func firstPagePresented() {
    guard firstPageMilliseconds == nil, let openedAt, let grant else { return }
    let duration = openedAt.duration(to: .now)
    let milliseconds =
      UInt64(max(0, duration.components.seconds * 1_000))
      + UInt64(max(0, duration.components.attoseconds / 1_000_000_000_000_000))
    firstPageMilliseconds = milliseconds
    Self.metrics.notice("first_page_ms=\(milliseconds, privacy: .public)")
    self.openedAt = nil
    reportingTask?.cancel()
    reportingTask = Task {
      // The document names its own stored data, so the fingerprint has to be in hand before the
      // session is opened rather than at the first page that needs it (Story 6.25).
      guard let fingerprint = await resolvedDocumentFingerprint() else {
        Self.metrics.error("LF_FILE_FINGERPRINT_FAILED")
        return
      }
      // Four spread page pairs provide four observations of each recto/verso pattern. The core
      // requires three, so one exceptional chapter page may be absent without reading all margins.
      let furniturePageIndexes = DocumentLanguage.spreadIndices(
        over: (pageCount + 1) / 2, count: 4
      ).flatMap { [$0 * 2, $0 * 2 + 1] }.filter { $0 < pageCount }
      let furniturePages = await grant.extractDigitalPages(furniturePageIndexes)
      guard !Task.isCancelled,
        let event = try? await EngineClient.openDocument(
          accessGrantID: grant.id,
          documentFingerprint: fingerprint,
          pageCount: UInt32(pageCount),
          firstPageMilliseconds: milliseconds,
          furniturePages: furniturePages
        ), let opened = event.result?.documentOpened
      else { return }
      await plan(documentID: opened.documentID)
    }
  }

  /// The SHA-256 of the open document's bytes, computed once per document.
  ///
  /// It answers three questions that all have to give the same answer for one file: which session
  /// directory its derived data lives in, which export job can be resumed for it, and which
  /// generation the normalized units belong to.
  private func resolvedDocumentFingerprint() async -> String? {
    if let documentFingerprint { return documentFingerprint }
    guard let grant, let fingerprint = try? await grant.documentFingerprint() else { return nil }
    // Hashing the whole file takes long enough that the reader can open a different document
    // before this returns (Story 6.25, QA of 2026-08-22). `grant` is still the one this call
    // started with, but `self.grant` may already belong to that other document — publishing
    // unconditionally would file the new document's data under the old one's fingerprint.
    guard self.grant?.id == grant.id else { return nil }
    documentFingerprint = fingerprint
    restoreResumableExportIfAvailable()
    return fingerprint
  }

  func retryPage(_ pageIndex: UInt32) {
    requestMutation(action: "retry", pageIndex: pageIndex)
  }

  func skipPage(_ pageIndex: UInt32) {
    requestMutation(action: "skip", pageIndex: pageIndex)
  }

  func forceOCRPage(_ pageIndex: UInt32) {
    forcedOCRPages.insert(pageIndex)
    requestMutation(action: "retry", pageIndex: pageIndex)
  }

  /// Turns the page on screen a quarter, and reads it that way.
  ///
  /// Some pages are printed sideways and the file says nothing about it — a landscape table set
  /// across a portrait page, a sheet fed into the scanner the wrong way round. `/Rotate` reads 0,
  /// so PDFKit has nothing to correct and the reader is left tilting their head, while the voice
  /// works down what it takes for a column and is really a line. Measured on the owner's 818 PDFs:
  /// 84 pages of 25 documents are printed across the page while the file claims they are upright,
  /// and automatic detection is a separate question (see the story) — this is the answer that
  /// works whatever the answer to that one turns out to be, and it is the reader's, not a guess.
  ///
  /// Turning the page changes both things at once, which is the point: the view shows the page
  /// turned because PDFKit honours `rotation`, and the extraction re-reads it from a copy turned
  /// the same way, so `page_rotation_degrees` reaches the engine and the passages come back in the
  /// order the reader now sees. The document on disk is not touched.
  func rotateCurrentPage(clockwise: Bool) {
    rotatePage(UInt32(max(0, pageIndex)), clockwise: clockwise)
  }

  func rotatePage(_ index: UInt32, clockwise: Bool) {
    guard let page = document?.page(at: Int(index)) else { return }
    let turned = (((page.rotation + (clockwise ? 90 : -90)) % 360) + 360) % 360
    page.rotation = turned
    pageRotationOverrides[index] = turned
    // "reread", not "retry": a page that came back perfectly well is `Completed`, and retrying only
    // rescues a page that *failed* — asking for a retry here turned the page on screen and left the
    // voice reading it along the old axis. Re-reading it overwrites both the units held in memory
    // and the copy on disk, so reopening the document does not bring the old axis back from the
    // cache either.
    requestMutation(action: "reread", pageIndex: index)
  }

  /// Asks, once, at the moment the document is being released — changing documents or quitting —
  /// whether the text recognised while reading should stay inside the PDF. Never asked during
  /// reading: the decision is not urgent and the interruption would be.
  ///
  /// Returns `false` immediately when there is nothing to offer, which is the common case: a
  /// document with a good text layer never recognises anything, and a reader who closes before OCR
  /// has covered a page has nothing to keep. Either answer settles the question for this session —
  /// the pages are taken off the pending list before the alert is even shown.
  ///
  /// Asking is separate from writing because quitting can only pause for one of the two: the
  /// question is put while the app is still in `applicationShouldTerminate`, and only an accepted
  /// question makes the quit wait for the write.
  func confirmKeepingRecognisedText() -> Bool {
    guard !recognisedPagesToKeep.isEmpty else { return false }
    // An audiobook left paused resumes by matching the fingerprint of the file it came from, and
    // keeping the recognised text changes that fingerprint. The reader who paused an export keeps
    // it; the offer comes back the next time this document closes.
    guard exportState != .paused, exportState != .exporting, exportState != .preparing else {
      return false
    }
    pagesAwaitingWrite = recognisedPagesToKeep
    recognisedPagesToKeep = [:]

    let alert = NSAlert()
    alert.messageText = String(localized: "ocr.keep.title")
    alert.informativeText = String(localized: "ocr.keep.message")
    alert.addButton(withTitle: String(localized: "ocr.keep.confirm"))
    alert.addButton(withTitle: String(localized: "ocr.keep.decline"))
    guard alert.runModal() == .alertFirstButtonReturn else {
      pagesAwaitingWrite = [:]
      return false
    }
    return true
  }

  func writeRecognisedText() async {
    let pages = pagesAwaitingWrite
    pagesAwaitingWrite = [:]
    guard !pages.isEmpty, let grant else { return }
    do {
      // `grant` is held for the whole write, which keeps the security-scoped access open.
      try await grant.embedRecognisedText(pages: pages)
      Self.exportLog.notice(
        "recognised text kept in the document (\(pages.count, privacy: .public) page(s))")
    } catch {
      // Story 6.18: the reason used to be discarded here, which left "could not be kept" as the
      // only trace of a failure that could be any of three different things.
      Self.exportLog.error(
        "keeping the recognised text failed: \(String(describing: error), privacy: .public)")
      let failure = NSAlert()
      failure.messageText = String(localized: "ocr.keep.failed.title")
      failure.informativeText = String(localized: "ocr.keep.failed.message")
      // Not `reader.error.dismiss`: that button says "Try another PDF", which belongs to the
      // failure-to-open alert and makes no sense here — the document is open and unchanged, and
      // there is nothing to do but acknowledge (Story 6.18, AC6).
      failure.addButton(withTitle: String(localized: "ocr.keep.failed.dismiss"))
      failure.runModal()
    }
  }

  func offerToKeepRecognisedText() async {
    guard confirmKeepingRecognisedText() else { return }
    await writeRecognisedText()
  }

  var storageDescription: String {
    ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file)
  }

  func deleteDerivedData() {
    guard let documentID = processingSession?.documentID else { return }
    reportingTask?.cancel()
    processingCancelled = true
    do {
      try LocalStateStore.deleteDerivedData(
        documentID: documentID,
        expectedBytes: storageBytes)
      storageBytes = 0
      processingSession = nil
      normalizedPages = [:]
      normalizedSentencePages = [:]
      pageRotationOverrides = [:]
      currentUnitID = nil
      firstUnitAvailable = false
    } catch {
      processingStorageFailed = true
    }
  }

  private func requestPlan(visiblePageIndex: UInt32? = nil) {
    guard processingSession != nil else { return }
    reportingTask?.cancel()
    processingCancelled = false
    reportingTask = Task {
      _ = await applyMutation(
        action: "reprioritize",
        pageIndex: visiblePageIndex ?? UInt32(pageIndex))
      await processPendingPages()
    }
  }

  private func plan(documentID: String, visiblePageIndex: UInt32? = nil) async {
    guard !Task.isCancelled else { return }
    let visible = visiblePageIndex ?? UInt32(pageIndex)
    guard
      let event = try? await EngineClient.planSession(
        documentID: documentID,
        pageCount: UInt32(pageCount),
        visiblePageIndex: visible
      ), !Task.isCancelled
    else { return }
    guard let session = event.result?.incrementalSession else { return }
    // Names from before documents named themselves belong to no document now, and the storage
    // panel only ever offers to delete the open one's — so they go here (Story 6.25).
    LocalStateStore.discardSessionsNamedByLaunchCounter()
    _ = try? LocalStateStore.prepare(documentID: session.documentID)
    processingSession = session
    checkpoint(session)
    await processPendingPages()
  }

  private func requestMutation(action: String, pageIndex: UInt32?) {
    guard processingSession != nil else { return }
    reportingTask?.cancel()
    reportingTask = Task {
      _ = await applyMutation(action: action, pageIndex: pageIndex)
      if action != "cancel" { await processPendingPages() }
    }
  }

  private func applyMutation(
    action: String,
    pageIndex: UInt32?,
    errorCode: String? = nil
  ) async -> Bool {
    guard let processingSession,
      let event = try? await EngineClient.mutateSession(
        processingSession,
        action: action,
        pageIndex: pageIndex,
        errorCode: errorCode
      ), let session = event.result?.incrementalSession
    else { return false }
    self.processingSession = session
    checkpoint(session)
    return true
  }

  /// Settles the document's language before any page reaches Vision or the engine, so the whole
  /// document is read under one language (AC5). The task is kept rather than consumed: its value is
  /// computed once, and every caller that gets here waits for the same answer instead of racing
  /// ahead with the fallback.
  private func settleDocumentLanguage() async {
    guard identifiedDocumentLanguage == nil, let languageIdentification else { return }
    guard let identified = await languageIdentification.value else { return }
    guard identifiedDocumentLanguage == nil else { return }
    adoptDocumentLanguage(identified)
  }

  private func adoptDocumentLanguage(_ identified: DocumentLanguage.Identification) {
    identifiedDocumentLanguage = identified
    languagePagesLeftToSample = 0
    recognisedLanguageSample = ""
    Self.metrics.notice(
      """
      document_language=\(identified.language, privacy: .public) \
      confidence=\(identified.confidence, privacy: .public)
      """)
    preselectVoiceIfPossible()
  }

  private func processPendingPages() async {
    await settleDocumentLanguage()
    while !Task.isCancelled, !processingCancelled,
      let page = processingSession?.pages.first(where: { $0.state == .processing }),
      let grant
    {
      #if STRESS_TEST
        let stressPage = ProcessInfo.processInfo.environment["LECTURA_STRESS_FAIL_PAGE_INDEX"]
          .flatMap(UInt32.init)
        if !stressFailureInjected, stressPage == page.pageIndex {
          stressFailureInjected = true
          _ = await applyMutation(
            action: "fail", pageIndex: page.pageIndex, errorCode: "LF_STRESS_RETRY_REQUIRED")
          continue
        }
      #endif
      guard let documentFingerprint = await resolvedDocumentFingerprint() else {
        _ = await applyMutation(
          action: "fail", pageIndex: page.pageIndex, errorCode: "LF_FILE_FINGERPRINT_FAILED")
        continue
      }
      let generationID = "generation_\(documentFingerprint.prefix(16))"
      let forceOCR = forcedOCRPages.remove(page.pageIndex) != nil
      // The language identified for this document, not a fixed "es": it is both the hint Vision
      // recognises the page with and what the engine judges the page's own text layer by (AC2).
      let language = documentLanguage
      // A page the reader turned by hand is extracted from a copy turned the same way, so the
      // narration reads it along the axis the reader is looking at (Story 6.15).
      let rotation = pageRotationOverrides[page.pageIndex]
      var raw =
        forceOCR
        ? await grant.extractOCRPage(
          Int(page.pageIndex), language: language, rotation: rotation)
        : await grant.extractDigitalPage(Int(page.pageIndex), rotation: rotation)
      guard !Task.isCancelled, !processingCancelled else { return }
      var normalized = try? await EngineClient.normalizePage(
        raw,
        documentFingerprint: documentFingerprint,
        generationID: generationID,
        language: language,
        route: forceOCR ? "ocr" : "direct_text"
      ).result?.normalizedPage
      if !forceOCR, normalized?.record.route == "ocr" {
        raw = await grant.extractOCRPage(
          Int(page.pageIndex), language: language, rotation: rotation)
        guard !Task.isCancelled, !processingCancelled else { return }
        normalized = try? await EngineClient.normalizePage(
          raw,
          documentFingerprint: documentFingerprint,
          generationID: generationID,
          language: language,
          route: "ocr"
        ).result?.normalizedPage
      }
      guard let normalized else {
        _ = await applyMutation(
          action: "fail", pageIndex: page.pageIndex,
          errorCode: raw.errorCode ?? "LF_OCR_RECOGNITION_FAILED")
        continue
      }
      // A page the reader had to pay OCR for is a page the document could keep the recognition of.
      // The result being remembered here is the one Vision already produced for this page, so
      // accepting the offer later costs no second recognition (Story 6.6, AC6). A page read again
      // — because the reader turned it — overwrites what was remembered before, which is the whole
      // point of asking again here rather than only once.
      //
      // The question goes to the grant, which opens its own copy of the file, and *not* to
      // `document`, the copy on screen: PDFKit recognises image-only pages it displays and then
      // reports that invention as the page's own text, so the page the reader is looking at always
      // answered "there is text here already" and its recognition was never kept (Story 6.15).
      if normalized.record.route == "ocr", !raw.blocks.isEmpty,
        await grant.canKeepRecognisedText(raw, pageIndex: Int(page.pageIndex))
      {
        recognisedPagesToKeep[page.pageIndex] = raw
      }
      let sentencePage = try? await EngineClient.normalizePage(
        raw,
        documentFingerprint: documentFingerprint,
        generationID: generationID,
        language: language,
        route: normalized.record.route,
        requestedUnit: "sentence"
      ).result?.normalizedPage
      // A scan whose text layer said nothing could not answer the language question when the
      // document opened, so the words Vision has just read answer it instead (AC1). Adopted only
      // after both passes over this page, so a page is never split across two languages.
      if identifiedDocumentLanguage == nil, languagePagesLeftToSample > 0,
        normalized.record.route == "ocr", !raw.blocks.isEmpty
      {
        languagePagesLeftToSample -= 1
        recognisedLanguageSample += raw.blocks.map(\.text).joined(separator: " ") + "\n"
        // Asked off the main thread, because the vote is dozens of recogniser calls (Story 6.16),
        // and adopted only if the document has not settled its language while we waited.
        if let identified = await DocumentLanguage.identifyAsync(in: recognisedLanguageSample),
          identifiedDocumentLanguage == nil
        {
          adoptDocumentLanguage(identified)
        }
      }
      do {
        try LocalStateStore.save(
          normalized,
          pageIndex: page.pageIndex,
          documentID: processingSession?.documentID ?? "")
        processingStorageFailed = false
        normalizedPages[page.pageIndex] = normalized
        if let sentencePage { normalizedSentencePages[page.pageIndex] = sentencePage }
        if page.pageIndex == UInt32(pageIndex), currentUnitID == nil {
          selectFirstUnitForCurrentPage()
        }
        // Narration that ran ahead of extraction resumes as soon as any page at or beyond its
        // position is ready. Matching only the current page left the voice stuck whenever it had
        // already stepped onto a blank page and was waiting for the next one to be extracted.
        if narrationState == .awaitingContent, page.pageIndex >= UInt32(pageIndex),
          !normalized.units.isEmpty
        {
          startNarration {}
        }
      } catch {
        processingStorageFailed = true
        _ = await applyMutation(
          action: "fail", pageIndex: page.pageIndex,
          errorCode: "LF_LOCAL_STATE_WRITE_FAILED")
        return
      }
      // A page counts as prepared when it produced readable units, or when extraction reported no
      // technical fault at all (a blank page). Only a page that yielded nothing *and* hit a real
      // extraction fault is a failure the reader must be told about — otherwise a blank verso or a
      // degraded-but-readable scan would surface as an unrecoverable error blocking the document.
      if !normalized.units.isEmpty || raw.errorCode == nil {
        if !normalized.units.isEmpty { firstUnitAvailable = true }
        guard await applyMutation(action: "complete", pageIndex: page.pageIndex) else { return }
      } else {
        guard
          await applyMutation(
            action: "fail", pageIndex: page.pageIndex,
            errorCode: raw.errorCode ?? "LF_OCR_DEGRADED")
        else { return }
      }
    }
  }

  private func prepareDocumentForExport() async {
    while !Task.isCancelled,
      let pending = processingSession?.pages.first(where: { $0.state == .pending })
    {
      let before = processingSession?.pages.filter { $0.state == .completed }.count ?? 0
      guard await applyMutation(action: "reprioritize", pageIndex: pending.pageIndex) else {
        return
      }
      await processPendingPages()
      let after = processingSession?.pages.filter { $0.state == .completed }.count ?? 0
      if after == before { return }
    }
  }

  private func restoreResumableExportIfAvailable() {
    guard exportState == .idle, let documentFingerprint, let voiceManifest else { return }
    AudiobookExporter.pruneStaleJobs(
      workRoot: exportWorkRoot, sourceFingerprint: documentFingerprint)
    let candidate = AudiobookExporter.resumableJobs(
      workRoot: exportWorkRoot, sourceFingerprint: documentFingerprint,
      modelID: voiceManifest.id, modelRevision: voiceManifest.modelRevision
    ).first
    guard let candidate,
      voiceManifest.languages.contains(candidate.manifest.language),
      voiceManifest.voices(for: candidate.manifest.language).contains(candidate.manifest.voiceID)
    else { return }
    selectedVoiceLanguage = candidate.manifest.language
    selectedVoiceID = candidate.manifest.voiceID
    exportJobID = candidate.manifest.jobID
    exportTitle = candidate.manifest.title
    exportDestination = candidate.destinationURL
    exportDestinationScopeURL = candidate.accessRootURL
    exportDestinationHasSecurityScope =
      candidate.accessRootURL.startAccessingSecurityScopedResource()
    exportCompletedUnits = candidate.manifest.fragments.count
    exportTotalUnits = candidate.manifest.totalUnits
    exportState = .paused
  }

  private func checkpoint(_ session: LFIncrementalSessionResult) {
    do {
      try LocalStateStore.save(session)
      processingStorageFailed = false
      storageBytes = (try? LocalStateStore.usage(documentID: session.documentID)) ?? 0
    } catch {
      processingStorageFailed = true
    }
  }

  private func selectFirstUnitForCurrentPage() {
    currentUnitID = immersionUnits.first?.unitID
  }
}
