import CoreGraphics
import Foundation

/// Redraws a PDF page's own content into another context, painting its text by glyph identifier
/// instead of by string (Story 6.9).
///
/// A book processed by scanning software such as ClearScan carries no photograph of the scan: the
/// text *is* the ink, vectorised into embedded fonts whose Unicode mapping is broken. Stripping the
/// text would leave the page blank, and turning the page into an image multiplies the file by tens
/// (measured: 3.4 MB to 100-190 MB on the reference book). So the page is reproduced operator by
/// operator, and its glyphs are drawn from the very same embedded font by glyph id — never as a
/// string. A drawing made of glyph ids carries no text for PDFKit to hand back, which is what lets
/// the recognised text be kept on the page without the two layers interleaving character by
/// character (see `OCRTextLayer`).
///
/// The interpreter is deliberately narrow. Every operator it cannot reproduce exactly — soft masks,
/// shadings, patterns, marked content, colour spaces other than the device ones, fonts that are not
/// `Type0`/`Identity-H` with an embedded program — refuses the page instead of guessing at it. A
/// refused page keeps the behaviour it had before this story: it is left untouched.
enum PDFGlyphReplay {
  /// Embedded font programs, shared across the pages of one operation.
  ///
  /// Sharing matters for size, not for speed: Core Graphics embeds one subset per `CGFont` object
  /// it is handed, so drawing 369 pages with a fresh `CGFont` each wrote 16.7 MB where reusing the
  /// same objects wrote 5.3 MB for the same ink.
  final class FontCache {
    fileprivate var programs: [Data: CGFont] = [:]
    public init() {}
  }

  struct Outcome {
    let succeeded: Bool
    /// Why the page was refused, for diagnosis. `nil` when it was reproduced.
    let refusal: String?
    let glyphs: Int
  }

  static func replay(page: CGPDFPage, into context: CGContext, fonts cache: FontCache) -> Outcome {
    guard let dictionary = page.dictionary else {
      return Outcome(succeeded: false, refusal: "page has no dictionary", glyphs: 0)
    }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else {
      return Outcome(succeeded: false, refusal: "page has no resources of its own", glyphs: 0)
    }
    var fonts: CGPDFDictionaryRef?
    CGPDFDictionaryGetDictionary(resources, "Font", &fonts)
    var xobjects: CGPDFDictionaryRef?
    CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects)

    let replay = Replayer(context: context, fonts: fonts, xobjects: xobjects, cache: cache)
    guard let table = CGPDFOperatorTableCreate() else {
      return Outcome(succeeded: false, refusal: "no operator table", glyphs: 0)
    }
    defer { CGPDFOperatorTableRelease(table) }
    install(into: table)
    let stream = CGPDFContentStreamCreateWithPage(page)
    let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(replay).toOpaque())
    CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
    CGPDFContentStreamRelease(stream)
    return Outcome(
      succeeded: replay.refusal == nil, refusal: replay.refusal, glyphs: replay.glyphsDrawn)
  }
}

// MARK: - the interpreter

/// The state a PDF content stream builds up while it is scanned. One instance per page.
final class Replayer {
  struct Font {
    let cgFont: CGFont
    let defaultWidth: Double
    let widths: [Int: Double]
    func width(_ cid: Int) -> Double { widths[cid] ?? defaultWidth }
  }

  /// The text state, which `q`/`Q` save and restore along with the graphics state.
  struct TextState {
    var font: Font?
    var size: CGFloat = 0
    var characterSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var leading: CGFloat = 0
    var rise: CGFloat = 0
    var invisible = false
  }

  let context: CGContext
  private let fontResources: CGPDFDictionaryRef?
  private let xobjectResources: CGPDFDictionaryRef?
  private let cache: PDFGlyphReplay.FontCache
  private var fonts: [String: Font] = [:]
  var text = TextState()
  private var savedText: [TextState] = []
  var textMatrix = CGAffineTransform.identity
  var lineMatrix = CGAffineTransform.identity
  private var pendingClip: CGPathFillRule?
  private(set) var refusal: String?
  private(set) var glyphsDrawn = 0

