import AppKit
import MacPlatform
import SwiftUI

struct TutorialStep: Identifiable {
  let id: Int
  let titleKey: String
  let bodyKey: String
  /// The control this step is about. `nil` for the steps that describe the tutorial itself, which
  /// have nothing to point at and stay centred.
  let target: TutorialAnchorTarget?
  /// AC7: a step is skipped rather than shown against the wrong surface — Inmersión-only or
  /// PDF-only controls never appear while the other surface is active.
  let requiresSurface: ReadingSurface?
}

let tutorialSteps: [TutorialStep] = [
  TutorialStep(
    id: 0, titleKey: "tutorial.welcome.title", bodyKey: "tutorial.welcome.body", target: nil,
    requiresSurface: nil),
  TutorialStep(
    id: 1, titleKey: "tutorial.views.title", bodyKey: "tutorial.views.body",
    target: .viewSwitcher, requiresSurface: nil),
  TutorialStep(
    id: 2, titleKey: "tutorial.start_reading.pdf.title",
    bodyKey: "tutorial.start_reading.pdf.body", target: .readingArea, requiresSurface: .pdf),
  TutorialStep(
    id: 3, titleKey: "tutorial.start_reading.immersion.title",
    bodyKey: "tutorial.start_reading.immersion.body", target: .readingArea,
    requiresSurface: .immersion),
  TutorialStep(
    id: 4, titleKey: "tutorial.transport.title", bodyKey: "tutorial.transport.body",
    target: .transport, requiresSurface: nil),
  // Story 6.10: a reader opening the app for the first time has no voice installed, so the step
  // right after playback is the download itself — announced before it happens, and pointing at the
  // ⋯ menu, which is where the voice is prepared and where its language is chosen.
  TutorialStep(
    id: 5, titleKey: "tutorial.voice.title", bodyKey: "tutorial.voice.body", target: .moreMenu,
    requiresSurface: nil),
  TutorialStep(
    id: 6, titleKey: "tutorial.translate.title", bodyKey: "tutorial.translate.body",
    target: .moreMenu, requiresSurface: nil),
  TutorialStep(
    id: 7, titleKey: "tutorial.export.title", bodyKey: "tutorial.export.body", target: .moreMenu,
    requiresSurface: nil),
  TutorialStep(
    id: 8, titleKey: "tutorial.finish.title", bodyKey: "tutorial.finish.body", target: nil,
    requiresSurface: nil),
]

/// One published frame: either a control a step points at, or the overlay itself, which is the
/// frame every other one is measured against.
enum TutorialAnchorSlot: Hashable {
  case control(TutorialAnchorTarget)
  case overlay
}

/// Frames of the controls the tutorial points at, in **window** coordinates (Story 6.5).
///
/// The reading controls are items of the window's native `NSToolbar`, so SwiftUI's own anchor
/// preferences cannot see them — they are not in its view tree. Window coordinates are the space
/// both worlds share: every anchored control publishes its frame here through a probe view, and
/// the overlay converts them into its own space to place a card.
@MainActor
@Observable
final class TutorialAnchorRegistry {
  private var frames: [TutorialAnchorSlot: CGRect] = [:]

  func frame(_ slot: TutorialAnchorSlot) -> CGRect? { frames[slot] }

  func update(_ slot: TutorialAnchorSlot, frame: CGRect?) {
    if let frame {
      frames[slot] = frame
    } else {
      frames.removeValue(forKey: slot)
    }
  }

  /// Sub-point differences are layout noise, not movement. Reporting them would republish a frame
  /// on every layout pass for no visible gain.
  func matches(_ slot: TutorialAnchorSlot, _ frame: CGRect?) -> Bool {
    switch (frames[slot], frame) {
    case (nil, nil): true
    case (let stored?, let candidate?):
      abs(stored.minX - candidate.minX) < 0.5 && abs(stored.minY - candidate.minY) < 0.5
        && abs(stored.width - candidate.width) < 0.5
        && abs(stored.height - candidate.height) < 0.5
    default: false
    }
  }
}

/// Publishes the frame of whatever it is attached to, in window coordinates.
///
/// Attached with `.background(...)` it takes the exact frame of the control in front of it, native
/// toolbar item included: AppKit converts through the real view hierarchy, so it stays correct
/// while the window is resized and while the toolbar rearranges its items.
struct TutorialAnchorProbe: NSViewRepresentable {
  let slot: TutorialAnchorSlot
  let registry: TutorialAnchorRegistry

