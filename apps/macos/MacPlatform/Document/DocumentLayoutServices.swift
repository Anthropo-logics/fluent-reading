import AppKit
import CoreGraphics
import CoreML
import Foundation
import PDFKit

public enum LayoutRole: String, Codable, Equatable, Sendable {
  case abstract, algorithm
  case asideText = "aside_text"
  case chart, content, formula
  case documentTitle = "doc_title"
  case figureTitle = "figure_title"
  case footer, footnote
  case formulaNumber = "formula_number"
  case header, image, number
  case paragraphTitle = "paragraph_title"
  case reference
  case referenceContent = "reference_content"
  case seal, table, text
  case visionFootnote = "vision_footnote"
  case unknown
}

public enum NarrationDisposition: String, Codable, Equatable, Sendable {
  case automatic
  case onDemand = "on_demand"
  case never
}

public struct DocumentLayoutRegion: Equatable, Sendable {
  public let role: LayoutRole
  public let disposition: NarrationDisposition
  public let confidence: Double
  public let rectPDFPoints: [Double]
  public let order: UInt32
  public let physicalPageIndex: UInt8

  public init(
    role: LayoutRole, disposition: NarrationDisposition, confidence: Double,
    rectPDFPoints: [Double], order: UInt32, physicalPageIndex: UInt8
  ) {
    self.role = role
    self.disposition = disposition
    self.confidence = confidence
    self.rectPDFPoints = rectPDFPoints
    self.order = order
    self.physicalPageIndex = physicalPageIndex
  }
}

public struct DocumentLayoutResult: Equatable, Sendable {
  public let regions: [DocumentLayoutRegion]
  public let physicalPageCount: UInt8
  public let status: String
  public let elapsedMilliseconds: UInt64
  public let processorRevision: String

  public init(
    regions: [DocumentLayoutRegion], physicalPageCount: UInt8, status: String,
    elapsedMilliseconds: UInt64, processorRevision: String
  ) {
    self.regions = regions
    self.physicalPageCount = physicalPageCount
    self.status = status
    self.elapsedMilliseconds = elapsedMilliseconds
    self.processorRevision = processorRevision
  }
}

public enum DocumentLayoutAlignment {
  private struct Candidate {
    let region: DocumentLayoutRegion
    let coverage: Double
  }