  init(
    context: CGContext, fonts: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?,
    cache: PDFGlyphReplay.FontCache
  ) {
    self.context = context
    self.fontResources = fonts
    self.xobjectResources = xobjects
    self.cache = cache
  }

  /// Runs `body` unless the page has already been refused. There is no way to stop a
  /// `CGPDFScanner` part way through, so the rest of the stream is simply ignored.
  func active(_ body: (Replayer) -> Void) {
    guard refusal == nil else { return }
    body(self)
  }

  func refuse(_ reason: String) {
    if refusal == nil { refusal = reason }
  }

  func pushState() {
    active {
      $0.savedText.append($0.text)
      $0.context.saveGState()
    }
  }

  func popState() {
    active {
      guard let restored = $0.savedText.popLast() else { return $0.refuse("unbalanced Q") }
      $0.text = restored
      $0.context.restoreGState()
    }
  }

  func setCMYK(_ c: CGFloat, _ m: CGFloat, _ y: CGFloat, _ k: CGFloat, stroke: Bool) {
    guard
      let color = CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [c, m, y, k, 1])
    else { return refuse("CMYK colour") }
    if stroke { context.setStrokeColor(color) } else { context.setFillColor(color) }
  }

  func markClip(_ rule: CGPathFillRule) {
    active { $0.pendingClip = rule }
  }

  /// Paints the current path, then applies a clip the stream asked for with `W`/`W*` — which the
  /// specification defers until after the painting operator.
  func paint(_ mode: CGPathDrawingMode?, close: Bool) {
    active { replayer in
      let context = replayer.context
      if close { context.closePath() }
      let clip = replayer.pendingClip
      let path = clip == nil ? nil : context.path
      if let mode { context.drawPath(using: mode) } else { context.beginPath() }
      if let clip, let path {
        context.addPath(path)
        context.clip(using: clip == .evenOdd ? .evenOdd : .winding)
      }
      replayer.pendingClip = nil
    }
  }

  func nextLine(_ tx: CGFloat, _ ty: CGFloat) {
    lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
    textMatrix = lineMatrix
  }

  func beginText() {
    active {
      $0.textMatrix = .identity
      $0.lineMatrix = .identity
    }
  }

  func setTextMatrix(_ matrix: CGAffineTransform) {
    active {
      $0.textMatrix = matrix
      $0.lineMatrix = matrix
    }
  }

  // MARK: fonts

  func selectFont(_ name: String, size: CGFloat) {
    active { replayer in
      replayer.text.size = size
      if let cached = replayer.fonts[name] {
        replayer.text.font = cached
        return
      }
      guard let resources = replayer.fontResources,
        let font = Replayer.load(name, from: resources, cache: replayer.cache)
      else { return replayer.refuse("font /\(name) is not an embedded Identity-H CID font") }
      replayer.fonts[name] = font
      replayer.text.font = font
    }
  }

  /// Resolves one `/Font` resource, or returns `nil` for anything this story does not reproduce.
  ///
  /// Only `Type0` fonts with `Identity-H` encoding are accepted, because only there is a code in
  /// the content stream the same number as the glyph to draw: two bytes per character, taken as a
  /// CID, and — with an identity `CIDToGIDMap` — the glyph id itself. Simple fonts would need their
  /// `/Encoding` and `/Differences` resolved to glyph names, which is a different story.
  private static func load(
    _ name: String, from resources: CGPDFDictionaryRef, cache: PDFGlyphReplay.FontCache
  ) -> Font? {
    var dictionary: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, name, &dictionary), let dictionary,
      pdfName(of: dictionary, key: "Subtype") == "Type0",
      pdfName(of: dictionary, key: "Encoding") == "Identity-H"
    else { return nil }
    var descendants: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
      CGPDFArrayGetCount(descendants) == 1
    else { return nil }
    var descendant: CGPDFDictionaryRef?
    guard CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return nil }
    guard let kind = pdfName(of: descendant, key: "Subtype"),
      kind == "CIDFontType0" || kind == "CIDFontType2"
    else { return nil }
    // A CID-to-glyph map other than the identity one would have to be read out of a stream.
    if let mapping = pdfName(of: descendant, key: "CIDToGIDMap"), mapping != "Identity" {
      return nil
    }
    var mappingStream: CGPDFStreamRef?
    if CGPDFDictionaryGetStream(descendant, "CIDToGIDMap", &mappingStream) { return nil }

    var descriptor: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(descendant, "FontDescriptor", &descriptor), let descriptor
    else { return nil }
    var program: Data?
    for key in ["FontFile3", "FontFile2", "FontFile"] {
      var stream: CGPDFStreamRef?
      guard CGPDFDictionaryGetStream(descriptor, key, &stream), let stream else { continue }
      var format = CGPDFDataFormat.raw
      program = CGPDFStreamCopyData(stream, &format) as Data?
      break
    }
    guard let program, !program.isEmpty else { return nil }
    let cgFont: CGFont
    if let shared = cache.programs[program] {
      cgFont = shared
    } else {
      guard let provider = CGDataProvider(data: program as CFData), let made = CGFont(provider)
      else { return nil }
      cache.programs[program] = made
      cgFont = made
    }

    var defaultWidth: CGPDFReal = 1000
    if !CGPDFDictionaryGetNumber(descendant, "DW", &defaultWidth) { defaultWidth = 1000 }
    guard let widths = widthTable(of: descendant) else { return nil }
    return Font(cgFont: cgFont, defaultWidth: Double(defaultWidth), widths: widths)
  }

  /// The `/W` array, in either of its two shapes: `c [w w w]` and `first last w`. Advance widths
  /// have to come from here — estimating them would space a whole book wrong.
  private static func widthTable(of descendant: CGPDFDictionaryRef) -> [Int: Double]? {
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(descendant, "W", &array), let array else { return [:] }
    var widths: [Int: Double] = [:]
    var index = 0
    let count = CGPDFArrayGetCount(array)
    while index < count {
      var first: CGPDFInteger = 0
      guard CGPDFArrayGetInteger(array, index, &first), first >= 0 else { return nil }
      index += 1
      guard index < count else { return nil }
      var nested: CGPDFArrayRef?
      if CGPDFArrayGetArray(array, index, &nested), let nested {
        for offset in 0..<CGPDFArrayGetCount(nested) {
          var value: CGPDFReal = 0
          guard CGPDFArrayGetNumber(nested, offset, &value) else { return nil }
          widths[first + offset] = Double(value)
        }
        index += 1
        continue
      }
      var last: CGPDFInteger = 0
      guard CGPDFArrayGetInteger(array, index, &last), last >= first, last - first < 65_536 else {
        return nil
      }
      index += 1
      guard index < count else { return nil }
      var value: CGPDFReal = 0
      guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
      index += 1
      for cid in first...last { widths[cid] = Double(value) }
    }
    return widths
  }

  private static func pdfName(of dictionary: CGPDFDictionaryRef, key: String) -> String? {
    var value: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
    return String(cString: value)
  }

  // MARK: showing text

  func showArray(_ array: CGPDFArrayRef) {
    active { replayer in
      for index in 0..<CGPDFArrayGetCount(array) {
        var string: CGPDFStringRef?
        if CGPDFArrayGetString(array, index, &string), let string {
          replayer.show(Replayer.bytes(of: string))
          continue
        }
        var adjustment: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &adjustment) else {
          return replayer.refuse("TJ element that is neither a string nor a number")
        }
        let shift =
          -CGFloat(adjustment) / 1000 * replayer.text.size * replayer.text.horizontalScale
        replayer.textMatrix = CGAffineTransform(translationX: shift, y: 0)
          .concatenating(replayer.textMatrix)
      }
    }
  }

  /// Draws one string's worth of glyphs and advances the text matrix by exactly what the
  /// specification says the string is wide.
  func show(_ bytes: [UInt8]) {
    guard refusal == nil else { return }
    guard let font = text.font else { return refuse("text shown before any font was selected") }
    guard bytes.count.isMultiple(of: 2) else {
      return refuse("odd number of bytes for a two-byte encoding")
    }

    var glyphs: [CGGlyph] = []
    var positions: [CGPoint] = []
    var advance: CGFloat = 0
    glyphs.reserveCapacity(bytes.count / 2)
    positions.reserveCapacity(bytes.count / 2)
    // Word spacing is tracked but never added: the specification applies it only to the
    // single-byte code 32, and an `Identity-H` string is two bytes per character throughout.
    for index in stride(from: 0, to: bytes.count, by: 2) {
      let cid = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      glyphs.append(CGGlyph(cid))
      positions.append(CGPoint(x: advance, y: 0))
      advance += CGFloat(font.width(cid) / 1000) * text.size + text.characterSpacing
    }

    if !text.invisible, !glyphs.isEmpty {
      context.saveGState()
      // Font size, horizontal scale and rise belong to the coordinate system, never to
      // `context.textMatrix`: `showGlyphs` writes its own text matrix from the context's text
      // position, so anything left in `textMatrix` is dropped (the trap already recorded for
      // `CTLineDraw` in the project's operating notes).
      context.concatenate(
        CGAffineTransform(scaleX: text.horizontalScale, y: 1)
          .concatenating(CGAffineTransform(translationX: 0, y: text.rise))
          .concatenating(textMatrix))
      context.textMatrix = .identity
      context.setFont(font.cgFont)
      context.setFontSize(text.size)
      context.setTextDrawingMode(.fill)
      context.showGlyphs(glyphs, at: positions)
      context.restoreGState()
      glyphsDrawn += glyphs.count
    }

    textMatrix = CGAffineTransform(translationX: advance * text.horizontalScale, y: 0)
      .concatenating(textMatrix)
  }

  static func bytes(of string: CGPDFStringRef) -> [UInt8] {
    let length = CGPDFStringGetLength(string)
    guard length > 0, let pointer = CGPDFStringGetBytePtr(string) else { return [] }
    return Array(UnsafeBufferPointer(start: pointer, count: length))
  }

  // MARK: images

  func drawXObject(_ name: String) {
    active { replayer in
      guard let resources = replayer.xobjectResources else {
        return replayer.refuse("XObject used with no XObject resources")
      }
      var stream: CGPDFStreamRef?
      guard CGPDFDictionaryGetStream(resources, name, &stream), let stream else {
        return replayer.refuse("XObject /\(name) is missing")
      }
      guard let dictionary = CGPDFStreamGetDictionary(stream),
        Replayer.pdfName(of: dictionary, key: "Subtype") == "Image"
      else { return replayer.refuse("XObject /\(name) is not an image") }
      guard let image = Replayer.image(from: stream, dictionary: dictionary) else {
        return replayer.refuse("image /\(name) uses an encoding this story does not reproduce")
      }
      // An image is painted into the unit square of the current transform. `CGContext.draw` already
      // puts the image's first row at the top of that square, which is where PDF wants it: adding
      // the usual flip turns the page upside down (measured on a scanned fixture: a third of the
      // pixels differed, and zero once the flip was removed).
      replayer.context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
  }

  /// Only the plainly decodable images: no soft mask, no stencil mask, no `/Decode`, no colour
  /// space that needs resolving. Anything else refuses the page rather than paint an approximation.
  private static func image(from stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) -> CGImage?
  {
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format) as Data?, !data.isEmpty else {
      return nil
    }
    if format == .jpegEncoded {
      guard let provider = CGDataProvider(data: data as CFData) else { return nil }
      return CGImage(
        jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    }
    if format == .JPEG2000 { return nil }

    var width: CGPDFInteger = 0
    var height: CGPDFInteger = 0
    var bits: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
      CGPDFDictionaryGetInteger(dictionary, "Height", &height),
      CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits),
      width > 0, height > 0, bits == 1 || bits == 8
    else { return nil }
    var stencil: CGPDFBoolean = 0
    if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &stencil), stencil == 1 { return nil }
    var softMask: CGPDFStreamRef?
    if CGPDFDictionaryGetStream(dictionary, "SMask", &softMask) { return nil }
    var decode: CGPDFArrayRef?
    if CGPDFDictionaryGetArray(dictionary, "Decode", &decode) { return nil }
    guard let space = pdfName(of: dictionary, key: "ColorSpace") else { return nil }
    let components: Int
    let colorSpace: CGColorSpace
    switch space {
    case "DeviceGray", "G", "CalGray":
      components = 1
      colorSpace = CGColorSpaceCreateDeviceGray()
    case "DeviceRGB", "RGB", "CalRGB":
      components = 3
      colorSpace = CGColorSpaceCreateDeviceRGB()
    case "DeviceCMYK", "CMYK":
      components = 4
      colorSpace = CGColorSpaceCreateDeviceCMYK()
    default: return nil
    }
    let bitsPerPixel = bits * components
    let bytesPerRow = (width * bitsPerPixel + 7) / 8
    guard data.count >= bytesPerRow * height, let provider = CGDataProvider(data: data as CFData)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bitsPerPixel,
      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