  func makeNSView(context: Context) -> TutorialAnchorProbeView {
    let view = TutorialAnchorProbeView()
    view.configure(slot: slot, registry: registry)
    return view
  }

  func updateNSView(_ nsView: TutorialAnchorProbeView, context: Context) {
    nsView.configure(slot: slot, registry: registry)
  }
}

final class TutorialAnchorProbeView: NSView {
  private var slot: TutorialAnchorSlot?
  private weak var registry: TutorialAnchorRegistry?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // Invisible in every sense that matters: it must not take clicks away from the control it is
    // measuring, and VoiceOver must not find one more element in the toolbar (AC6).
    postsFrameChangedNotifications = true
    setAccessibilityElement(false)
    NotificationCenter.default.addObserver(
      self, selector: #selector(report), name: NSView.frameDidChangeNotification, object: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(slot: TutorialAnchorSlot, registry: TutorialAnchorRegistry) {
    self.slot = slot
    self.registry = registry
    report()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeWindow()
    report()
  }

  override func layout() {
    super.layout()
    report()
  }

  override func viewDidHide() {
    super.viewDidHide()
    report()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    report()
  }

  private func observeWindow() {
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didResizeNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
    guard let window else { return }
    // A toolbar item moves when the window is resized without its own frame changing relative to
    // its superview, so `frameDidChange` alone would miss it.
    for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(report), name: name, object: window)
    }
  }

  /// A control that is not in a window, or is hidden, has no position to point at: it publishes
  /// nothing, and the step that names it falls back to a centred card instead of pointing at an
  /// empty spot (AC7).
  @objc private func report() {
    guard let slot, let registry else { return }
    let frame: CGRect? =
      (window == nil || isHiddenOrHasHiddenAncestor) ? nil : convert(bounds, to: nil)
    guard !registry.matches(slot, frame) else { return }
    // Publishing straight from `layout()` would mutate observed state in the middle of a SwiftUI
    // update pass; one hop puts it in the next one.
    Task { @MainActor in registry.update(slot, frame: frame) }
  }
}

/// Interactive first-use tutorial (Story 5.10), anchored to the real controls (Story 6.5). Purely
/// presentational: it never touches narration, translation or document state (AC6) — only reads
/// the reader's current `readingSurface`, so a step can show against the surface it describes.
struct TutorialOverlay: View {
  let surface: ReadingSurface
  let anchors: TutorialAnchorRegistry
  @Binding var stepIndex: Int
  @Binding var dontShowAgain: Bool
  let onFinish: () -> Void
  /// Return/arrow keys only reach a button that actually holds keyboard focus. A fresh overlay
  /// starts with none, so without claiming it explicitly the first press of Return went to whatever
  /// the window's toolbar had focused before the tutorial appeared, not to "Siguiente" (AC6).
  @FocusState private var primaryButtonFocused: Bool
  /// Natural height of the card's content at `cardWidth`, measured as it is drawn: scaled system
  /// text makes it grow, and the placement has to know before it can keep it inside the window.
  @State private var cardHeight: CGFloat = 320
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let cardWidth: CGFloat = 360
  private static let tipSize = CGSize(width: 24, height: 12)

  private var visibleSteps: [TutorialStep] {
    tutorialSteps.filter { $0.requiresSurface == nil || $0.requiresSurface == surface }
  }

  private var step: TutorialStep? {
    let steps = visibleSteps
    guard steps.indices.contains(stepIndex) else { return steps.last }
    return steps[stepIndex]
  }