  public static func enrich(
    _ blocks: [DigitalTextBlock], with layout: DocumentLayoutResult
  ) -> [DigitalTextBlock] {
    guard layout.status == "completed" else { return blocks }
    let nonEmptyCount = blocks.count {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard nonEmptyCount > 0 else { return blocks }

    let matched = blocks.enumerated().map { index, block in
      (index, block, match(block, in: layout.regions))
    }
    let alignedCount = matched.count { value in
      !value.1.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.2 != nil
    }
    guard Double(alignedCount) / Double(nonEmptyCount) >= 0.60 else { return blocks }

    return
      matched
      .map { index, block, region in
        let physicalPageIndex = region?.physicalPageIndex ?? spreadPage(for: block, layout: layout)
        let enriched =
          region.map {
            DigitalTextBlock(
              blockID: block.blockID, text: block.text, spokenText: block.spokenText,
              region: block.region, confidence: block.confidence, layoutRole: $0.role,
              layoutConfidence: $0.confidence, layoutOrder: $0.order,
              narrationDisposition: $0.disposition, physicalPageIndex: $0.physicalPageIndex)
          }
          ?? physicalPageIndex.map {
            DigitalTextBlock(
              blockID: block.blockID, text: block.text, spokenText: block.spokenText,
              region: block.region, confidence: block.confidence, layoutRole: block.layoutRole,
              layoutConfidence: block.layoutConfidence, layoutOrder: block.layoutOrder,
              narrationDisposition: block.narrationDisposition, physicalPageIndex: $0)
          } ?? block
        return (
          index,
          enriched,
          physicalPageIndex
        )
      }
      .sorted {
        let leftPage = $0.2 ?? UInt8.max
        let rightPage = $1.2 ?? UInt8.max
        if leftPage != rightPage { return leftPage < rightPage }
        let leftOrder = $0.1.layoutOrder ?? UInt32.max
        let rightOrder = $1.1.layoutOrder ?? UInt32.max
        return leftOrder == rightOrder ? $0.0 < $1.0 : leftOrder < rightOrder
      }
      .map(\.1)
  }

  private static func match(
    _ block: DigitalTextBlock, in regions: [DocumentLayoutRegion]
  ) -> DocumentLayoutRegion? {
    guard let blockRect = rect(block.region.rectPDFPoints), blockRect.width > 0,
      blockRect.height > 0
    else { return nil }
    let area = Double(blockRect.width * blockRect.height)
    var candidates: [Candidate] = []
    for region in regions {
      guard region.role != .image, region.confidence >= 0.30,
        let regionRect = rect(region.rectPDFPoints)
      else {
        continue
      }
      let intersection = blockRect.intersection(regionRect)
      let coverage =
        intersection.isNull ? 0 : Double(intersection.width * intersection.height) / area
      if coverage >= 0.60 { candidates.append(Candidate(region: region, coverage: coverage)) }
    }
    candidates.sort {
      $0.coverage == $1.coverage
        ? $0.region.confidence > $1.region.confidence : $0.coverage > $1.coverage
    }
    guard let best = candidates.first else { return nil }
    for candidate in candidates.dropFirst() {
      if candidate.region.role != best.region.role
        && abs(candidate.coverage - best.coverage) <= 0.02
        && abs(candidate.region.confidence - best.region.confidence) <= 0.02
      {
        return nil
      }
    }
    return best.region
  }

  private static func spreadPage(
    for block: DigitalTextBlock, layout: DocumentLayoutResult
  ) -> UInt8? {
    guard layout.physicalPageCount == 2, let blockRect = rect(block.region.rectPDFPoints) else {
      return nil
    }
    var pageBounds: [UInt8: CGRect] = [:]
    for region in layout.regions {
      guard let regionRect = rect(region.rectPDFPoints) else { continue }
      pageBounds[region.physicalPageIndex] =
        pageBounds[region.physicalPageIndex]?.union(regionRect) ?? regionRect
    }
    guard pageBounds[0] != nil, pageBounds[1] != nil else { return nil }
    let point = CGPoint(x: blockRect.midX, y: blockRect.midY)
    return pageBounds.min {
      let leftDistance = squaredDistance(from: point, to: $0.value)
      let rightDistance = squaredDistance(from: point, to: $1.value)
      return leftDistance == rightDistance ? $0.key < $1.key : leftDistance < rightDistance
    }?.key
  }

  private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
    let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
    return dx * dx + dy * dy
  }

  private static func rect(_ points: [Double]) -> CGRect? {
    guard points.count == 4, points.allSatisfy(\.isFinite), points[2] > 0, points[3] > 0 else {
      return nil
    }
    return CGRect(x: points[0], y: points[1], width: points[2], height: points[3])
  }
}

public enum DocumentLayoutPostprocessor {
  private static let roles: [LayoutRole] = [
    .abstract, .algorithm, .asideText, .chart, .content, .formula, .documentTitle, .figureTitle,
    .footer, .footer, .footnote, .formulaNumber, .header, .header, .image, .formula, .number,
    .paragraphTitle, .reference, .referenceContent, .seal, .table, .text, .text, .visionFootnote,
  ]