// MARK: - operator table

/// The replayer behind a scanner's `info` pointer. It outlives every callback: `replay` holds it
/// for the whole scan.
private func replayer(_ info: UnsafeMutableRawPointer?) -> Replayer {
  Unmanaged<Replayer>.fromOpaque(info!).takeUnretainedValue()
}

private func number(_ scanner: CGPDFScannerRef) -> CGFloat? {
  var value: CGPDFReal = 0
  return CGPDFScannerPopNumber(scanner, &value) ? CGFloat(value) : nil
}

/// The six numbers of a matrix operand, which pop in reverse order like every other operand.
private func matrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
  guard let f = number(scanner), let e = number(scanner), let d = number(scanner),
    let c = number(scanner), let b = number(scanner), let a = number(scanner)
  else { return nil }
  return CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
}

private func string(_ scanner: CGPDFScannerRef) -> [UInt8]? {
  var value: CGPDFStringRef?
  guard CGPDFScannerPopString(scanner, &value), let value else { return nil }
  return Replayer.bytes(of: value)
}

private func array(_ scanner: CGPDFScannerRef) -> CGPDFArrayRef? {
  var value: CGPDFArrayRef?
  guard CGPDFScannerPopArray(scanner, &value) else { return nil }
  return value
}

private func numbers(_ scanner: CGPDFScannerRef) -> [CGFloat]? {
  guard let value = array(scanner) else { return nil }
  var values: [CGFloat] = []
  for index in 0..<CGPDFArrayGetCount(value) {
    var element: CGPDFReal = 0
    guard CGPDFArrayGetNumber(value, index, &element) else { return nil }
    values.append(CGFloat(element))
  }
  return values
}

