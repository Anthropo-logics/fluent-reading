import CoreGraphics
import Darwin
import XCTest

final class ReaderWindowUITests: XCTestCase {
  @MainActor
  func testInitialWindowOffersNativePDFOpeningFromKeyboard() {
    let app = application()
    app.launch()

    let open = app.buttons["reader.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    app.typeKey("o", modifierFlags: .command)
    XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(open.waitForExistence(timeout: 2))
  }

  @MainActor
  func testOpensRealPDFAndNavigatesWithKeyboard() throws {
    let staging = try stageRealPDF(realCorpusPDFs().first)
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
    let pdf = staging
    let app = application()
    app.launch()
    defer { app.terminate() }

    app.typeKey("o", modifierFlags: .command)
    XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.firstMatch.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.click()
    location.typeKey("a", modifierFlags: .command)
    location.typeText(pdf.path)
    app.typeKey(.return, modifierFlags: [])
    openButton(in: app).click()

    let page = app.staticTexts["reader.page"]
    XCTAssertTrue(page.waitForExistence(timeout: 60))
    dismissTutorialIfShown(in: app)
    attachScreenshot(app, name: "story-3-reader-pdf")
    // The element itself only exists once the metric is computed, so waiting for it must not be
    // bounded by the 2 s NFR4 budget that metric is measuring — a genuine budget overrun would
    // then surface as a confusing "element not found" instead of a clear assertion on the value.
    XCTAssertTrue(app.staticTexts["reader.first-page-ms"].waitForExistence(timeout: 15))
    let total = pageTotal(from: page.value as? String)
    XCTAssertGreaterThan(total, 1)
    let previous = app.buttons["reader.previous"]
    let next = app.buttons["reader.next"]
    XCTAssertFalse(previous.isEnabled)
    XCTAssertFalse(previous.label.isEmpty)
    XCTAssertTrue(next.isEnabled)
    XCTAssertFalse(next.label.isEmpty)
    let document = app.descendants(matching: .any)
      .matching(identifier: "reader.document").firstMatch
    XCTAssertTrue(document.exists)
    XCTAssertFalse(document.label.isEmpty)
    let processing = app.descendants(matching: .any)
      .matching(identifier: "reader.processing.status").firstMatch
    XCTAssertTrue(processing.waitForExistence(timeout: 2))
    let cancelProcessing = app.buttons["reader.processing.cancel"]
    XCTAssertTrue(cancelProcessing.waitForExistence(timeout: 5))
    cancelProcessing.click()
    let resumeProcessing = app.buttons["reader.processing.resume"]
    XCTAssertTrue(resumeProcessing.waitForExistence(timeout: 5))
    resumeProcessing.click()
    XCTAssertTrue(cancelProcessing.waitForExistence(timeout: 5))
    let immersionOption = app.descendants(matching: .any)
      .matching(identifier: "reader.view.immersion.option").firstMatch
    XCTAssertTrue(immersionOption.waitForExistence(timeout: 5))
    let pageBeforeToggle = page.value as? String
    immersionOption.click()
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "reader.immersion").firstMatch
        .waitForExistence(timeout: 5))
    let unit = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.immersion.unit.'"))
      .firstMatch
    XCTAssertTrue(unit.waitForExistence(timeout: 5))
    unit.hover()
    XCTAssertTrue(app.buttons["narration.toggle"].waitForExistence(timeout: 2))
    // narration.speed lives inside the "reader.more" menu's content, which SwiftUI does not
    // attach to the accessibility tree until the menu is actually open.
    let more = app.popUpButtons["reader.more"]
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    more.click()
    let speed = app.descendants(matching: .any).matching(identifier: "narration.speed").firstMatch
    XCTAssertTrue(speed.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    attachScreenshot(app, name: "story-3-reader-immersion")
    // The page counter is PDF-surface-only — Immersion is a continuous scroll and shows
    // reader.immersion.score instead, so the toolbar drops reader.page entirely while it is up.
    // Toggling back to PDF is what actually exercises "the position survived the round trip".
    let pdfOption = app.descendants(matching: .any)
      .matching(identifier: "reader.view.pdf.option").firstMatch
    XCTAssertTrue(pdfOption.waitForExistence(timeout: 5))
    pdfOption.click()
    XCTAssertTrue(page.waitForExistence(timeout: 5))
    XCTAssertEqual(page.value as? String, pageBeforeToggle)
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testFirstPageColdAndHotBudgetOnReferenceMac() throws {
    guard hardwareModel() == "Mac16,12" else {
      throw XCTSkip("NFR4 is approved only on the trusted MacBook Air M4 reference host")
    }
    let corpus = realCorpusPDFs()
    guard corpus.count >= 2 else {
      throw XCTSkip("The real PDF corpus needs at least two documents")
    }
    let first = try stageRealPDF(corpus[0])
    let second = try stageRealPDF(corpus[1])
    defer {
      try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    var cold: [Double] = []
    for _ in 0..<5 {
      let app = application()
      app.launch()
      cold.append(try open(first, in: app))
      app.terminate()
      // NOT a launch race — ruled out by evidence (Story 6.8), not assumption: raising this
      // timeout from 10s to 30s made zero difference to the failure count, and an accessibility
      // snapshot at the exact moment of failure showed the *same* process id across all ten
      // launches in a run, with the previous document still on screen and mid-processing. The
      // process genuinely never exits while extraction/OCR is still running in the background —
      // `open()` only waits for the first-page metric, not full processing. Root cause not yet
      // confirmed (leading hypothesis: the main thread/run loop is busy enough that it never gets
      // to service the Apple-Event-based termination request); see Story 6.8. This wait stays at
      // 30s because it is harmless when the process has already exited, not because it fixes
      // anything.
      XCTAssertEqual(app.wait(for: .notRunning, timeout: 30), true)
    }

    let app = application()
    app.launch()
    var hot: [Double] = []
    for index in 0..<5 {
      hot.append(try open(index.isMultiple(of: 2) ? first : second, in: app))
    }
    print("STORY_1_2_FIRST_PAGE cold=\(cold) hot=\(hot)")
    XCTAssertLessThanOrEqual(percentile95(cold), 2)
    XCTAssertLessThanOrEqual(percentile95(hot), 2)
  }

  @MainActor
  func testLongDocumentLifecycleIterationWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["LECTURA_STRESS_ITERATION"] == "1" else {
      throw XCTSkip("Set LECTURA_STRESS_ITERATION=1")
    }
    guard let path = ProcessInfo.processInfo.environment["LECTURA_STRESS_DOCUMENT"],
      FileManager.default.fileExists(atPath: path)
    else { throw XCTSkip("Set LECTURA_STRESS_DOCUMENT to a real PDF") }
    guard
      let duration = TimeInterval(
        ProcessInfo.processInfo.environment["LECTURA_STRESS_DURATION_SECONDS"] ?? "")
    else { throw XCTSkip("Set LECTURA_STRESS_DURATION_SECONDS") }
    guard let metricsPath = ProcessInfo.processInfo.environment["LECTURA_STRESS_METRICS_PATH"]
    else {
      throw XCTSkip("Set LECTURA_STRESS_METRICS_PATH")
    }
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let pdf = staging.appendingPathComponent("real-corpus.pdf")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: pdf)
    let app = application()
    app.launchEnvironment["LECTURA_STRESS_FAIL_PAGE_INDEX"] = "3"
    app.launch()
    defer { app.terminate() }
    try openDocument(pdf, in: app)
    XCTAssertTrue(app.staticTexts["reader.page"].waitForExistence(timeout: 60))
    dismissTutorialIfShown(in: app)

    XCTAssertTrue(app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 60))
    let renderedUnit = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.immersion.unit.'"))
      .firstMatch
    XCTAssertTrue(renderedUnit.waitForExistence(timeout: 60))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: renderedUnit)
        ], timeout: 5),
      .completed)
    let firstUnitIdentifier = renderedUnit.identifier
    app.typeKey(.rightArrow, modifierFlags: [])
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "identifier != %@", firstUnitIdentifier),
            object: renderedUnit)
        ], timeout: 60),
      .completed)
    var maxUIResponseMs = timed { toggleReadingSurface(in: app) }
    var surfaceSwitches = 1
    Thread.sleep(forTimeInterval: 1)
    let pdfCapture = XCTAttachment(screenshot: app.screenshot())
    pdfCapture.name = "real-corpus-pdf-recovery"
    pdfCapture.lifetime = .keepAlways
    add(pdfCapture)
    let cancel = app.buttons["reader.processing.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    var transitionStarted = ProcessInfo.processInfo.systemUptime
    cancel.click()
    let resume = app.buttons["reader.processing.resume"]
    XCTAssertTrue(resume.waitForExistence(timeout: 10))
    maxUIResponseMs = max(
      maxUIResponseMs,
      (ProcessInfo.processInfo.systemUptime - transitionStarted) * 1_000)
    transitionStarted = ProcessInfo.processInfo.systemUptime
    resume.click()
    XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    maxUIResponseMs = max(
      maxUIResponseMs,
      (ProcessInfo.processInfo.systemUptime - transitionStarted) * 1_000)
    let next = app.buttons["reader.next"]
    XCTAssertTrue(next.waitForExistence(timeout: 5))
    next.click()
    let positionBeforeRetry = app.staticTexts["reader.page"].value as? String
    let retry = app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.processing.retry.'"))
      .firstMatch
    XCTAssertTrue(retry.waitForExistence(timeout: 60))
    transitionStarted = ProcessInfo.processInfo.systemUptime
    retry.click()
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: retry)
        ], timeout: 60) == .completed)
    maxUIResponseMs = max(
      maxUIResponseMs,
      (ProcessInfo.processInfo.systemUptime - transitionStarted) * 1_000)
    maxUIResponseMs = max(maxUIResponseMs, timed { toggleReadingSurface(in: app) })
    surfaceSwitches += 1
    XCTAssertTrue(app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 60))
    // Immersion is a continuous scroll through the book, so its indicator reports progress through
    // the document rather than a page number; the page counter only exists on the PDF surface.
    let score = app.descendants(matching: .any)["reader.immersion.score"].firstMatch
    XCTAssertTrue(score.waitForExistence(timeout: 30))
    let progress = (score.value as? String) ?? ""
    XCTAssertTrue(progress.hasSuffix("%"), "el indicador debe informar progreso: \(progress)")
    XCTAssertNotNil(Int(progress.dropLast()), "progreso ilegible: \(progress)")
    XCTAssertFalse(positionBeforeRetry?.isEmpty ?? true)

    let deadline = Date().addingTimeInterval(duration)
    var forward = true
    var cycle = 0
    while Date() < deadline {
      maxUIResponseMs = max(
        maxUIResponseMs,
        timed { app.typeKey(forward ? .rightArrow : .leftArrow, modifierFlags: []) })
      forward.toggle()
      cycle += 1
      if cycle.isMultiple(of: 12) {
        toggleReadingSurface(in: app)
        surfaceSwitches += 1
        Thread.sleep(forTimeInterval: 1)
        toggleReadingSurface(in: app)
        surfaceSwitches += 1
        XCTAssertTrue(
          app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 60))
      }
      Thread.sleep(forTimeInterval: 5)
    }
    app.activate()
    let immersionCapture = XCTAttachment(screenshot: app.screenshot())
    immersionCapture.name = "real-corpus-immersion-after-navigation"
    immersionCapture.lifetime = .keepAlways
    add(immersionCapture)
    let metrics: [String: Any] = [
      "max_ui_response_ms": maxUIResponseMs,
      "navigation_cycles": cycle,
      "surface_switches": surfaceSwitches,
      "recovery_cycle_completed": true,
    ]
    try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: metricsPath), options: .atomic)
  }

  private func timed(_ action: () -> Void) -> Double {
    let started = ProcessInfo.processInfo.systemUptime
    action()
    return (ProcessInfo.processInfo.systemUptime - started) * 1_000
  }

  @MainActor
  private func toggleReadingSurface(in app: XCUIApplication) {
    let immersion = app.descendants(matching: .any)["reader.immersion"].firstMatch
    if immersion.exists {
      immersion.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    }
    let toggle = app.buttons["reader.view.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertTrue(toggle.isHittable)
    toggle.click()
  }

  /// The first-run tutorial opens automatically once the reader reaches its reading state and, by
  /// design, hides the reading content behind it from the accessibility tree while it is up — the
  /// same reason a real VoiceOver user should not hear both layers at once. Every flow below that
  /// opens a real document has to close it before it can see `reader.*` elements at all.
  @MainActor
  private func dismissTutorialIfShown(in app: XCUIApplication) {
    let skip = app.buttons["tutorial.skip"]
    guard skip.waitForExistence(timeout: 3) else { return }
    skip.click()
  }

  @MainActor
  private func open(_ pdf: URL, in app: XCUIApplication) throws -> Double {
    try openDocument(pdf, in: app)
    XCTAssertTrue(app.staticTexts["reader.page"].waitForExistence(timeout: 60))
    dismissTutorialIfShown(in: app)
    let metric = app.staticTexts["reader.first-page-ms"]
    // Same reasoning as testOpensRealPDFAndNavigatesWithKeyboard: the wait itself must not be
    // bounded by the 2 s budget the assertions below actually enforce.
    XCTAssertTrue(metric.waitForExistence(timeout: 15))
    guard let milliseconds = Double(metric.value as? String ?? "") else {
      XCTFail("Missing first-page metric")
      return .infinity
    }
    return milliseconds / 1_000
  }

  @MainActor
  private func application() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    return app
  }

  @MainActor
  private func openDocument(_ pdf: URL, in app: XCUIApplication) throws {
    // The menu-bar command is available both on a fresh launch and while another document is open;
    // the in-content reader.open button intentionally exists only in the empty state.
    app.activate()
    app.typeKey("o", modifierFlags: .command)
    guard app.dialogs.firstMatch.waitForExistence(timeout: 10) else {
      XCTFail("The native PDF open panel did not appear")
      return
    }
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.firstMatch.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.click()
    location.typeKey("a", modifierFlags: .command)
    location.typeText(pdf.path)
    app.typeKey(.return, modifierFlags: [])
    openButton(in: app).click()
  }

  @MainActor
  private func openButton(in app: XCUIApplication) -> XCUIElement {
    let open = app.dialogs.firstMatch.buttons["OKButton"]
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        ],
        timeout: 60),
      .completed)
    return open
  }

  private func percentile95(_ values: [Double]) -> Double {
    values.sorted()[values.count - 1]
  }

  private func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(decoding: bytes.dropLast().map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private func realCorpusPDFs() -> [URL] {
    let fallback =
      "/Users/jailiivinaibuelvasdiaz/Proyectos/academico/projects/children-of-the-state/02-literature/bibliography/sources"
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["LECTURA_REAL_PDF_CORPUS"] ?? fallback)
    guard
      let files = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    return files.compactMap { $0 as? URL }
      .filter { $0.pathExtension.lowercased() == "pdf" }
      .sorted { $0.path < $1.path }
  }

  private func stageRealPDF(_ source: URL?) throws -> URL {
    guard let source else { throw XCTSkip("The configured real PDF corpus is empty") }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("real-corpus.pdf")
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  private func pageIndex(from value: String?) -> Int {
    Int(value?.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
  }

  private func pageTotal(from value: String?) -> Int {
    let digits = value?.split(separator: "/").last?.filter(\.isNumber) ?? ""
    return Int(digits) ?? 0
  }

  /// Regression cover for the reading experience the owner reported as unusable on a real book:
  /// a blank page surfaced as an unrecoverable error, the toolbar pushed out of the window, no
  /// navigation in Immersion, and Play doing nothing because no voice was preselected.
  @MainActor
  func testRealBookRemainsReadableWithBlankPagesToolbarAndNavigation() throws {
    guard let path = ProcessInfo.processInfo.environment["LECTURA_REAL_BOOK_PDF"],
      FileManager.default.fileExists(atPath: path)
    else { throw XCTSkip("Set LECTURA_REAL_BOOK_PDF to a real multi-hundred-page book") }
    let app = application()
    app.launchEnvironment["LECTURA_MODEL_ROOT"] =
      ProcessInfo.processInfo.environment["LECTURA_MODEL_ROOT"] ?? ""
    app.launch()
    defer { app.terminate() }
    try openDocument(URL(fileURLWithPath: path), in: app)

    let page = app.staticTexts["reader.page"]
    XCTAssertTrue(page.waitForExistence(timeout: 120), "the page indicator must survive opening")
    dismissTutorialIfShown(in: app)

    // A blank page (this book's title verso) must never be reported as a failed page.
    let failureRetry = app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.processing.retry.'"))
      .firstMatch
    Thread.sleep(forTimeInterval: 30)
    XCTAssertFalse(
      failureRetry.exists,
      "a blank page must not surface as an unrecoverable page failure")

    // Reading essentials must stay reachable instead of being pushed out of the window.
    XCTAssertTrue(app.buttons["reader.next"].isHittable, "Page navigation stays reachable")
    XCTAssertTrue(app.buttons["narration.toggle"].isHittable, "Playback stays reachable")
    let overflow = app.descendants(matching: .any).matching(identifier: "reader.more").firstMatch
    XCTAssertTrue(overflow.isHittable, "Secondary actions stay reachable through the menu")

    // Pressing Play with a verified installed voice must actually start narrating instead of
    // silently doing nothing, which is what the owner hit: the voice has to be preselected.
    attachScreenshot(app, name: "real-book-toolbar-before-play")
    app.buttons["narration.toggle"].click()
    let narrationStatus = app.descendants(matching: .any)
      .matching(identifier: "narration.status").firstMatch
    let startedNarrating =
      narrationStatus.waitForExistence(timeout: 30)
      || app.descendants(matching: .any)["voice.sheet"].exists
    XCTAssertTrue(startedNarrating, "Play must produce a visible outcome, never nothing at all")
    XCTAssertFalse(
      app.descendants(matching: .any)["voice.sheet"].exists,
      "an installed voice must be preselected so Play does not dead-end in the voice sheet")
    // Narration must actually reach playback, not merely report that it is preparing: the owner
    // saw "preparing audio" and heard nothing at all.
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(
              format: "label == %@", String(localized: "narration.status.playing")),
            object: narrationStatus)
        ], timeout: 180),
      .completed,
      "narration must reach real playback, not stall at preparing or fail")
    attachScreenshot(app, name: "real-book-after-play")

    // Continuous reading: the voice must carry past this book's blank second page and keep going,
    // moving the reader's page with it, instead of stopping on the first page without text.
    let pageAtPlay = pageIndex(from: page.value as? String)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] _, _ in
              pageIndex(from: page.value as? String) > pageAtPlay
            }, object: nil)
        ], timeout: 300),
      .completed,
      "narration must advance the page on its own, skipping blank pages")
    XCTAssertNotEqual(
      narrationStatus.label, String(localized: "narration.status.finished"),
      "narration must not end on a blank page while the book still has text")
    attachScreenshot(app, name: "real-book-continuous-reading")

    // Immersion drops the page-arrow group entirely (it is a continuous scroll, not a paged
    // surface — see readerToolbarContent) and reports position through reader.immersion.score
    // instead, so navigation here means that indicator existing, not reader.page/reader.next.
    app.descendants(matching: .any).matching(identifier: "reader.view.immersion.option")
      .firstMatch.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 30))
    let immersionScore = app.descendants(matching: .any)["reader.immersion.score"].firstMatch
    XCTAssertTrue(
      immersionScore.waitForExistence(timeout: 10),
      "Immersion must report reading progress")
    attachScreenshot(app, name: "real-book-immersion-with-navigation")
  }

}
