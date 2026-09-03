import MacPlatform
import SwiftUI

struct ReaderView: View {
  @State private var model = ReaderViewModel()
  @State private var showingStorage = false
  @State private var showingVoice = false
  @State private var showingOutline = false
  @State private var showingTranslation = false
  @State private var showingExport = false
  @State private var showingHelp = false
  @State private var showingImmersionControls = false
  @State private var tutorialStepIndex = 0
  @State private var showingTutorial = false
  /// Live frames of the controls the tutorial points at, published by the probes attached below
  /// (Story 6.5). Kept for the whole reading view, not only while the tutorial is up, so a step
  /// never opens against a frame that has not been measured yet.
  @State private var tutorialAnchors = TutorialAnchorRegistry()
  @AppStorage("tutorial.dontShowAgain") private var tutorialDontShowAgain = false
  @State private var hasOfferedTutorialThisLaunch = false
  @State private var immersionTheme = ImmersionTheme.paper
  @State private var autoFollowEnabled = true
  @State private var followRequest = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    mainContent
      .task { model.restoreAfterLanguageRestart() }
      .onReceive(NotificationCenter.default.publisher(for: .prepareReaderLanguageRestart)) { _ in
        model.prepareForLanguageRestart()
      }
      .onChange(of: model.readingSurface) { _, surface in
        AccessibilityNotification.Announcement(
          String(localized: surface == .pdf ? "reader.view.pdf" : "reader.view.immersion")
        ).post()
      }
      .onChange(of: model.narrationSource) { _, source in
        // AC9 (Story 5.6): a VoiceOver user needs to hear which language they are about to listen
        // to, same as a sighted reader sees from the "EN" badge on a translated passage.
        let sourceKey =
          source == .original ? "narration.source.original" : "narration.source.translation"
        var announcement = String(localized: String.LocalizationValue(sourceKey))
        if source == .translation, !model.translationTargetLanguage.isEmpty {
          announcement += ": \(model.translationTargetLanguage.uppercased())"
        }
        AccessibilityNotification.Announcement(announcement).post()
      }
      .onChange(of: model.selectedVoiceLanguage) { _, language in
        guard !language.isEmpty else { return }
        AccessibilityNotification.Announcement(
          "\(String(localized: "voice.select.language")): \(language.uppercased())"
        ).post()
      }
      .onChange(of: model.selectedVoiceID) { _, voice in
        guard !voice.isEmpty else { return }
        AccessibilityNotification.Announcement(
          "\(String(localized: "voice.select.voice")): \(voice)"
        ).post()
      }
      .onChange(of: model.exportState) { _, state in
        exportStateChanged(state)
      }
      .onReceive(NotificationCenter.default.publisher(for: .openReaderDocument)) { _ in
        model.open()
      }
      .onReceive(NotificationCenter.default.publisher(for: .toggleReadingSurface)) { _ in
        guard model.state == .reading else { return }
        model.readingSurface = model.readingSurface == .pdf ? .immersion : .pdf
      }
      .onReceive(NotificationCenter.default.publisher(for: .cancelReadingProcessing)) { _ in
        model.cancelProcessing()
      }
      .onReceive(NotificationCenter.default.publisher(for: .resumeReadingProcessing)) { _ in
        model.resumeProcessing()
      }
      .onReceive(NotificationCenter.default.publisher(for: .retryReadingProcessing)) { _ in
        guard let page = model.failedPages.first else { return }
        model.retryPage(page.pageIndex)
      }
      .onReceive(NotificationCenter.default.publisher(for: .showReaderHelp)) { _ in
        showingHelp = true
      }
      // A tiny invisible subview, not more modifiers on this chain: adding these two directly here
      // pushed the compiler's type-checker for `body` well past its time budget.
      .background(tutorialTriggers)
      .background(rotationTriggers)
      .background(overflowCommandTriggers)
      .background(narrationCommandTriggers)
      .confirmationDialog(
        "reader.storage.title",
        isPresented: $showingStorage,
        titleVisibility: .visible
      ) {
        Button("reader.storage.delete", role: .destructive) { model.deleteDerivedData() }
          .disabled(model.storageBytes == 0)
      } message: {
        Text("\(String(localized: "reader.storage.used")): \(model.storageDescription)")
      }
      .sheet(isPresented: $showingVoice) { voicePreparationSheet }
      .sheet(isPresented: $showingTranslation) { translationPreparationSheet }
      .sheet(isPresented: $showingExport) { exportPreparationSheet }
      .sheet(isPresented: $showingHelp) { helpSheet }
  }

  /// AC1: offered once the reader actually reaches the reading surface it describes — the empty
  /// state has no controls yet worth pointing at. `hasOfferedTutorialThisLaunch` keeps a reader who
  /// closes and reopens a different document within the same launch from seeing it twice;
  /// `tutorialDontShowAgain` is the persistent opt-out across launches.
  private var tutorialTriggers: some View {
    Color.clear
      .onReceive(NotificationCenter.default.publisher(for: .showReaderTutorial)) { _ in
        // AC4: the Ayuda menu entry replays the tutorial regardless of "no volver a mostrar".
        tutorialStepIndex = 0
        showingTutorial = true
      }
      .onChange(of: model.state) { _, state in offerTutorialIfNeeded(for: state) }
  }

  /// The menu-bar rotation commands, taken off `body` for the same reason as `tutorialTriggers`:
  /// two more modifiers on that chain put the expression past the compiler's type-checking budget.
  ///
  /// Same guard as the ⋯ menu, which only offers these while a document is on the PDF surface:
  /// there is no page to turn in Immersion, and none before a document is open.
  private var rotationTriggers: some View {
    Color.clear
      .onReceive(NotificationCenter.default.publisher(for: .rotateReaderPageClockwise)) { _ in
        guard model.state == .reading, model.readingSurface == .pdf else { return }
        model.rotateCurrentPage(clockwise: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .rotateReaderPageCounterclockwise)) {
        _ in
        guard model.state == .reading, model.readingSurface == .pdf else { return }
        model.rotateCurrentPage(clockwise: false)
      }
  }

  /// Story 6.24: the menu-bar counterparts of the ⋯ menu's four sheets. Each one opens exactly what
  /// the ⋯ item opens, including Export's rule that a reader without a compatible voice is sent to
  /// pick one first — two ways in, one behaviour. Split across two sub-views for the same reason
  /// `rotationTriggers` exists: `body` is already at the compiler's type-checking budget.
  private var overflowCommandTriggers: some View {
    Color.clear
      .onReceive(NotificationCenter.default.publisher(for: .showReaderVoice)) { _ in
        guard model.state == .reading else { return }
        showingVoice = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .showReaderTranslation)) { _ in
        guard model.state == .reading else { return }
        showingTranslation = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .showReaderExport)) { _ in
        guard model.state == .reading else { return }
        if model.hasCompatibleVoiceSelection { showingExport = true } else { showingVoice = true }
      }
      .onReceive(NotificationCenter.default.publisher(for: .showReaderStorage)) { _ in
        guard model.state == .reading else { return }
        showingStorage = true
      }
  }

  /// The rest of the ⋯ menu: the two skips, the speed, the narration source, and the three
  /// immersion settings. The immersion three are guarded the way the ⋯ menu hides them — there is
  /// no reading column to theme, follow or split into sentences while the PDF is on screen.
  private var narrationCommandTriggers: some View {
    Color.clear
      .onReceive(NotificationCenter.default.publisher(for: .setReaderVisibleTextVersion)) { note in
        guard let raw = note.object as? String, model.state == .reading else { return }
        model.selectVisibleText(showingOriginal: raw == "original")
      }
      .onReceive(NotificationCenter.default.publisher(for: .seekReaderNarration)) { note in
        guard let seconds = note.object as? Double else { return }
        model.seekNarration(by: seconds)
      }
      .onReceive(NotificationCenter.default.publisher(for: .setReaderNarrationRate)) { note in
        guard let rate = note.object as? Double else { return }
        model.narrationRate = rate
      }
      .onReceive(NotificationCenter.default.publisher(for: .setReaderNarrationSource)) { note in
        guard let raw = note.object as? String, model.state == .reading else { return }
        model.selectNarrationSource(raw == "translation" ? .translation : .original)
      }
      .onReceive(NotificationCenter.default.publisher(for: .setReaderTrackingUnit)) { note in
        guard let raw = note.object as? String, let unit = TrackingUnit(rawValue: raw),
          model.readingSurface == .immersion
        else { return }
        model.trackingUnit = unit
      }
      .onReceive(NotificationCenter.default.publisher(for: .setReaderImmersionTheme)) { note in
        guard let raw = note.object as? String, let theme = ImmersionTheme(rawValue: raw),
          model.readingSurface == .immersion
        else { return }
        immersionTheme = theme
      }
      .onReceive(NotificationCenter.default.publisher(for: .resumeReaderAutoFollow)) { _ in
        guard model.readingSurface == .immersion else { return }
        setAutoFollowEnabled(true)
        followRequest += 1
      }
  }

  private func offerTutorialIfNeeded(for state: ReaderState) {
    guard state == .reading, !hasOfferedTutorialThisLaunch, !tutorialDontShowAgain else { return }
    hasOfferedTutorialThisLaunch = true
    tutorialStepIndex = 0
    showingTutorial = true
  }

  private var mainContent: some View {
    Group {
      switch model.state {
      case .empty:
        ContentUnavailableView {
          Label("reader.empty.title", systemImage: "doc.richtext")
        } description: {
          Text("reader.empty.description")
        } actions: {
          openButton
        }
      case .opening:
        ProgressView("reader.opening")
          .accessibilityIdentifier("reader.opening")
      case .reading:
        readingView
      case .failed(let error):
        ContentUnavailableView {
          Label("reader.error.title", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error == .encrypted ? "reader.error.encrypted" : "reader.error.unreadable")
        } actions: {
          Button("reader.error.dismiss") { model.dismissError() }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("reader.error.dismiss")
        }
        .accessibilityIdentifier("reader.error")
      }
    }
    .frame(minWidth: 720, minHeight: 520)
  }

  private var openButton: some View {
    Button("reader.open") { model.open() }
      .keyboardShortcut("o", modifiers: .command)
      .accessibilityIdentifier("reader.open")
  }

  private var readingView: some View {
    // Reading controls live in the window's native toolbar. Every in-content layout attempt — a
    // plain VStack row, layout priorities, a safe-area inset — ended with the page displacing the
    // bar out of the window as soon as the reader turned a page. AppKit owns the titlebar, so the
    // controls simply cannot be pushed away by the document any more.
    surfaceContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .safeAreaInset(edge: .top, spacing: 0) { readerStatusRows }
      .toolbar { readerToolbarContent }
      .overlay {
        if showingTutorial {
          TutorialOverlay(
            surface: model.readingSurface,
            anchors: tutorialAnchors,
            stepIndex: $tutorialStepIndex,
            dontShowAgain: $tutorialDontShowAgain,
            onFinish: { showingTutorial = false }
          )
          .accessibilityAddTraits(.isModal)
        }
      }
  }

  @ToolbarContentBuilder
  private var readerToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button("reader.outline.toggle", systemImage: "sidebar.left") { showingOutline.toggle() }
        .keyboardShortcut("l", modifiers: [.command, .option])
        .accessibilityIdentifier("reader.outline.toggle")
    }
    ToolbarItem {
      Picker("reader.view", selection: $model.readingSurface) {
        Text("reader.view.pdf")
          .accessibilityIdentifier("reader.view.pdf.option")
          .tag(ReadingSurface.pdf)
        Text("reader.view.immersion")
          .accessibilityIdentifier("reader.view.immersion.option")
          .tag(ReadingSurface.immersion)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("reader.view")
      // Story 6.5: the tutorial reads the real frame of this native toolbar item from here.
      .background(TutorialAnchorProbe(slot: .control(.viewSwitcher), registry: tutorialAnchors))
    }
    ToolbarItem {
      narrationTransport
        .background(TutorialAnchorProbe(slot: .control(.transport), registry: tutorialAnchors))
    }
    // Immersion is a continuous scroll through the book, so page arrows and a page counter would
    // only invite fighting the scroll.
    ToolbarItem {
      if model.readingSurface == .pdf {
        HStack(spacing: 4) {
          Button("reader.previous", systemImage: "chevron.left") { model.previousPage() }
            .labelStyle(.iconOnly)
            .disabled(!model.canGoPrevious)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityIdentifier("reader.previous")
          Text("\(model.pageIndex + 1) / \(model.pageCount)")
            .monospacedDigit()
            .accessibilityLabel("reader.page")
            .accessibilityValue("\(model.pageIndex + 1) / \(model.pageCount)")
            .accessibilityIdentifier("reader.page")
          Button("reader.next", systemImage: "chevron.right") { model.nextPage() }
            .labelStyle(.iconOnly)
            .disabled(!model.canGoNext)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityIdentifier("reader.next")
        }
      }
    }
    ToolbarItem {
      overflowMenu
        .background(TutorialAnchorProbe(slot: .control(.moreMenu), registry: tutorialAnchors))
    }
  }

  private var readerStatusRows: some View {
    VStack(spacing: 0) {
      if model.translationProgressState == .translating || model.hasAnyTranslation {
        HStack(spacing: 10) {
          Text("translation.text.version")
          Picker(
            "translation.text.version",
            selection: Binding(
              get: { model.hasAnyTranslation ? model.showingOriginalText : true },
              set: { model.selectVisibleText(showingOriginal: $0) })
          ) {
            Text("narration.source.original")
              .accessibilityIdentifier("translation.text.original")
              .tag(true)
            Text("narration.source.translation")
              .accessibilityIdentifier("translation.text.translation")
              .tag(false)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .controlSize(.small)
          .frame(width: 220)
          .disabled(!model.hasAnyTranslation)
          .accessibilityLabel("translation.text.version")
          .accessibilityValue(
            String(
              localized: model.hasAnyTranslation && !model.showingOriginalText
                ? "narration.source.translation" : "narration.source.original")
          )
          .accessibilityIdentifier("translation.text.version")
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.narrationState != .idle {
        HStack(spacing: 8) {
          Text(narrationStatusKey)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("narration.status")
            .accessibilityValue(
              String(
                localized: model.narrationSource == .translation
                  ? "narration.source.translation" : "narration.source.original")
            )
          if model.narrationSkippedCount > 0 {
            Text("narration.skipped")
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .accessibilityIdentifier("narration.skipped")
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.translationProgressState == .translating || model.translationPendingCount > 0 {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(
            "\(String(localized: "translation.progress.running")) · \(model.translationTranslatedCount)/\(model.translationTranslatableCount)"
          )
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("translation.progress.running")
          Spacer(minLength: 0)
          Button("translation.request.cancel", role: .cancel) {
            model.cancelTranslationProgress()
          }
          .accessibilityIdentifier("translation.progress.cancel")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if model.translationProgressState == .failed {
        HStack(spacing: 8) {
          Label("translation.progress.failed", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .lineLimit(1)
            .accessibilityIdentifier("translation.progress.failed")
          Button("voice.retry") { model.requestTranslation() }
            .accessibilityIdentifier("translation.progress.retry")
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let session = model.processingSession {
        processingBanner(session)
      }
      Divider()
    }
    .background(.bar)
  }

  private var overflowMenu: some View {
    Menu {
      openButton
      Button("reader.view.toggle", systemImage: "arrow.triangle.2.circlepath") {
        model.readingSurface = model.readingSurface == .pdf ? .immersion : .pdf
      }
      .accessibilityIdentifier("reader.view.toggle")
      Divider()
      // A page printed sideways with nothing in the file to say so: the reader turns it, and both
      // the page on screen and the order it is read aloud in follow (Story 6.15).
      if model.readingSurface == .pdf {
        // Keyboard equivalents live once in the app's Reading menu.
        Button("reader.rotate.clockwise", systemImage: "rotate.right") {
          model.rotateCurrentPage(clockwise: true)
        }
        .accessibilityIdentifier("reader.rotate.clockwise")
        Button("reader.rotate.counterclockwise", systemImage: "rotate.left") {
          model.rotateCurrentPage(clockwise: false)
        }
        .accessibilityIdentifier("reader.rotate.counterclockwise")
        Divider()
      }
      Button("reader.storage") { showingStorage = true }
        .accessibilityIdentifier("reader.storage")
      Button("voice.action", systemImage: "waveform") { showingVoice = true }
        .accessibilityIdentifier("voice.action")
      Button("translation.action", systemImage: "character.bubble") {
        showingTranslation = true
      }
      .accessibilityIdentifier("translation.action")
      Button("export.action", systemImage: "square.and.arrow.up") {
        if model.hasCompatibleVoiceSelection {
          showingExport = true
        } else {
          showingVoice = true
        }
      }
      .accessibilityIdentifier("export.action")
      Divider()
      Picker(
        "narration.source",
        selection: Binding(
          get: { model.narrationSource },
          set: { model.selectNarrationSource($0) })
      ) {
        Text("narration.source.original")
          .accessibilityIdentifier("narration.source.original")
          .tag(NarrationSource.original)
        Text("narration.source.translation")
          .accessibilityIdentifier("narration.source.translation")
          .tag(NarrationSource.translation)
      }
      .accessibilityIdentifier("narration.source")
      if model.readingSurface == .immersion { immersionSettings }
      Divider()
      narrationSecondaryControls
      if model.narrationState == .failed {
        Divider()
        Button("narration.retry") { model.retryFailedNarration() }
          .accessibilityIdentifier("narration.retry")
        Button("narration.skip") { model.skipFailedNarrationUnit() }
          .accessibilityIdentifier("narration.skip")
      }
      if model.narrationState == .translationFailed {
        Divider()
        Button("narration.retry") { model.retryTranslationForCurrentNarrationUnit() }
          .accessibilityIdentifier("narration.translation.retry")
        Button("narration.skip") { model.skipFailedNarrationUnit() }
          .accessibilityIdentifier("narration.translation.skip")
        Button("narration.translation.revert") { model.revertNarrationToOriginal() }
          .accessibilityIdentifier("narration.translation.revert")
      }
      if model.narrationState == .missingTranslationVoice {
        Divider()
        Button("translation.voice.link") { showingVoice = true }
          .accessibilityIdentifier("narration.translation.voice_link")
      }
      if model.narrationState == .missingVoiceRuntime
        || model.narrationState == .missingVoiceModel
      {
        Divider()
        Button("voice.storage.choose") { model.chooseModelStorage() }
          .accessibilityIdentifier("narration.runtime.choose_storage")
      }
    } label: {
      Label("reader.more", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("reader.more")
  }

  private func processingBanner(_ session: LFIncrementalSessionResult) -> some View {
    HStack(spacing: 10) {
      if let page = model.failedPages.first {
        VStack(alignment: .leading, spacing: 6) {
          Label("reader.processing.page_failed", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .lineLimit(1)
          HStack(spacing: 8) {
            Button("reader.processing.retry") { model.retryPage(page.pageIndex) }
              .accessibilityLabel("reader.processing.retry")
              .accessibilityValue("\(page.pageIndex + 1)")
              .accessibilityIdentifier("reader.processing.retry.\(page.pageIndex)")
            Button("reader.processing.skip") { model.skipPage(page.pageIndex) }
              .accessibilityLabel("reader.processing.skip")
              .accessibilityValue("\(page.pageIndex + 1)")
              .accessibilityIdentifier("reader.processing.skip.\(page.pageIndex)")
            Button("reader.processing.force_ocr") { model.forceOCRPage(page.pageIndex) }
              .accessibilityLabel("reader.processing.force_ocr")
              .accessibilityValue("\(page.pageIndex + 1)")
              .accessibilityIdentifier("reader.processing.force_ocr.\(page.pageIndex)")
          }
        }
      } else {
        ProgressView(value: model.processingProgress)
          .frame(maxWidth: 180)
        Text(
          model.processingStorageFailed
            ? "reader.processing.storage_failed"
            : model.processingCancelled
              ? "reader.processing.cancelled"
              : model.firstUnitAvailable
                ? "reader.processing.first_unit_ready" : "reader.processing.active"
        )
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      Menu("reader.processing.details") {
        ForEach(session.pages, id: \.pageIndex) { page in
          (Text("\(page.pageIndex + 1): ") + Text(LocalizedStringKey(page.state.nameKey)))
            .accessibilityValue("\(page.pageIndex + 1)")
            .accessibilityIdentifier(
              "reader.processing.page.\(page.pageIndex).\(page.state.rawValue)")
        }
      }
      .fixedSize()
      .accessibilityIdentifier("reader.processing.details")
      if !model.processingCancelled {
        Button("reader.processing.cancel") { model.cancelProcessing() }
          .accessibilityIdentifier("reader.processing.cancel")
      } else {
        Button("reader.processing.resume") { model.resumeProcessing() }
          .accessibilityIdentifier("reader.processing.resume")
      }
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("reader.processing.status")
  }

  /// Table-of-contents navigator. In the PDF surface it is a full sidebar like any PDF reader; in
  /// Immersion it keeps the same content but stripped down so it does not fight the reading page.
  private var outlineNavigator: some View {
    let entries = model.documentOutline
    return VStack(alignment: .leading, spacing: 0) {
      if model.readingSurface == .pdf {
        HStack {
          Text("reader.outline.title").font(.headline)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        Divider()
      }
      if entries.isEmpty {
        Text("reader.outline.empty")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("reader.outline.empty")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
              Button {
                model.goToOutlineEntry(entry)
                if model.readingSurface == .immersion { showingOutline = false }
              } label: {
                HStack(spacing: 6) {
                  Text(entry.title)
                    .font(model.readingSurface == .immersion ? .callout : .body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                  Spacer(minLength: 6)
                  Text("\(entry.pageIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(entry.level) * 12)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .background(
                entry.pageIndex == model.pageIndex ? readingPulse.opacity(0.12) : Color.clear
              )
              .accessibilityIdentifier("reader.outline.entry.\(entry.pageIndex)")
            }
          }
        }
      }
    }
    .frame(width: model.readingSurface == .immersion ? 260 : 280, alignment: .top)
    .accessibilityIdentifier("reader.outline")
  }

  @ViewBuilder
  private var surfaceContent: some View {
    VStack(spacing: 0) {
      if model.exportState != .idle { exportStatus }

      if let document = model.document {
        HStack(spacing: 0) {
          if showingOutline && model.readingSurface == .pdf {
            outlineNavigator
              .frame(maxHeight: .infinity, alignment: .top)
            Divider()
          }
          ZStack {
            PDFReaderView(
              document: document,
              pageIndex: model.pageIndex,
              sourceRegion: model.currentSourceRegion,
              firstPagePresented: model.firstPagePresented,
              startReadingAt: { point, page in
                model.beginReading(atPagePoint: point, onPage: page) { showingVoice = true }
              },
              startReadingTranslatedUnit: { unitID in
                model.beginReadingTranslated(at: unitID) { showingVoice = true }
              },
              visiblePageChanged: { model.didDisplayPage($0) },
              translatedBlocks: model.translatedOverlayBlocks,
              pageRotations: model.pageRotationOverrides,
              isVisible: model.readingSurface == .pdf
            )
            .opacity(model.readingSurface == .pdf ? 1 : 0)
            .allowsHitTesting(model.readingSurface == .pdf)
            .accessibilityHidden(pdfAccessibilityHidden)

            immersionView
              .overlay(alignment: .topLeading) {
                // Immersion keeps the same navigator, shown on demand so the reading column stays
                // the focus instead of permanently giving up width to a sidebar.
                if showingOutline && model.readingSurface == .immersion {
                  outlineNavigator
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 12)
                    .padding(12)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .opacity(model.readingSurface == .immersion ? 1 : 0)
              .allowsHitTesting(model.readingSurface == .immersion)
              .accessibilityHidden(model.readingSurface != .immersion)
          }
          .background(TutorialAnchorProbe(slot: .control(.readingArea), registry: tutorialAnchors))
        }
      }
      #if DEBUG
        if let milliseconds = model.firstPageMilliseconds {
          Text("\(milliseconds)")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityLabel("First page milliseconds")
            .accessibilityValue("\(milliseconds)")
            .accessibilityIdentifier("reader.first-page-ms")
        }
      #endif
    }
  }

  private var immersionView: some View {
    HStack(spacing: 0) {
      readingScore
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 28) {
            let stream = model.immersionStream
            if stream.isEmpty {
              Text("reader.immersion.pending")
                .font(.system(size: 18, design: .serif))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reader.immersion.pending")
            } else {
              ForEach(stream, id: \.unit.unitID) { entry in
                immersionUnit(entry.unit)
                  .id(entry.unit.unitID)
              }
            }
          }
          .frame(maxWidth: 620, alignment: .leading)
          .padding(.horizontal, 72)
          .padding(.vertical, 88)
          .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: model.currentUnitID) { _, unitID in
          guard autoFollowEnabled, let unitID else { return }
          if reduceMotion {
            proxy.scrollTo(unitID, anchor: .center)
          } else {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(unitID, anchor: .center) }
          }
        }
        .onChange(of: followRequest) {
          guard let unitID = model.currentUnitID else { return }
          proxy.scrollTo(unitID, anchor: .center)
        }
        .onScrollPhaseChange { _, phase in
          if phase == .interacting { setAutoFollowEnabled(false) }
        }
      }
    }
    .background(immersionTheme.background)
    .onHover { showingImmersionControls = $0 }
    .accessibilityLabel("reader.view.immersion")
    .accessibilityIdentifier("reader.immersion")
  }

  /// Settings that only make sense while reading in immersion. The floating overlay that used to
  /// carry them duplicated the window toolbar, so only the immersion-specific controls survive and
  /// they now live in the same overflow menu as everything else.
  @ViewBuilder
  private var immersionSettings: some View {
    Divider()
    Picker("reader.unit", selection: $model.trackingUnit) {
      Text("reader.unit.paragraph").tag(TrackingUnit.paragraph)
      Text("reader.unit.sentence").tag(TrackingUnit.sentence)
    }
    Picker("reader.immersion.theme", selection: $immersionTheme) {
      ForEach(ImmersionTheme.allCases) { theme in Text(theme.label).tag(theme) }
    }
    Button("reader.follow.resume", systemImage: "scope") {
      setAutoFollowEnabled(true)
      followRequest += 1
    }
    .disabled(autoFollowEnabled)
    .accessibilityIdentifier("reader.follow.resume")
  }

  private func setAutoFollowEnabled(_ enabled: Bool) {
    autoFollowEnabled = enabled
    ReaderSurfaceCoordinator.shared.autoFollowEnabled = enabled
  }

  private var voicePreparationSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("voice.title", systemImage: "waveform")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("voice.close") { showingVoice = false }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("voice.close")
      }
      Text("voice.purpose")
        .foregroundStyle(.secondary)
      HStack {
        Text(model.modelStorageDescription)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("voice.storage.choose") { model.chooseModelStorage() }
          .accessibilityIdentifier("voice.storage.choose")
      }
      if let manifest = model.voiceManifest, model.voicePreparationState != .installed {
        DisclosureGroup("voice.details") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            voiceDetail("voice.model", manifest.id)
            voiceDetail("voice.version", manifest.modelRevision)
            voiceDetail(
              "voice.languages", manifest.languages.joined(separator: ", ").uppercased())
            voiceDetail("voice.authors", manifest.authors.joined(separator: ", "))
            voiceDetail("voice.license", manifest.licenseId)
            voiceDetail("voice.source", manifest.artifacts.first?.publisher ?? "—")
            voiceDetail(
              "voice.format",
              Set(manifest.artifacts.map(\.format)).sorted().joined(separator: ", "))
            voiceDetail(
              "voice.precision",
              Set(manifest.artifacts.map(\.quantization)).sorted().joined(separator: ", "))
            voiceDetail("voice.hash", manifest.artifacts.first?.sha256Hex ?? "—")
            voiceDetail("voice.storage", model.voiceStorageDescription)
          }
          .padding(.top, 8)
        }
        .textSelection(.enabled)
      }
      if model.voicePreparationState == .downloading {
        ProgressView(value: model.voiceProgress)
          .accessibilityIdentifier("voice.progress")
        Button("voice.cancel", role: .cancel) { model.cancelVoicePreparation() }
          .accessibilityIdentifier("voice.cancel")
      } else if model.voicePreparationState == .installed {
        VStack(alignment: .leading, spacing: 12) {
          Label("voice.installed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityIdentifier("voice.installed")
          Picker(
            "voice.select.language",
            selection: Binding(
              get: { model.selectedVoiceLanguage },
              set: { model.selectVoiceLanguage($0) })
          ) {
            Text("voice.select.none").tag("")
            ForEach(model.availableVoiceLanguages, id: \.self) { language in
              Text(Locale.current.localizedString(forLanguageCode: language) ?? language)
                .tag(language)
            }
          }
          .accessibilityIdentifier("voice.language")
          Picker(
            "voice.select.voice",
            selection: Binding(
              get: { model.selectedVoiceID },
              set: { model.selectVoice($0) })
          ) {
            Text("voice.select.none").tag("")
            ForEach(model.availableVoiceIDs, id: \.self) { voice in
              Text(voice.replacingOccurrences(of: "_", with: " ")).tag(voice)
            }
          }
          .disabled(model.selectedVoiceLanguage.isEmpty)
          .accessibilityIdentifier("voice.selector")
          if model.hasCompatibleVoiceSelection {
            Text("voice.select.active")
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("voice.active")
          }
          if let manifest = model.voiceManifest {
            DisclosureGroup("voice.details") {
              Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                voiceDetail("voice.storage", model.voiceStorageDescription)
                voiceDetail("voice.source", manifest.artifacts.first?.publisher ?? "—")
                voiceDetail("voice.license", manifest.licenseId)
              }
              .padding(.top, 8)
            }
          }
        }
      } else {
        if model.voicePreparationState == .failed {
          Text(voiceFailureKey)
            .foregroundStyle(.red)
            .accessibilityIdentifier("voice.error")
        } else if model.voicePreparationState == .cancelled {
          Text("voice.cancelled").foregroundStyle(.secondary)
        }
        Button(
          model.voicePreparationState == .failed || model.voicePreparationState == .cancelled
            ? "voice.retry" : "voice.download"
        ) { model.prepareVoice() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("voice.download")
      }
    }
    .padding(28)
    .frame(minWidth: 560, idealWidth: 620)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voice.sheet")
  }

  private var translationPreparationSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("translation.title", systemImage: "character.bubble")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("voice.close") { showingTranslation = false }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("translation.close")
      }
      Text("translation.purpose")
        .foregroundStyle(.secondary)
      HStack {
        Text(model.modelStorageDescription)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("voice.storage.choose") { model.chooseModelStorage() }
          .accessibilityIdentifier("translation.storage.choose")
      }
      if let manifest = model.translationManifest {
        DisclosureGroup("voice.details") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            voiceDetail("voice.model", manifest.id)
            voiceDetail("voice.version", manifest.modelRevision)
            voiceDetail("voice.languages", manifest.languages.joined(separator: ", ").uppercased())
            voiceDetail(
              "translation.directions", model.translationDirections.joined(separator: ", "))
            voiceDetail("voice.authors", manifest.authors.joined(separator: ", "))
            voiceDetail("voice.license", manifest.licenseId)
            voiceDetail("voice.source", manifest.artifacts.first?.publisher ?? "—")
            voiceDetail(
              "voice.format",
              Set(manifest.artifacts.map(\.format)).sorted().joined(separator: ", "))
            voiceDetail(
              "voice.precision",
              Set(manifest.artifacts.map(\.quantization)).sorted().joined(separator: ", "))
            voiceDetail("voice.hash", manifest.artifacts.first?.sha256Hex ?? "—")
            voiceDetail("voice.storage", model.translationStorageDescription)
          }
          .padding(.top, 8)
        }
        .textSelection(.enabled)
      }
      if model.translationPreparationState == .downloading {
        ProgressView(value: model.translationProgress)
          .accessibilityIdentifier("translation.progress")
        Button("voice.cancel", role: .cancel) { model.cancelTranslationPreparation() }
          .accessibilityIdentifier("translation.cancel")
      } else if model.translationPreparationState == .installed {
        VStack(alignment: .leading, spacing: 12) {
          Label("translation.installed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityIdentifier("translation.installed")
          if model.availableTranslationTargetLanguages.isEmpty {
            Text("translation.select.unavailable")
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("translation.select.unavailable")
          } else {
            Picker(
              "translation.select.target",
              selection: Binding(
                get: { model.translationTargetLanguage },
                set: { model.selectTranslationTargetLanguage($0) })
            ) {
              Text("voice.select.none").tag("")
              ForEach(model.availableTranslationTargetLanguages, id: \.self) { language in
                Text(Locale.current.localizedString(forLanguageCode: language) ?? language)
                  .tag(language)
              }
            }
            .accessibilityIdentifier("translation.target")
            if !model.translationTargetLanguage.isEmpty {
              Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                voiceDetail(
                  "translation.select.target",
                  Locale.current.localizedString(forLanguageCode: model.translationTargetLanguage)
                    ?? model.translationTargetLanguage)
                if let manifest = model.translationManifest {
                  voiceDetail("voice.model", manifest.id)
                }
                voiceDetail(
                  "translation.voice.status",
                  String(
                    localized: model.hasVoiceForTranslationTarget
                      ? "translation.voice.available" : "translation.voice.missing"))
              }
              if !model.hasVoiceForTranslationTarget {
                Button("translation.voice.link") {
                  showingTranslation = false
                  showingVoice = true
                }
                .accessibilityIdentifier("translation.voice.link")
              }
              if model.translationRequested {
                Label("translation.requested", systemImage: "checkmark.circle")
                  .foregroundStyle(.green)
                  .accessibilityIdentifier("translation.requested")
                Button("translation.request.cancel", role: .cancel) {
                  model.cancelTranslationRequest()
                }
                .accessibilityIdentifier("translation.request.cancel")
              } else {
                Button("translation.request.start") { model.requestTranslation() }
                  .keyboardShortcut(.defaultAction)
                  .accessibilityIdentifier("translation.request.start")
              }
            }
          }
        }
      } else {
        if model.translationPreparationState == .failed {
          Text(translationFailureKey)
            .foregroundStyle(.red)
            .accessibilityIdentifier("translation.error")
        } else if model.translationPreparationState == .cancelled {
          Text("voice.cancelled").foregroundStyle(.secondary)
        }
        Button(
          model.translationPreparationState == .failed
            || model.translationPreparationState == .cancelled
            ? "voice.retry" : "translation.download"
        ) { model.prepareTranslation() }
        .keyboardShortcut(.defaultAction)
        .disabled(model.translationManifest == nil)
        .accessibilityIdentifier("translation.download")
      }
    }
    .padding(28)
    .frame(minWidth: 560, idealWidth: 620)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("translation.sheet")
  }

  private var exportPreparationSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("export.title", systemImage: "waveform.badge.plus")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("voice.close") { showingExport = false }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        model.exportingTranslation ? "export.scope.full_translation" : "export.scope.full_original"
      )
      .foregroundStyle(.secondary)
      Group {
        if model.exportChapters.isEmpty {
          Text("export.chapters.continuous")
        } else {
          Text("export.chapters.available")
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      TextField("export.name", text: $model.exportTitle)
        .accessibilityIdentifier("export.name")
      Picker(
        "export.language",
        selection: Binding(
          get: { model.selectedVoiceLanguage },
          set: { model.selectVoiceLanguage($0) })
      ) {
        ForEach(model.availableVoiceLanguages, id: \.self) { language in
          Text(Locale.current.localizedString(forLanguageCode: language) ?? language).tag(language)
        }
      }
      .accessibilityIdentifier("export.language")
      Picker(
        "export.voice",
        selection: Binding(get: { model.selectedVoiceID }, set: { model.selectVoice($0) })
      ) {
        ForEach(model.availableVoiceIDs, id: \.self) { voice in
          Text(voice.replacingOccurrences(of: "_", with: " ")).tag(voice)
        }
      }
      .accessibilityIdentifier("export.voice")
      HStack {
        Text(
          model.exportDestination?.lastPathComponent ?? String(localized: "export.destination.none")
        )
        .lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("export.destination.choose") { model.chooseExportDestination() }
          .accessibilityIdentifier("export.destination")
      }
      if model.exportingTranslation {
        // AC2 (Story 5.9): source/target language, translation model, target voice, and how much of
        // the document is already translated versus what export would still have to translate —
        // the same preflight a reader gets before Original, but for what they are actually listening
        // to right now.
        Label("export.translation.notice", systemImage: "character.bubble")
          .foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          exportDetail("export.translation.source", model.selectedVoiceLanguage.uppercased())
          exportDetail("export.translation.target", model.translationTargetLanguage.uppercased())
          exportDetail("export.translation.model", model.translationManifest?.id ?? "—")
          exportDetail(
            "export.voice",
            (model.translationVoiceID ?? "—").replacingOccurrences(
              of: "_", with: " "))
          exportDetail("export.translation.translated", "\(model.exportTranslatedUnitsCount)")
          exportDetail("export.translation.pending", "\(model.exportTranslationPendingUnitsCount)")
          exportDetail("export.translation.failed", "\(model.exportTranslationFailedUnitsCount)")
        }
        if !model.hasTranslationExportPrerequisites {
          Label("export.translation.missing", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
        if !model.exportingTranslation {
          exportDetail("export.language", model.selectedVoiceLanguage.uppercased())
          exportDetail(
            "export.voice", model.selectedVoiceID.replacingOccurrences(of: "_", with: " "))
        }
        exportDetail("export.duration", model.exportEstimatedDurationDescription)
        exportDetail("export.size", model.exportEstimatedSizeDescription)
        exportDetail("export.space", model.exportAvailableSpaceDescription)
        exportDetail("export.ready", "\(model.exportReadyUnits.count)")
        exportDetail("export.chapters.count", "\(model.exportChapters.count)")
        exportDetail("export.pending", "\(model.exportPendingPages)")
        exportDetail("export.degraded", "\(model.exportDegradedUnits)")
        exportDetail("export.omitted", "\(model.exportNonNarrableUnits)")
      }
      if model.exportDegradedUnits + model.exportNonNarrableUnits > 0 {
        Label("export.warning.degraded", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
      Text("export.live_paused").font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("export.start") {
          model.beginExport()
          showingExport = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          model.exportDestination == nil || !model.hasCompatibleVoiceSelection
            || (model.exportingTranslation && !model.hasTranslationExportPrerequisites)
        )
        .accessibilityIdentifier("export.start")
      }
    }
    .padding(28)
    .frame(minWidth: 540)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("export.sheet")
  }

  private var helpSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("help.title", systemImage: "questionmark.circle")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("voice.close") { showingHelp = false }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("help.close")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          helpSection(
            "help.usage.title",
            items: ["help.open", "help.narrate", "help.export", "help.storage", "help.keyboard"])
          helpSection(
            "limits.title",
            items: [
              "limits.translation", "limits.languages", "limits.export_secondary",
              "limits.resources", "limits.format", "limits.content",
            ])
          helpSection(
            "privacy.title",
            items: [
              "privacy.local", "privacy.network", "privacy.no_upload", "privacy.no_telemetry",
              "privacy.permissions", "privacy.storage",
            ])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(28)
    .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 560)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("help.sheet")
  }

  private func helpSection(_ title: String, items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(LocalizedStringKey(title))
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(items, id: \.self) { item in
        Text(LocalizedStringKey(item))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(title)
  }

  private var exportStatus: some View {
    HStack(spacing: 10) {
      ProgressView(value: model.exportProgress).frame(maxWidth: 180)
      Text("\(model.exportCompletedUnits) / \(model.exportTotalUnits)").monospacedDigit()
      Text(model.exportDestination?.lastPathComponent ?? "—").lineLimit(1)
      Text("\(String(localized: "export.remaining")): \(model.exportRemainingDescription)")
        .foregroundStyle(.secondary)
      if case .failed(let error) = model.exportState {
        Label(exportFailureKey(error), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
      Spacer()
      switch model.exportState {
      case .preparing, .exporting:
        Button("export.pause") { model.pauseExport() }
        Button("export.cancel", role: .cancel) { model.cancelExport() }
      case .paused:
        Button("export.resume") { model.resumeExport() }
        Button("export.cancel", role: .cancel) { model.cancelExport() }
      case .failed:
        if case .failed(let error) = model.exportState,
          error == .invalidManifest || error == .missingFragment
        {
          Button("export.restart") { model.restartExport() }
        } else {
          if case .failed(let error) = model.exportState,
            error == .insufficientSpace || error == .destinationUnavailable
              || error == .permissionDenied || error == .destinationExists
          {
            Button("export.destination.choose") { model.chooseExportDestination() }
          }
          Button("export.retry") { model.retryExport() }
        }
        Button("export.cancel", role: .cancel) { model.cancelExport() }
      case .completed:
        Button("export.reveal") { model.revealCompletedExport() }
        Button("export.open") { model.openCompletedExport() }
      case .cancelled, .idle:
        EmptyView()
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("export.status")
  }

  private func exportFailureKey(_ error: AudiobookExportError) -> LocalizedStringKey {
    switch error {
    case .noNarrableUnits: "export.error.no_units"
    case .insufficientSpace: "export.error.space"
    case .destinationUnavailable: "export.error.destination"
    case .destinationExists: "export.error.exists"
    case .permissionDenied: "export.error.permission"
    case .synthesisFailed: "export.error.synthesis"
    case .encodingFailed: "export.error.encoding"
    case .missingFragment: "export.error.fragment"
    case .invalidManifest: "export.error.manifest"
    case .verificationFailed: "export.error.verification"
    case .translationFailed: "export.error.translation"
    case .paused: "export.status.paused"
    case .cancelled: "export.status.cancelled"
    }
  }

  private func exportDetail(_ key: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(key).foregroundStyle(.secondary)
      Text(value)
    }
  }

  private func voiceDetail(_ key: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(key).foregroundStyle(.secondary)
      Text(value).font(.body.monospaced()).lineLimit(2).truncationMode(.middle)
    }
  }

  private var voiceFailureKey: LocalizedStringKey {
    switch model.voicePreparationFailure {
    case .missingModel: "voice.error.missing"
    case .incompatible: "voice.error.incompatible"
    case .corruptArtifact: "voice.error.corrupt"
    case .interruptedDownload: "voice.error.interrupted"
    case .insufficientSpace: "voice.error.space"
    case .loadFailed: "voice.error.load"
    case nil: "voice.error"
    }
  }

  private var translationFailureKey: LocalizedStringKey {
    switch model.translationPreparationFailure {
    case .missingModel: "translation.error.missing"
    case .incompatible: "translation.error.incompatible"
    case .corruptArtifact: "translation.error.corrupt"
    case .interruptedDownload: "translation.error.interrupted"
    case .insufficientSpace: "translation.error.space"
    case .loadFailed: "translation.error.load"
    case nil: "translation.error"
    }
  }

  /// Progress through the whole document. A tick per passage of the current page stopped making
  /// sense once immersion became one continuous scroll, and the page number it carried is exactly
  /// what this surface is meant to let the reader forget.
  private var readingScore: some View {
    GeometryReader { geometry in
      let travel = max(geometry.size.height - 28, 0)
      ZStack(alignment: .top) {
        Capsule()
          .fill(Color.secondary.opacity(0.15))
          .frame(width: 2)
          .frame(maxHeight: .infinity)
        Capsule()
          .fill(readingPulse)
          .frame(width: 3, height: 28)
          .offset(y: travel * model.readingProgress)
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .frame(width: 24)
    .padding(.vertical, 24)
    .overlay(alignment: .trailing) { Divider() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("reader.progress")
    .accessibilityValue("\(Int(model.readingProgress * 100))%")
    .accessibilityIdentifier("reader.immersion.score")
  }

  private var narrationStatusKey: LocalizedStringKey {
    switch model.narrationState {
    case .idle: "narration.status.idle"
    case .preparing: "narration.status.preparing"
    case .playing: "narration.status.playing"
    case .paused: "narration.status.paused"
    case .awaitingContent: "narration.status.awaiting"
    case .finished: "narration.status.finished"
    case .failed: "narration.status.failed"
    case .awaitingTranslation: "narration.status.awaiting_translation"
    case .translationFailed: "narration.status.translation_failed"
    case .missingTranslationVoice: "narration.status.missing_translation_voice"
    case .missingVoiceRuntime: "narration.status.missing_runtime"
    case .missingVoiceModel: "narration.status.missing_model"
    }
  }

  private func exportAnnouncement(_ state: AudiobookExportState) -> String {
    let key: LocalizedStringResource =
      switch state {
      case .idle: "export.status.idle"
      case .preparing: "export.status.preparing"
      case .exporting: "export.status.exporting"
      case .paused: "export.status.paused"
      case .completed: "export.status.completed"
      case .cancelled: "export.status.cancelled"
      case .failed: "export.status.failed"
      }
    return String(localized: key)
  }

  private func exportStateChanged(_ state: AudiobookExportState) {
    let coordinator = ExportTerminationCoordinator.shared
    coordinator.isExporting = state == .preparing || state == .exporting
    coordinator.pause = { model.pauseExport() }
    AccessibilityNotification.Announcement(exportAnnouncement(state)).post()
  }

  /// Only play/pause and unit stepping stay in the toolbar; seeking and speed live in the overflow
  /// menu so page navigation is never pushed off-screen on a narrow window.
  private var narrationTransport: some View {
    HStack(spacing: 6) {
      Button("narration.previous", systemImage: "backward.end.fill") {
        model.moveNarrationUnit(by: -1)
      }
      .labelStyle(.iconOnly)
      .accessibilityIdentifier("narration.previous")
      Button(
        model.narrationState == .playing
          ? "narration.pause"
          : model.narrationState == .paused ? "narration.resume" : "narration.play",
        systemImage: model.narrationState == .playing ? "pause.fill" : "play.fill"
      ) {
        model.toggleNarration { showingVoice = true }
      }
      .labelStyle(.iconOnly)
      .keyboardShortcut(.space, modifiers: [])
      .accessibilityIdentifier("narration.toggle")
      Button("narration.next", systemImage: "forward.end.fill") {
        model.moveNarrationUnit(by: 1)
      }
      .labelStyle(.iconOnly)
      .accessibilityIdentifier("narration.next")
    }
    .fixedSize()
  }

  @ViewBuilder
  private var narrationSecondaryControls: some View {
    Button("narration.rewind", systemImage: "gobackward.15") { model.seekNarration(by: -15) }
      .accessibilityIdentifier("narration.rewind")
    Button("narration.forward", systemImage: "goforward.15") { model.seekNarration(by: 15) }
      .accessibilityIdentifier("narration.forward")
    Picker("narration.speed", selection: $model.narrationRate) {
      Text("0.75×").tag(0.75)
      Text("1×").tag(1.0)
      Text("1.25×").tag(1.25)
      Text("1.5×").tag(1.5)
      Text("2×").tag(2.0)
    }
    .accessibilityLabel("narration.speed")
    .accessibilityValue("\(model.narrationRate, specifier: "%.2g")×")
    .accessibilityIdentifier("narration.speed")
  }

  @ViewBuilder
  private func immersionUnit(_ unit: LFReadingUnit) -> some View {
    let active = unit.unitID == model.currentUnitID
    let translated = model.isShowingTranslation(unit)
    // A chapter title is read aloud like the rest (`ReaderViewModel.isNarrable`), so it has to be
    // on the page as words the voice can be followed through. Falling to the marker below printed
    // "contenido no compatible" where the title was, and the reading highlight — which only exists
    // in this branch — had nothing to land on while the voice spoke it.
    if unit.contentClass == "prose" || unit.contentClass == "note"
      || unit.contentClass == "heading"
    {
      Text(model.displayText(for: unit))
        .font(immersionFont(for: unit.contentClass))
        .lineSpacing(7)
        .foregroundStyle(immersionTheme.foreground)
        .textSelection(.enabled)
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? readingPulse.opacity(0.09) : Color.clear)
        .overlay(alignment: .leading) {
          if active { Rectangle().fill(readingPulse).frame(width: 3) }
        }
        .overlay(alignment: .topTrailing) {
          // A translated passage says so, so the reader never mistakes a translation for the book.
          if translated {
            Text(model.translationTargetLanguage.uppercased())
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(readingPulse.opacity(0.16)))
              .foregroundStyle(.secondary)
              .padding(.trailing, 6)
              .accessibilityHidden(true)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          beginReading(unit, translated: translated)
        }
        .onTapGesture { model.selectUnit(unit.unitID) }
        .help("reader.immersion.start_here")
        .accessibilityValue(translated ? String(localized: "translation.badge") : "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction(named: Text("reader.immersion.start_here")) {
          beginReading(unit, translated: translated)
        }
        .accessibilityIdentifier("reader.immersion.unit.\(unit.unitID)")
    } else {
      Text(markerKey(for: unit.contentClass))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("reader.immersion.degraded.\(unit.unitID)")
    }
  }

  private func beginReading(_ unit: LFReadingUnit, translated: Bool) {
    if translated {
      model.beginReadingTranslated(at: unit.unitID) { showingVoice = true }
    } else {
      model.beginReading(at: unit.unitID) { showingVoice = true }
    }
  }

  /// Body, footnote and chapter title read as what they are. Kept out of the modifier chain above:
  /// `body` is already at the type-checker's budget in this view.
  private func immersionFont(for contentClass: String) -> Font {
    switch contentClass {
    case "note": .system(size: 16, design: .serif)
    case "heading": .system(size: 24, weight: .semibold, design: .serif)
    default: .system(size: 19, design: .serif)
    }
  }

  private func markerKey(for contentClass: String) -> LocalizedStringKey {
    switch contentClass {
    case "table": "reader.immersion.table"
    case "formula": "reader.immersion.formula"
    case "note": "reader.immersion.note"
    default: "reader.immersion.unsupported"
    }
  }

  private var readingPulse: Color { Color(red: 0.38, green: 0.25, blue: 0.72) }

  private var pdfAccessibilityHidden: Bool {
    #if STRESS_TEST
      true
    #else
      model.readingSurface != .pdf
    #endif
  }
}

private enum ImmersionTheme: String, CaseIterable, Identifiable {
  case paper, sepia, dark
  var id: Self { self }
  var label: String { rawValue.capitalized }
  var background: Color {
    switch self {
    case .paper: Color(nsColor: .textBackgroundColor)
    case .sepia: Color(red: 0.94, green: 0.90, blue: 0.79)
    case .dark: Color(red: 0.08, green: 0.08, blue: 0.09)
    }
  }
  var foreground: Color { self == .dark ? Color(white: 0.88) : Color(white: 0.14) }
}