  public static func decode(
    classLogits: MLMultiArray, boxes: MLMultiArray, orderLogits: MLMultiArray, pageBounds: CGRect,
    pageRotationDegrees: Int, physicalPageIndex: UInt8, orderOffset: UInt32,
    regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
  ) -> [DocumentLayoutRegion] {
    guard pageBounds.width.isFinite, pageBounds.height.isFinite, pageBounds.width > 0,
      pageBounds.height > 0, isFinite(classLogits), isFinite(boxes), isFinite(orderLogits),
      let classShape = shape(of: classLogits), let boxShape = shape(of: boxes),
      let orderShape = shape(of: orderLogits), classShape.0 == boxShape.0,
      classShape.0 == orderShape.0, boxShape.1 == 4, orderShape.1 == classShape.0
    else { return [] }

    let (queryCount, classCount) = classShape
    guard classCount > 0, queryCount > 0 else { return [] }
    var votes = Array(repeating: 0.0, count: queryCount)
    for earlier in 0..<queryCount {
      for later in (earlier + 1)..<queryCount {
        let score = sigmoid(value(orderLogits, [0, earlier, later]))
        votes[later] += score
        votes[earlier] += 1 - score
      }
    }
    let ranks = Dictionary(
      uniqueKeysWithValues: votes.enumerated().sorted {
        $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element
      }.enumerated().map { ($0.element.offset, $0.offset) })
    var pairs: [(score: Double, flatIndex: Int)] = []
    pairs.reserveCapacity(queryCount * classCount)
    for flatIndex in 0..<(queryCount * classCount) {
      let query = flatIndex / classCount
      let label = flatIndex % classCount
      pairs.append((sigmoid(value(classLogits, [0, query, label])), flatIndex))
    }
    let highestPairs = pairs.sorted {
      $0.score == $1.score ? $0.flatIndex < $1.flatIndex : $0.score > $1.score
    }.prefix(300)

    let regions = highestPairs.compactMap { pair -> DocumentLayoutRegion? in
      guard pair.score >= 0.3 else { return nil }
      let query = pair.flatIndex / classCount
      let label = pair.flatIndex % classCount
      let role = label < roles.count ? roles[label] : .unknown
      let centerX = value(boxes, [0, query, 0])
      let centerY = value(boxes, [0, query, 1])
      let width = value(boxes, [0, query, 2])
      let height = value(boxes, [0, query, 3])
      let observation = CGRect(
        x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
      let normalized = fullImageRect(observation, within: regionOfInterest)
      let rect = pageSpaceRect(normalized, pageBounds: pageBounds, rotation: pageRotationDegrees)
      guard let rank = ranks[query] else { return nil }
      return DocumentLayoutRegion(
        role: role, disposition: disposition(for: role), confidence: pair.score,
        rectPDFPoints: [
          Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height),
        ],
        order: orderOffset + UInt32(rank), physicalPageIndex: physicalPageIndex)
    }
    return regions.sorted { $0.order < $1.order }
  }

  static func fullImageRect(_ observation: CGRect, within regionOfInterest: CGRect) -> CGRect {
    CGRect(
      x: regionOfInterest.minX + observation.minX * regionOfInterest.width,
      y: regionOfInterest.minY + observation.minY * regionOfInterest.height,
      width: observation.width * regionOfInterest.width,
      height: observation.height * regionOfInterest.height)
  }

  public static func isPhysicalSpread(
    _ regions: [DocumentLayoutRegion], pageBounds: CGRect, pageRotationDegrees: Int = 0
  ) -> Bool {
    let turn = ((pageRotationDegrees % 360) + 360) % 360
    let quarterTurned = turn % 180 != 0
    let displayWidth = quarterTurned ? pageBounds.height : pageBounds.width
    let displayHeight = quarterTurned ? pageBounds.width : pageBounds.height
    guard displayWidth / displayHeight >= 1.15 else { return false }
    let gutter = displayWidth * 0.04
    let middle = displayWidth / 2
    let projected = regions.map {
      ($0, displayRect(of: $0, pageBounds: pageBounds, rotation: turn))
    }
    let readable = projected.filter {
      $0.0.confidence >= 0.3 && $0.0.disposition == .automatic && $0.1.width > 0
    }
    let leftReadable = readable.contains { $0.1.maxX < middle - gutter }
    let rightReadable = readable.contains { $0.1.minX > middle + gutter }
    guard leftReadable, rightReadable else { return false }
    guard
      !readable.contains(where: {
        $0.1.minX < middle + gutter && $0.1.maxX > middle - gutter
      })
    else { return false }
    let folios = projected.filter {
      ($0.0.role == .number || $0.0.role == .footer) && $0.0.confidence >= 0.3
        && $0.1.midY <= displayHeight * 0.2
    }
    return folios.contains { $0.1.midX < middle - gutter }
      && folios.contains { $0.1.midX > middle + gutter }
  }