  var body: some View {
    if let step {
      GeometryReader { proxy in
        let placement = placement(for: step, overlaySize: proxy.size)
        ZStack(alignment: .topLeading) {
          if let highlight = placement.highlight { highlightRing(highlight) }
          callout(for: step, placement: placement)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // AC3: the card travels to the next control instead of blinking from one place to another,
        // which is what makes it read as one card moving through the interface.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: placement.cardFrame)
      }
      .background {
        Color.black.opacity(0.25)
          .ignoresSafeArea()
          .onTapGesture {}  // absorbs clicks so the tutorial never triggers reading controls (AC6)
      }
      .background(TutorialAnchorProbe(slot: .overlay, registry: anchors))
      .accessibilityIdentifier("tutorial.overlay")
      .transition(.opacity)
      .onAppear {
        announce(step)
        primaryButtonFocused = true
      }
      .onChange(of: stepIndex) { _, _ in
        if let current = self.step { announce(current) }
        primaryButtonFocused = true
      }
    }
  }

  /// AC1/AC3/AC4: the card is placed against the live frame of the control the step describes, so
  /// it follows the control between steps, across window resizes and across toolbar rearrangements.
  private func placement(for step: TutorialStep, overlaySize: CGSize)
    -> TutorialCalloutPlacement
  {
    TutorialCallout.placement(
      target: targetRect(for: step),
      cardSize: CGSize(width: Self.cardWidth, height: cardHeight),
      overlaySize: overlaySize)
  }

  private func targetRect(for step: TutorialStep) -> CGRect? {
    guard let target = step.target,
      let control = anchors.frame(.control(target)),
      let overlay = anchors.frame(.overlay)
    else { return nil }
    return TutorialCallout.overlayRect(windowRect: control, overlayWindowRect: overlay)
  }

  private func announce(_ step: TutorialStep) {
    AccessibilityNotification.Announcement(
      String(localized: String.LocalizationValue(step.titleKey))
    )
    .post()
  }

  /// AC2, for controls inside the reading area: the target is outlined where it is. Toolbar items
  /// are painted by AppKit above this overlay, so those are pointed at by the card's tip instead.
  private func highlightRing(_ rect: CGRect) -> some View {
    RoundedRectangle(cornerRadius: 10)
      .strokeBorder(Color.accentColor, lineWidth: 3)
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func callout(for step: TutorialStep, placement: TutorialCalloutPlacement) -> some View {
    let content =
      card(for: step)
      .frame(width: placement.cardFrame.width)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        cardHeight = $0
      }
    // Only a card grown past the window — scaled system text in a small window — gets a scroll
    // view. Wrapping it always would hand the arrow keys to the scroller instead of to "Anterior".
    return Group {
      if cardHeight > placement.cardFrame.height {
        ScrollView(.vertical) { content }.scrollBounceBehavior(.basedOnSize)
      } else {
        content
      }
    }
    .frame(width: placement.cardFrame.width, height: placement.cardFrame.height)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(alignment: .topLeading) { tip(placement.tip, pointingUp: true) }
    .overlay(alignment: .bottomLeading) { tip(placement.tip, pointingUp: false) }
    .shadow(radius: 16)
    .offset(x: placement.cardFrame.minX, y: placement.cardFrame.minY)
  }

  /// AC2: a short pointer on the edge of the card facing the control, aligned with its centre —
  /// not a generic arrow toward a region of the window.
  @ViewBuilder
  private func tip(_ tip: TutorialCalloutPlacement.Tip, pointingUp: Bool) -> some View {
    let offset: CGFloat? =
      switch tip {
      case .above(let x): pointingUp ? x : nil
      case .below(let x): pointingUp ? nil : x
      case .none: nil
      }
    if let offset {
      TutorialTipShape()
        .fill(.regularMaterial)
        .frame(width: Self.tipSize.width, height: Self.tipSize.height)
        .rotationEffect(.degrees(pointingUp ? 0 : 180))
        .offset(
          x: offset - Self.tipSize.width / 2,
          y: pointingUp ? -Self.tipSize.height + 1 : Self.tipSize.height - 1
        )
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func card(for step: TutorialStep) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(LocalizedStringKey(step.titleKey))
        .font(.title3.weight(.semibold))
      Text(LocalizedStringKey(step.bodyKey))
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(
        String(
          format: String(localized: "tutorial.step_count"), stepIndex + 1, visibleSteps.count)
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
      Divider()
      Toggle("tutorial.dont_show_again", isOn: $dontShowAgain)
        .accessibilityIdentifier("tutorial.dont_show_again")
      HStack {
        Button("tutorial.skip") { onFinish() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("tutorial.skip")
        Spacer()
        if stepIndex > 0 {
          Button("tutorial.previous") { stepIndex -= 1 }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityIdentifier("tutorial.previous")
        }
        if stepIndex + 1 < visibleSteps.count {
          Button("tutorial.next") { stepIndex += 1 }
            .keyboardShortcut(.defaultAction)
            .focused($primaryButtonFocused)
            .accessibilityIdentifier("tutorial.next")
        } else {
          Button("tutorial.done") { onFinish() }
            .keyboardShortcut(.defaultAction)
            .focused($primaryButtonFocused)
            .accessibilityIdentifier("tutorial.done")
        }
      }
    }
    .padding(20)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tutorial.card")
  }
}

/// The pointer on the edge of a card: a triangle whose apex is at the top of its own frame, so it
/// points at whatever the card was placed under.
private struct TutorialTipShape: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}
