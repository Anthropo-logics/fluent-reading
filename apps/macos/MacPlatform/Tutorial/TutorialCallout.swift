import CoreGraphics

/// The real control a tutorial step points at (Story 6.5). Replaces the symbolic directions the
/// first version of the tutorial used ("toward the leading edge of the toolbar"), which described a
/// region of the window instead of a control.
///
/// Reading controls live in the window's **native** toolbar, so their frames are known to AppKit
/// and not to SwiftUI. Both kinds of target — native toolbar items and in-content views — publish
/// their frame in window coordinates, which is the one coordinate space both worlds agree on.
public enum TutorialAnchorTarget: String, CaseIterable, Sendable {
  /// The PDF / Immersion switch in the toolbar.
  case viewSwitcher
  /// Play, pause and unit navigation in the toolbar.
  case transport
  /// The ⋯ overflow menu that holds translation, export and voice preparation.
  case moreMenu
  /// The reading surface itself (the PDF page or the immersion column).
  case readingArea
}

/// Where a step's callout goes, expressed in the overlay's own coordinates (top-left origin, y
/// growing downwards, like SwiftUI) so the view layer can use it without further conversion.
public struct TutorialCalloutPlacement: Equatable, Sendable {
  /// Which edge of the card carries the pointer, and where along that edge it sits (measured from
  /// the card's leading edge, so the view can offset it without knowing the card's position).
  public enum Tip: Equatable, Sendable {
    /// Pointer on the card's top edge: the target is above the card.
    case above(CGFloat)
    /// Pointer on the card's bottom edge: the target is below the card.
    case below(CGFloat)
    /// No pointer — either there is no target, or the card had to be laid over one too large to
    /// stand beside (the highlight carries the meaning in that case).
    case none
  }

  public let cardFrame: CGRect
  public let tip: Tip
  /// The target itself, for drawing a highlight around it. `nil` when the target lies outside the
  /// overlay — a toolbar item, for instance, which is painted by AppKit above the content area.
  public let highlight: CGRect?

  public init(cardFrame: CGRect, tip: Tip, highlight: CGRect?) {
    self.cardFrame = cardFrame
    self.tip = tip
    self.highlight = highlight
  }
}

/// Geometry of the tutorial callouts. Pure arithmetic on rectangles, deliberately free of AppKit
/// and SwiftUI: it is the part where AC5 (never clipped by the window, never covering the control
/// it points at) is actually decided, and this way it can be checked without a running window.
public enum TutorialCallout {
  /// Distance between the card and the control it points at. Large enough for the pointer to read
  /// as a pointer, small enough that the pair still reads as one thing.
  public static let gap: CGFloat = 14
  /// Minimum distance between the card and the edges of the overlay.
  public static let margin: CGFloat = 16
  /// How close to a corner the pointer may get before it stops tracking the target. Measured in a
  /// 720-point window against the ⋯ menu, the far-right control: any more and the pointer stops
  /// short of the button it is supposed to be pointing at once the card is clamped by the margin.
  public static let tipInset: CGFloat = 18

  /// Converts an AppKit window rectangle (origin at the bottom-left, y growing upwards) into the
  /// overlay's coordinates (origin at its own top-left, y growing downwards).
  ///
  /// A toolbar item sits above the content area, so it legitimately converts to a **negative** y:
  /// the target is off the top of the overlay, and the card ends up pinned under it.
  public static func overlayRect(windowRect: CGRect, overlayWindowRect: CGRect) -> CGRect {
    CGRect(
      x: windowRect.minX - overlayWindowRect.minX,
      y: overlayWindowRect.maxY - windowRect.maxY,
      width: windowRect.width,
      height: windowRect.height)
  }

  /// Places the card next to `target`, or centred when there is no target (the welcome and closing
  /// steps, which describe the tutorial itself rather than a control).
  ///
  /// The card is placed below the target when it fits, above when it does not, and over it only
  /// when the target is too large for either — the reading surface, which fills the window. The
  /// returned frame is always inside the overlay, and its size is capped to what the overlay can
  /// hold, so a card grown by scaled system text stays reachable instead of hanging off the edge.
  public static func placement(
    target: CGRect?,
    cardSize: CGSize,
    overlaySize: CGSize
  ) -> TutorialCalloutPlacement {
    let width = min(cardSize.width, max(0, overlaySize.width - 2 * margin))
    let height = min(cardSize.height, max(0, overlaySize.height - 2 * margin))
    let maxX = max(margin, overlaySize.width - width - margin)
    let maxY = max(margin, overlaySize.height - height - margin)

    guard let target else {
      let centred = CGRect(
        x: clamp((overlaySize.width - width) / 2, margin, maxX),
        y: clamp((overlaySize.height - height) / 2, margin, maxY),
        width: width, height: height)
      return TutorialCalloutPlacement(cardFrame: centred, tip: .none, highlight: nil)
    }

    let centredX = clamp(target.midX - width / 2, margin, maxX)
    let tipX = clamp(target.midX - centredX, tipInset, max(tipInset, width - tipInset))
    let below = max(target.maxY + gap, margin)
    let above = min(target.minY - gap - height, maxY)

    let x: CGFloat
    let y: CGFloat
    let tip: TutorialCalloutPlacement.Tip
    if below <= maxY {
      x = centredX
      y = below
      tip = .above(tipX)
    } else if above >= margin {
      x = centredX
      y = above
      tip = .below(tipX)
    } else {
      // No room over or under: stand beside the target if either side has room, and only lie over
      // it when nothing else fits — the reading surface, which is the whole window.
      y = clamp(target.midY - height / 2, margin, maxY)
      let beside = target.maxX + gap
      let besideLeading = target.minX - gap - width
      x = beside <= maxX ? beside : (besideLeading >= margin ? besideLeading : centredX)
      tip = .none
    }

    let overlayBounds = CGRect(origin: .zero, size: overlaySize)
    let visible = target.intersection(overlayBounds)
    return TutorialCalloutPlacement(
      cardFrame: CGRect(x: x, y: y, width: width, height: height),
      tip: tip,
      highlight: visible.isNull || visible.isEmpty ? nil : target)
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), max(lower, upper))
  }
}