  private static func shape(of array: MLMultiArray) -> (Int, Int)? {
    let shape = array.shape.map(\.intValue)
    guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] > 0 else { return nil }
    return (shape[1], shape[2])
  }

  private static func isFinite(_ array: MLMultiArray) -> Bool {
    (0..<array.count).allSatisfy { array[$0].doubleValue.isFinite }
  }

  private static func value(_ array: MLMultiArray, _ index: [Int]) -> Double {
    array[index.map(NSNumber.init(value:))].doubleValue
  }

  private static func sigmoid(_ value: Double) -> Double {
    1 / (1 + exp(-min(80, max(-80, value))))
  }

  private static func disposition(for role: LayoutRole) -> NarrationDisposition {
    switch role {
    case .header, .footer, .footnote, .visionFootnote, .number, .formulaNumber, .seal:
      return .never
    case .algorithm, .chart, .formula, .image, .reference, .referenceContent, .table:
      return .onDemand
    default:
      return .automatic
    }
  }

  private static func rect(of region: DocumentLayoutRegion) -> CGRect {
    guard region.rectPDFPoints.count == 4 else { return .zero }
    return CGRect(
      x: region.rectPDFPoints[0], y: region.rectPDFPoints[1], width: region.rectPDFPoints[2],
      height: region.rectPDFPoints[3])
  }

  private static func displayRect(
    of region: DocumentLayoutRegion, pageBounds: CGRect, rotation: Int
  ) -> CGRect {
    let source = rect(of: region)
    switch rotation {
    case 90:
      return CGRect(
        x: source.minY - pageBounds.minY, y: pageBounds.maxX - source.maxX,
        width: source.height, height: source.width)
    case 180:
      return CGRect(
        x: pageBounds.maxX - source.maxX, y: pageBounds.maxY - source.maxY,
        width: source.width, height: source.height)
    case 270:
      return CGRect(
        x: pageBounds.maxY - source.maxY, y: source.minX - pageBounds.minX,
        width: source.height, height: source.width)
    default:
      return CGRect(
        x: source.minX - pageBounds.minX, y: source.minY - pageBounds.minY,
        width: source.width, height: source.height)
    }
  }

  private static func pageSpaceRect(_ normalized: CGRect, pageBounds: CGRect, rotation: Int)
    -> CGRect
  {
    let turn = ((rotation % 360) + 360) % 360
    let quarterTurned = turn % 180 != 0
    let displayWidth = quarterTurned ? pageBounds.height : pageBounds.width
    let displayHeight = quarterTurned ? pageBounds.width : pageBounds.height
    let x = normalized.minX * displayWidth
    let y = normalized.minY * displayHeight
    let width = normalized.width * displayWidth
    let height = normalized.height * displayHeight
    // PP-DocLayoutV3 reports image-space boxes from the top-left. PDFKit uses PDF-space points
    // from the bottom-left, so each quarter turn needs its own top-origin projection.
    switch turn {
    case 90:
      return CGRect(
        x: pageBounds.minX + y, y: pageBounds.minY + x, width: height,
        height: width)
    case 180:
      return CGRect(
        x: pageBounds.maxX - (x + width), y: pageBounds.minY + y, width: width,
        height: height)
    case 270:
      return CGRect(
        x: pageBounds.maxX - (y + height), y: pageBounds.maxY - (x + width), width: height,
        height: width)
    default:
      return CGRect(
        x: pageBounds.minX + x, y: pageBounds.maxY - (y + height), width: width,
        height: height)
    }
  }
}