private func popName(_ scanner: CGPDFScannerRef) -> String? {
  var value: UnsafePointer<Int8>?
  guard CGPDFScannerPopName(scanner, &value), let value else { return nil }
  return String(cString: value)
}

extension PDFGlyphReplay {
  fileprivate static func install(into table: CGPDFOperatorTableRef) {
    func on(
      _ name: String,
      _ callback: @escaping @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void
    ) {
      CGPDFOperatorTableSetCallback(table, name, callback)
    }

    // Graphics state.
    on("q") { _, info in replayer(info).pushState() }
    on("Q") { _, info in replayer(info).popState() }
    on("cm") { scanner, info in
      guard let value = matrix(scanner) else { return replayer(info).refuse("cm operands") }
      replayer(info).active { $0.context.concatenate(value) }
    }
    on("w") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("w operand") }
      replayer(info).active { $0.context.setLineWidth(value) }
    }
    on("J") { scanner, info in
      guard let value = number(scanner), let cap = CGLineCap(rawValue: Int32(value)) else {
        return replayer(info).refuse("J operand")
      }
      replayer(info).active { $0.context.setLineCap(cap) }
    }
    on("j") { scanner, info in
      guard let value = number(scanner), let join = CGLineJoin(rawValue: Int32(value)) else {
        return replayer(info).refuse("j operand")
      }
      replayer(info).active { $0.context.setLineJoin(join) }
    }
    on("M") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("M operand") }
      replayer(info).active { $0.context.setMiterLimit(value) }
    }
    on("d") { scanner, info in
      guard let phase = number(scanner), let lengths = numbers(scanner) else {
        return replayer(info).refuse("d operands")
      }
      replayer(info).active { $0.context.setLineDash(phase: phase, lengths: lengths) }
    }
    // Flatness and rendering intent change no ink this comparison can see.
    on("i") { scanner, _ in _ = number(scanner) }
    on("ri") { scanner, _ in _ = popName(scanner) }

    // Device colour. Anything that needs a colour space resolved refuses the page below.
    on("g") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("g operand") }
      replayer(info).active { $0.context.setFillColor(gray: value, alpha: 1) }
    }
    on("G") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("G operand") }
      replayer(info).active { $0.context.setStrokeColor(gray: value, alpha: 1) }
    }
    on("rg") { scanner, info in
      guard let blue = number(scanner), let green = number(scanner), let red = number(scanner)
      else { return replayer(info).refuse("rg operands") }
      replayer(info).active {
        $0.context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
      }
    }
    on("RG") { scanner, info in
      guard let blue = number(scanner), let green = number(scanner), let red = number(scanner)
      else { return replayer(info).refuse("RG operands") }
      replayer(info).active {
        $0.context.setStrokeColor(red: red, green: green, blue: blue, alpha: 1)
      }
    }
    on("k") { scanner, info in
      guard let black = number(scanner), let yellow = number(scanner),
        let magenta = number(scanner), let cyan = number(scanner)
      else { return replayer(info).refuse("k operands") }
      replayer(info).active { $0.setCMYK(cyan, magenta, yellow, black, stroke: false) }
    }
    on("K") { scanner, info in
      guard let black = number(scanner), let yellow = number(scanner),
        let magenta = number(scanner), let cyan = number(scanner)
      else { return replayer(info).refuse("K operands") }
      replayer(info).active { $0.setCMYK(cyan, magenta, yellow, black, stroke: true) }
    }

    // Path construction.
    on("m") { scanner, info in
      guard let y = number(scanner), let x = number(scanner) else {
        return replayer(info).refuse("m operands")
      }
      replayer(info).active { $0.context.move(to: CGPoint(x: x, y: y)) }
    }
    on("l") { scanner, info in
      guard let y = number(scanner), let x = number(scanner) else {
        return replayer(info).refuse("l operands")
      }
      replayer(info).active { $0.context.addLine(to: CGPoint(x: x, y: y)) }
    }
    on("c") { scanner, info in
      guard let y3 = number(scanner), let x3 = number(scanner), let y2 = number(scanner),
        let x2 = number(scanner), let y1 = number(scanner), let x1 = number(scanner)
      else { return replayer(info).refuse("c operands") }
      replayer(info).active {
        $0.context.addCurve(
          to: CGPoint(x: x3, y: y3), control1: CGPoint(x: x1, y: y1),
          control2: CGPoint(x: x2, y: y2))
      }
    }
    on("v") { scanner, info in
      guard let y3 = number(scanner), let x3 = number(scanner), let y2 = number(scanner),
        let x2 = number(scanner)
      else { return replayer(info).refuse("v operands") }
      replayer(info).active {
        let start = $0.context.path?.currentPoint ?? .zero
        $0.context.addCurve(
          to: CGPoint(x: x3, y: y3), control1: start, control2: CGPoint(x: x2, y: y2))
      }
    }
    on("y") { scanner, info in
      guard let y3 = number(scanner), let x3 = number(scanner), let y1 = number(scanner),
        let x1 = number(scanner)
      else { return replayer(info).refuse("y operands") }
      replayer(info).active {
        $0.context.addCurve(
          to: CGPoint(x: x3, y: y3), control1: CGPoint(x: x1, y: y1),
          control2: CGPoint(x: x3, y: y3))
      }
    }
    on("h") { _, info in replayer(info).active { $0.context.closePath() } }
    on("re") { scanner, info in
      guard let height = number(scanner), let width = number(scanner), let y = number(scanner),
        let x = number(scanner)
      else { return replayer(info).refuse("re operands") }
      replayer(info).active {
        $0.context.addRect(CGRect(x: x, y: y, width: width, height: height))
      }
    }

    // Path painting and clipping.
    on("S") { _, info in replayer(info).paint(.stroke, close: false) }
    on("s") { _, info in replayer(info).paint(.stroke, close: true) }
    on("f") { _, info in replayer(info).paint(.fill, close: false) }
    on("F") { _, info in replayer(info).paint(.fill, close: false) }
    on("f*") { _, info in replayer(info).paint(.eoFill, close: false) }
    on("B") { _, info in replayer(info).paint(.fillStroke, close: false) }
    on("B*") { _, info in replayer(info).paint(.eoFillStroke, close: false) }
    on("b") { _, info in replayer(info).paint(.fillStroke, close: true) }
    on("b*") { _, info in replayer(info).paint(.eoFillStroke, close: true) }
    on("n") { _, info in replayer(info).paint(nil, close: false) }
    on("W") { _, info in replayer(info).markClip(.winding) }
    on("W*") { _, info in replayer(info).markClip(.evenOdd) }

    // Text.
    on("BT") { _, info in replayer(info).beginText() }
    on("ET") { _, _ in }
    on("Tf") { scanner, info in
      guard let size = number(scanner), let name = popName(scanner) else {
        return replayer(info).refuse("Tf operands")
      }
      replayer(info).selectFont(name, size: size)
    }
    on("Td") { scanner, info in
      guard let ty = number(scanner), let tx = number(scanner) else {
        return replayer(info).refuse("Td operands")
      }
      replayer(info).active { $0.nextLine(tx, ty) }
    }
    on("TD") { scanner, info in
      guard let ty = number(scanner), let tx = number(scanner) else {
        return replayer(info).refuse("TD operands")
      }
      replayer(info).active {
        $0.text.leading = -ty
        $0.nextLine(tx, ty)
      }
    }
    on("Tm") { scanner, info in
      guard let value = matrix(scanner) else { return replayer(info).refuse("Tm operands") }
      replayer(info).setTextMatrix(value)
    }
    on("T*") { _, info in replayer(info).active { $0.nextLine(0, -$0.text.leading) } }
    on("TL") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("TL operand") }
      replayer(info).active { $0.text.leading = value }
    }
    on("Tc") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("Tc operand") }
      replayer(info).active { $0.text.characterSpacing = value }
    }
    on("Tw") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("Tw operand") }
      replayer(info).active { $0.text.wordSpacing = value }
    }
    on("Tz") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("Tz operand") }
      replayer(info).active { $0.text.horizontalScale = value / 100 }
    }
    on("Ts") { scanner, info in
      guard let value = number(scanner) else { return replayer(info).refuse("Ts operand") }
      replayer(info).active { $0.text.rise = value }
    }
    on("Tr") { scanner, info in
      // Filled text and invisible text are the two modes a scanned page uses. Stroked and
      // clipping modes would need the text turned into a path to come out identical.
      guard let value = number(scanner), value == 0 || value == 3 else {
        return replayer(info).refuse("text rendering mode other than fill or invisible")
      }
      replayer(info).active { $0.text.invisible = value == 3 }
    }
    on("Tj") { scanner, info in
      guard let bytes = string(scanner) else { return replayer(info).refuse("Tj operand") }
      replayer(info).active { $0.show(bytes) }
    }
    on("TJ") { scanner, info in
      guard let value = array(scanner) else { return replayer(info).refuse("TJ operand") }
      replayer(info).showArray(value)
    }
    on("'") { scanner, info in
      guard let bytes = string(scanner) else { return replayer(info).refuse("' operand") }
      replayer(info).active {
        $0.nextLine(0, -$0.text.leading)
        $0.show(bytes)
      }
    }
    on("\"") { scanner, info in
      guard let bytes = string(scanner), let spacing = number(scanner), let word = number(scanner)
      else { return replayer(info).refuse("\" operands") }
      replayer(info).active {
        $0.text.wordSpacing = word
        $0.text.characterSpacing = spacing
        $0.nextLine(0, -$0.text.leading)
        $0.show(bytes)
      }
    }

    on("Do") { scanner, info in
      guard let name = popName(scanner) else { return replayer(info).refuse("Do operand") }
      replayer(info).drawXObject(name)
    }

    // Registered only so the page is refused rather than silently drawn wrong. A `CGPDFOperatorTable`
    // has no default callback, so an operator left out here would be skipped in silence — which is
    // exactly the failure this story must not have.
    for name in [
      "gs", "sh", "BI", "ID", "EI", "d0", "d1", "cs", "CS", "sc", "SC", "scn", "SCN",
      "BDC", "BMC", "EMC", "DP", "MP", "BX", "EX",
    ] {
      on(name) { _, info in replayer(info).refuse("operator this story does not reproduce") }
    }
  }
}
