import CoreGraphics
import Darwin
import XCTest

final class ReaderWindowUITests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    let intentionallyLong =
      name.contains("testFirstPageColdAndHotBudgetOnReferenceMac")
      || name.contains("testOpensRealPDFAndNavigatesWithKeyboard")
      || name.contains("testEpic7TranslationKeepsOneAnchorAcrossPDFAndImmersion")
      || name.contains("testPageRecoveryActionsAreContextualAcrossPDFAndImmersion")
    if name.contains("testLongDocumentLifecycleIterationWhenRequested") {
      let duration =
        TimeInterval(
          ProcessInfo.processInfo.environment["LECTURA_STRESS_DURATION_SECONDS"] ?? "") ?? 0
      executionTimeAllowance = max(600, duration + 600)
    } else if name.contains("testEpic7TranslationKeepsOneAnchorAcrossPDFAndImmersion")
      || name.contains("testPageRecoveryActionsAreContextualAcrossPDFAndImmersion")
    {
      executionTimeAllowance = 600
    } else if intentionallyLong {
      // XCTest arms its UI execution timer before entering the test method. These flows retain ten
      // measured opens and the complete reader lifecycle, so their allowance must be set here.
      executionTimeAllowance = 300
    }
  }

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
  func testReadingMenuDisablesActionsThatHaveNoCurrentTarget() throws {
    let app = application()
    app.launchArguments += ["-AppleLanguages", "(en)"]
    app.launch()
    defer { app.terminate() }

    let readingMenu = app.menuBars.menuBarItems["Reading"]
    XCTAssertTrue(readingMenu.waitForExistence(timeout: 5))
    readingMenu.click()
    for title in ["Voice…", "Translate…", "Export audio…", "Storage…"] {
      let item = app.menuItems[title]
      XCTAssertTrue(item.waitForExistence(timeout: 2), "Missing Reading menu item: \(title)")
      XCTAssertFalse(item.isEnabled, "\(title) must be disabled before a document is open")
    }
    XCTAssertFalse(app.menuItems["Text"].exists, "Text versions stay hidden before translation")
    app.typeKey(.escape, modifierFlags: [])

    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = repository.appendingPathComponent("tests/corpus/documents/es-single-digital.pdf")
    let pdf = try stageRealPDF(source)
    defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
    try openDocument(pdf, in: app)
    XCTAssertTrue(app.staticTexts["reader.page"].waitForExistence(timeout: 30))
    app.descendants(matching: .any)["reader.view.immersion.option"].click()
    XCTAssertTrue(
      app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 5))

    readingMenu.click()
    let resumeFollowing = app.menuItems["Resume automatic following"]
    XCTAssertTrue(resumeFollowing.waitForExistence(timeout: 2))
    XCTAssertFalse(
      resumeFollowing.isEnabled,
      "Resume automatic following must stay disabled while following is already active")
    XCTAssertFalse(app.menuItems["Text"].exists, "Opening a document must not reveal text versions")
  }

  @MainActor
  func testOpensRealPDFAndNavigatesWithKeyboard() throws {
    let staging = try stageRealPDF(realCorpusPDFs().first)
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
    let pdf = staging
    let app = application()
    app.launch()
    defer { app.terminate() }
    try openDocument(pdf, in: app)

    let page = app.staticTexts["reader.page"]
    XCTAssertTrue(page.waitForExistence(timeout: 60))
    attachScreenshot(app, name: "story-3-reader-pdf")
    // The element itself only exists once the metric is computed, so waiting for it must not be
    // bounded by the 2 s NFR4 budget that metric is measuring — a genuine budget overrun would
    // then surface as a confusing "element not found" instead of a clear assertion on the value.
    XCTAssertTrue(app.staticTexts["reader.first-page-ms"].waitForExistence(timeout: 15))
    let visibleTextVersion = app.descendants(matching: .any)
      .matching(identifier: "translation.text.version").firstMatch
    XCTAssertFalse(
      visibleTextVersion.exists,
      "the Original/Translation control stays hidden until translation begins")
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
    XCTAssertFalse(
      visibleTextVersion.exists,
      "changing surfaces must not reveal translation controls before translation begins")
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
  func testEpic7TranslationKeepsOneAnchorAcrossPDFAndImmersion() throws {
    guard let pdfPath = ProcessInfo.processInfo.environment["LECTURA_EPIC7_PDF"],
      FileManager.default.fileExists(atPath: pdfPath),
      let modelRoot = ProcessInfo.processInfo.environment["LECTURA_MODEL_ROOT"],
      FileManager.default.fileExists(atPath: modelRoot)
    else { throw XCTSkip("Set LECTURA_EPIC7_PDF and LECTURA_MODEL_ROOT") }

    let pdf = try stageRealPDF(URL(fileURLWithPath: pdfPath))
    defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
    let app = application()
    // The environment override has no security scope. Pointing it at a removable volume can block
    // app startup behind a TCC prompt before the window exists, so exercise the same native folder
    // grant a reader uses instead.
    app.launchEnvironment["LECTURA_MODEL_ROOT"] = ""
    app.launch()
    defer {
      let cancel = app.buttons["translation.progress.cancel"]
      if cancel.exists { cancel.click() }
      app.terminate()
    }
    try openDocument(pdf, in: app)
    let page = app.staticTexts["reader.page"]
    XCTAssertTrue(page.waitForExistence(timeout: 120))
    let startingPage = page.value as? String

    let more = app.popUpButtons["reader.more"]
    XCTAssertTrue(more.waitForExistence(timeout: 10))
    more.click()
    let translate = app.descendants(matching: .any)["translation.action"]
    XCTAssertTrue(translate.waitForExistence(timeout: 5))
    translate.click()
    chooseDirectory(modelRoot, from: app.buttons["translation.storage.choose"], in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["translation.installed"].waitForExistence(timeout: 60))
    let target = app.popUpButtons["translation.target"]
    target.click()
    let english = app.menuItems["English"]
    XCTAssertTrue(english.waitForExistence(timeout: 5))
    english.click()
    app.buttons["translation.request.start"].click()
    app.buttons["translation.close"].click()

    let translatedVersion = app.descendants(matching: .any)["translation.text.translation"]
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: translatedVersion)
        ], timeout: 300),
      .completed)
    translatedVersion.click()

    let translatedPDF = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.pdf.translation.'"))
      .firstMatch
    XCTAssertTrue(translatedPDF.waitForExistence(timeout: 60))
    let translatedID = translatedPDF.identifier
    let unitID = String(translatedID.dropFirst("reader.pdf.translation.".count))
    attachScreenshot(app, name: "epic-7-pdf-translation")

    let originalVersion = app.descendants(matching: .any)["translation.text.original"]
    originalVersion.click()
    XCTAssertFalse(translatedPDF.waitForExistence(timeout: 2))
    XCTAssertEqual(page.value as? String, startingPage)
    translatedVersion.click()
    XCTAssertTrue(app.descendants(matching: .any)[translatedID].waitForExistence(timeout: 10))

    translatedPDF.doubleClick()
    let narrationStatus = app.descendants(matching: .any)["narration.status"]
    XCTAssertTrue(narrationStatus.waitForExistence(timeout: 30))
    XCTAssertEqual(narrationStatus.value as? String, "Translation")

    originalVersion.click()
    XCTAssertTrue(
      narrationStatus.exists, "changing visible text must not stop translated narration")
    translatedVersion.click()
    let immersion = app.descendants(matching: .any)["reader.view.immersion.option"]
    immersion.click()
    let translatedImmersion = app.descendants(matching: .any)["reader.immersion.unit.\(unitID)"]
    XCTAssertTrue(translatedImmersion.waitForExistence(timeout: 30))
    translatedImmersion.doubleClick()
    XCTAssertTrue(narrationStatus.waitForExistence(timeout: 30))
    attachScreenshot(app, name: "epic-7-immersion-translation")

    app.descendants(matching: .any)["reader.view.pdf.option"].click()
    XCTAssertTrue(page.waitForExistence(timeout: 10))
    XCTAssertEqual(page.value as? String, startingPage)
    XCTAssertTrue(app.descendants(matching: .any)[translatedID].waitForExistence(timeout: 10))
  }

  @MainActor
  func testPageRecoveryActionsAreContextualAcrossPDFAndImmersion() throws {
    guard let path = ProcessInfo.processInfo.environment["LECTURA_OCR_RECOVERY_PDF"],
      FileManager.default.fileExists(atPath: path)
    else { throw XCTSkip("Set LECTURA_OCR_RECOVERY_PDF to a PDF with degraded digital text") }

    let pdf = try stageRealPDF(URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
    let source = try Data(contentsOf: pdf)

    try exercisePageRecovery("retry", onPDFSurface: true, pdf: pdf)
    try exercisePageRecovery("skip", onPDFSurface: false, pdf: pdf)
    try exercisePageRecovery("force_ocr", onPDFSurface: false, pdf: pdf)

    XCTAssertEqual(try Data(contentsOf: pdf), source, "recovery must not modify the source PDF")
  }

  @MainActor
  private func exercisePageRecovery(
    _ action: String,
    onPDFSurface: Bool,
    pdf: URL
  ) throws {
    let app = application()
    app.launchEnvironment["LECTURA_STRESS_FAIL_PAGE_INDEX"] = "0"
    app.launch()
    defer {
      let cancel = app.buttons["reader.processing.cancel"]
      if cancel.exists {
        cancel.click()
        _ = app.buttons["reader.processing.resume"].waitForExistence(timeout: 10)
      }
      app.terminate()
    }
    try openDocument(pdf, in: app)

    XCTAssertTrue(
      app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 120))
    if onPDFSurface {
      let pdfSurface = app.descendants(matching: .any)["reader.view.pdf.option"]
      XCTAssertTrue(pdfSurface.waitForExistence(timeout: 10))
      pdfSurface.click()
    }

    let page = app.staticTexts["reader.page"]
    let pageBefore =
      onPDFSurface && page.waitForExistence(timeout: 10)
      ? page.value as? String : nil
    let retry = app.buttons["reader.processing.retry.0"]
    let skip = app.buttons["reader.processing.skip.0"]
    let forceOCR = app.buttons["reader.processing.force_ocr.0"]
    guard retry.waitForExistence(timeout: 120) else {
      XCTFail("a failed page must offer Retry")
      return
    }
    guard skip.waitForExistence(timeout: 5) else {
      XCTFail("a failed page must offer Skip page")
      return
    }
    guard forceOCR.waitForExistence(timeout: 5) else {
      XCTFail("a failed page must offer Force OCR")
      return
    }
    for control in [retry, skip, forceOCR] {
      XCTAssertTrue(control.isHittable)
      XCTAssertFalse(control.label.isEmpty)
      XCTAssertEqual(control.value as? String, "1")
    }
    XCTAssertTrue(app.buttons["narration.toggle"].isEnabled)
    XCTAssertFalse(app.descendants(matching: .any)["translation.text.version"].exists)

    let selected = app.buttons["reader.processing.\(action).0"]
    if action == "retry" {
      app.typeKey("t", modifierFlags: [.command, .shift])
    } else {
      selected.click()
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: selected)
        ], timeout: 120),
      .completed)

    if action == "skip" {
      let details = app.descendants(matching: .any)["reader.processing.details"]
      XCTAssertTrue(details.waitForExistence(timeout: 10))
      details.click()
      XCTAssertTrue(
        app.descendants(matching: .any)["reader.processing.page.0.skipped"]
          .waitForExistence(timeout: 10))
      app.typeKey(.escape, modifierFlags: [])
    }
    if action == "force_ocr" {
      let expected = ProcessInfo.processInfo.environment["LECTURA_OCR_RECOVERY_EXPECTED_TEXT"] ?? ""
      let predicate =
        expected.isEmpty
        ? NSPredicate(format: "identifier BEGINSWITH 'reader.immersion.unit.'")
        : NSPredicate(
          format: "identifier BEGINSWITH 'reader.immersion.unit.' AND label CONTAINS[cd] %@",
          expected)
      XCTAssertTrue(
        app.descendants(matching: .any).matching(predicate).firstMatch
          .waitForExistence(timeout: 120))
    }

    XCTAssertTrue(app.buttons["narration.toggle"].isEnabled)
    XCTAssertFalse(app.descendants(matching: .any)["translation.text.version"].exists)
    if onPDFSurface { XCTAssertEqual(page.value as? String, pageBefore) }
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
    guard
      ProcessInfo.processInfo.environment["LECTURA_FIRST_PAGE_PERFORMANCE_TEST"] == "1"
    else {
      throw XCTSkip(
        "Set LECTURA_FIRST_PAGE_PERFORMANCE_TEST=1 for the real first-page performance gate")
    }
    guard hardwareModel() == "Mac16,12" else {
      throw XCTSkip("NFR4 is approved only on the trusted MacBook Air M4 reference host")
    }
    guard
      let corpusRoot = ProcessInfo.processInfo.environment["LECTURA_REAL_PDF_CORPUS"],
      !corpusRoot.isEmpty
    else {
      XCTFail("Set LECTURA_REAL_PDF_CORPUS to a directory containing at least two PDFs")
      return
    }
    let corpus = realCorpusPDFs(at: corpusRoot)
    guard corpus.count >= 2 else {
      XCTFail("LECTURA_REAL_PDF_CORPUS must contain at least two PDFs")
      return
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
    guard ProcessInfo.processInfo.environment["LECTURA_STRESS_METRICS_PATH"] != nil else {
      throw XCTSkip("Set LECTURA_STRESS_METRICS_PATH")
    }
    guard let modelRoot = ProcessInfo.processInfo.environment["LECTURA_STRESS_MODEL_ROOT"],
      FileManager.default.fileExists(atPath: modelRoot)
    else { throw XCTSkip("Set LECTURA_STRESS_MODEL_ROOT") }
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let pdf = staging.appendingPathComponent("real-corpus.pdf")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: pdf)
    let app = application()
    app.launchEnvironment["LECTURA_STRESS_FAIL_PAGE_INDEX"] = "3"
    app.launchEnvironment["LECTURA_MODEL_ROOT"] = ""
    app.launch()
    defer { app.terminate() }
    try openDocument(pdf, in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 60))

    let renderedUnit = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.immersion.unit.'"))
      .firstMatch
    guard renderedUnit.waitForExistence(timeout: 60) else {
      XCTFail("the long document produced no visible reading unit")
      return
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: renderedUnit)
        ], timeout: 5),
      .completed)
    let nextUnit = app.buttons["narration.next"]
    XCTAssertTrue(nextUnit.waitForExistence(timeout: 5))
    nextUnit.click()
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
    XCTAssertEqual(app.staticTexts["reader.page"].value as? String, positionBeforeRetry)
    maxUIResponseMs = max(maxUIResponseMs, timed { toggleReadingSurface(in: app) })
    surfaceSwitches += 1
    XCTAssertTrue(app.descendants(matching: .any)["reader.immersion"].waitForExistence(timeout: 60))
    XCTAssertFalse(positionBeforeRetry?.isEmpty ?? true)
    let translationAnchor = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.immersion.unit.'"))
      .firstMatch
    guard translationAnchor.waitForExistence(timeout: 60) else {
      XCTFail("recovery left no visible reading anchor")
      return
    }
    translationAnchor.click()

    let more = app.popUpButtons["reader.more"]
    XCTAssertTrue(more.waitForExistence(timeout: 10))
    more.click()
    let translate = app.descendants(matching: .any)["translation.action"]
    XCTAssertTrue(translate.waitForExistence(timeout: 5))
    translate.click()
    chooseDirectory(modelRoot, from: app.buttons["translation.storage.choose"], in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["translation.installed"].waitForExistence(timeout: 60))
    let target = app.popUpButtons["translation.target"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    target.click()
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    let startTranslation = app.buttons["translation.request.start"]
    XCTAssertTrue(startTranslation.isEnabled)
    startTranslation.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["translation.requested"].waitForExistence(timeout: 10))
    app.buttons["translation.close"].click()
    let translationRunning = app.descendants(matching: .any)["translation.progress.running"]
    let translationFailed = app.descendants(matching: .any)["translation.progress.failed"]
    XCTAssertTrue(
      translationRunning.waitForExistence(timeout: 15) || translationFailed.exists,
      "translation must start or report a failure")
    guard !translationFailed.exists else {
      XCTFail("translation runtime failed before producing text")
      return
    }
    let translatedVersion = app.descendants(matching: .any)["translation.text.translation"]
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: translatedVersion)
        ], timeout: 300),
      .completed)
    translatedVersion.click()
    let translatedUnit = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.immersion.unit.'"))
      .firstMatch
    guard translatedUnit.waitForExistence(timeout: 60) else {
      XCTFail("translation removed the visible reading unit")
      return
    }
    more.click()
    let voice = app.descendants(matching: .any)["voice.action"]
    XCTAssertTrue(voice.waitForExistence(timeout: 5))
    voice.click()
    guard app.descendants(matching: .any)["voice.installed"].waitForExistence(timeout: 60) else {
      XCTFail("the installed narration model was not ready")
      return
    }
    app.buttons["voice.close"].click()
    translatedUnit.click()
    more.click()
    let translatedNarration = app.descendants(matching: .any)["narration.source.translation"]
    XCTAssertTrue(translatedNarration.waitForExistence(timeout: 5))
    translatedNarration.click()
    app.buttons["narration.toggle"].click()
    let narrationStatus = app.descendants(matching: .any)["narration.status"]
    guard
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(
              format: "label == 'Reading aloud' AND value == 'Translation'"),
            object: narrationStatus)
        ], timeout: 180) == .completed
    else {
      XCTFail("translated narration did not reach playback")
      return
    }

    let deadline = Date().addingTimeInterval(duration)
    var forward = true
    var cycle = 0
    var narrationSourceSwitches = 0
    var pauseResumeCycles = 0
    while Date() < deadline {
      XCTAssertFalse(
        translationFailed.exists,
        "automatic translation continuation must not turn normal completion into a failure")
      maxUIResponseMs = max(
        maxUIResponseMs,
        timed { app.buttons[forward ? "narration.next" : "narration.previous"].click() })
      forward.toggle()
      cycle += 1
      if cycle.isMultiple(of: 3) {
        app.scrollViews["reader.immersion"].scroll(byDeltaX: 0, deltaY: -120)
      }
      if cycle.isMultiple(of: 4) {
        app.buttons["narration.toggle"].click()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["narration.toggle"].click()
        pauseResumeCycles += 1
      }
      if cycle.isMultiple(of: 6) {
        more.click()
        let source = app.descendants(matching: .any)[
          narrationSourceSwitches.isMultiple(of: 2)
            ? "narration.source.original" : "narration.source.translation"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        narrationSourceSwitches += 1
      }
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
    XCTAssertFalse(
      translationFailed.exists,
      "translation must remain healthy after sustained navigation and surface changes")
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
      "translated_units_played": 1,
      "narration_source_switches": narrationSourceSwitches,
      "pause_resume_cycles": pauseResumeCycles,
    ]
    let metricsAttachment = XCTAttachment(
      data: try JSONSerialization.data(
        withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]),
      uniformTypeIdentifier: "public.json")
    metricsAttachment.name = "reader-stress-metrics.json"
    metricsAttachment.lifetime = .keepAlways
    add(metricsAttachment)
  }

  private func timed(_ action: () -> Void) -> Double {
    let started = ProcessInfo.processInfo.systemUptime
    action()
    return (ProcessInfo.processInfo.systemUptime - started) * 1_000
  }

  @MainActor
  private func toggleReadingSurface(in app: XCUIApplication) {
    let target = app.descendants(matching: .any)[
      app.descendants(matching: .any)["reader.immersion"].exists
        ? "reader.view.pdf.option" : "reader.view.immersion.option"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertTrue(target.isHittable)
    target.click()
  }

  /// The first-run tutorial opens automatically once the reader reaches its reading state and, by
  /// design, hides the reading content behind it from the accessibility tree while it is up — the
  /// same reason a real VoiceOver user should not hear both layers at once. Every real-document
  /// flow routes through `openDocument`, which closes it before the test reads `reader.*` content.
  @MainActor
  private func dismissTutorialIfShown(in app: XCUIApplication) {
    let viewSwitcher = app.descendants(matching: .any)["reader.view"]
    guard viewSwitcher.waitForExistence(timeout: 60) else {
      XCTFail("The reader did not reach its reading state")
      return
    }
    let skip = app.buttons["tutorial.skip"]
    guard skip.waitForExistence(timeout: 3) else { return }
    skip.click()
  }

  @MainActor
  private func open(_ pdf: URL, in app: XCUIApplication) throws -> Double {
    try openDocument(pdf, in: app)
    XCTAssertTrue(app.staticTexts["reader.page"].waitForExistence(timeout: 60))
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
    dismissTutorialIfShown(in: app)
  }

  @MainActor
  private func chooseDirectory(_ path: String, from button: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.click()
    XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 10))
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.textFields["PathTextField"]
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.click()
    location.typeKey("a", modifierFlags: .command)
    location.typeText(path)
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

  private func realCorpusPDFs(at rootPath: String? = nil) -> [URL] {
    guard
      let rootPath = rootPath ?? ProcessInfo.processInfo.environment["LECTURA_REAL_PDF_CORPUS"],
      !rootPath.isEmpty
    else { return [] }
    let root = URL(fileURLWithPath: rootPath)
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