public actor DocumentLayoutClassifier {
  private enum RasterSource {
    case thumbnail
    case coreGraphics
  }

  public static let shared = DocumentLayoutClassifier()

  private let processorRevision = "pp-doclayout-v3-fp32-coreml-1"
  private var cachedURL: URL?
  private var cachedModel: MLModel?

  public nonisolated static func defaultModelURL(
    bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let path = environment["LECTURA_LAYOUT_MODEL_URL"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return bundle.resourceURL?.appendingPathComponent(
      "PPDocLayoutV3-fp32.mlmodelc", isDirectory: true)
  }

  public func classify(
    at page: PDFPage, rotation: Int, modelURL: URL? = nil
  ) async -> DocumentLayoutResult {
    let started = ProcessInfo.processInfo.systemUptime
    func result(_ regions: [DocumentLayoutRegion], _ pages: UInt8, _ status: String)
      -> DocumentLayoutResult
    {
      DocumentLayoutResult(
        regions: regions, physicalPageCount: pages, status: status,
        elapsedMilliseconds: UInt64((ProcessInfo.processInfo.systemUptime - started) * 1_000),
        processorRevision: processorRevision)
    }
    guard let requestedURL = modelURL ?? Self.defaultModelURL(), requestedURL.isFileURL,
      FileManager.default.fileExists(atPath: requestedURL.path)
    else { return result([], 1, "unavailable") }
    do {
      let model = try model(at: requestedURL)
      let bounds = page.bounds(for: .cropBox)
      guard bounds.width > 0, bounds.height > 0 else { return result([], 1, "degraded") }
      let primary = try predict(model, page: page, crop: nil, source: .thumbnail)
      var source = RasterSource.thumbnail
      var regions = DocumentLayoutPostprocessor.decode(
        classLogits: primary.0, boxes: primary.1, orderLogits: primary.2, pageBounds: bounds,
        pageRotationDegrees: rotation, physicalPageIndex: 0, orderOffset: 0)
      if regions.isEmpty {
        source = .coreGraphics
        let fallback = try predict(model, page: page, crop: nil, source: source)
        regions = DocumentLayoutPostprocessor.decode(
          classLogits: fallback.0, boxes: fallback.1, orderLogits: fallback.2, pageBounds: bounds,
          pageRotationDegrees: rotation, physicalPageIndex: 0, orderOffset: 0)
      }
      guard !regions.isEmpty else { return result([], 1, "degraded") }
      guard
        DocumentLayoutPostprocessor.isPhysicalSpread(
          regions, pageBounds: bounds, pageRotationDegrees: rotation)
      else {
        return result(regions, 1, "completed")
      }
      let left = try predict(model, page: page, crop: 0..<1, source: source)
      let leftRegions = DocumentLayoutPostprocessor.decode(
        classLogits: left.0, boxes: left.1, orderLogits: left.2, pageBounds: bounds,
        pageRotationDegrees: rotation, physicalPageIndex: 0, orderOffset: 0,
        regionOfInterest: CGRect(x: 0, y: 0, width: 0.5, height: 1))
      let right = try predict(model, page: page, crop: 1..<2, source: source)
      let offset =
        (leftRegions.map(\.order).max() ?? UInt32.max) == UInt32.max
        ? 0 : (leftRegions.map(\.order).max() ?? 0) + 1
      let rightRegions = DocumentLayoutPostprocessor.decode(
        classLogits: right.0, boxes: right.1, orderLogits: right.2, pageBounds: bounds,
        pageRotationDegrees: rotation, physicalPageIndex: 1, orderOffset: offset,
        regionOfInterest: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
      guard let splitRegions = Self.combinedSpreadRegions(left: leftRegions, right: rightRegions)
      else { return result([], 2, "degraded") }
      return result(splitRegions, 2, "completed")
    } catch {
      return result([], 1, "degraded")
    }
  }

  private func model(at requestedURL: URL) throws -> MLModel {
    let url = requestedURL.resolvingSymlinksInPath().standardizedFileURL
    if cachedURL == url, let cachedModel { return cachedModel }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = try MLModel(contentsOf: url, configuration: configuration)
    cachedURL = url
    cachedModel = model
    return model
  }

  static func combinedSpreadRegions(
    left: [DocumentLayoutRegion], right: [DocumentLayoutRegion]
  ) -> [DocumentLayoutRegion]? {
    guard !left.isEmpty, !right.isEmpty else { return nil }
    return left + right
  }

  private func predict(
    _ model: MLModel, page: PDFPage, crop: Range<Int>?, source: RasterSource
  ) throws
    -> (MLMultiArray, MLMultiArray, MLMultiArray)
  {
    let input = try pixelValues(for: page, crop: crop, source: source)
    let prediction = try model.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        "pixel_values": MLFeatureValue(multiArray: input)
      ]))
    guard let classLogits = prediction.featureValue(for: "class_logits")?.multiArrayValue,
      let boxes = prediction.featureValue(for: "boxes_cxcywh")?.multiArrayValue,
      let orderLogits = prediction.featureValue(for: "order_logits")?.multiArrayValue
    else { throw CocoaError(.coderInvalidValue) }
    return (classLogits, boxes, orderLogits)
  }

  private func pixelValues(for page: PDFPage, crop: Range<Int>?, source: RasterSource) throws
    -> MLMultiArray
  {
    let image: CGImage?
    switch source {
    case .thumbnail:
      image = page.thumbnail(of: CGSize(width: 800, height: 800), for: .cropBox)
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
    case .coreGraphics:
      let bounds = page.bounds(for: .cropBox)
      let turn = ((page.rotation % 360) + 360) % 360
      let displayWidth = turn % 180 == 0 ? bounds.width : bounds.height
      let displayHeight = turn % 180 == 0 ? bounds.height : bounds.width
      let scale = 800 / max(displayWidth, displayHeight)
      image = PDFPageRasterizer.image(
        of: page,
        pixelSize: CGSize(width: displayWidth * scale, height: displayHeight * scale))
    }
    guard let source = image else { throw CocoaError(.coderInvalidValue) }
    let slice =
      crop.map { range in
        CGRect(
          x: CGFloat(range.lowerBound) * CGFloat(source.width) / 2, y: 0,
          width: CGFloat(source.width) / 2, height: CGFloat(source.height))
      } ?? CGRect(x: 0, y: 0, width: source.width, height: source.height)
    guard let sourceSlice = source.cropping(to: slice.integral),
      let context = CGContext(
        data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 800 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw CocoaError(.coderInvalidValue) }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
    context.interpolationQuality = .high
    context.draw(sourceSlice, in: CGRect(x: 0, y: 0, width: 800, height: 800))
    guard let pixels = context.data else { throw CocoaError(.coderInvalidValue) }
    let input = try MLMultiArray(shape: [1, 3, 800, 800], dataType: .float32)
    let output = input.dataPointer.bindMemory(to: Float32.self, capacity: input.count)
    let rgba = pixels.bindMemory(to: UInt8.self, capacity: 800 * 800 * 4)
    for pixel in 0..<(800 * 800) {
      output[pixel] = Float32(rgba[pixel * 4]) / 255
      output[800 * 800 + pixel] = Float32(rgba[pixel * 4 + 1]) / 255
      output[2 * 800 * 800 + pixel] = Float32(rgba[pixel * 4 + 2]) / 255
    }
    return input
  }
}
