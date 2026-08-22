import AVFoundation
import CoreMedia
import Foundation

@main
struct NativeAudiobookMuxer {
  static func main() async throws {
    guard CommandLine.arguments.count == 4 else { throw MuxError.usage }
    let source = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let chapterSpec = try JSONDecoder().decode(
      [Chapter].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
    let tracks = try await source.loadTracks(withMediaType: .audio)
    guard let track = tracks.first,
      let hint = try await track.load(.formatDescriptions).first
    else { throw MuxError.noAudio }

    let groups = chapterSpec.map { chapter in
      let item = AVMutableMetadataItem()
      item.identifier = .quickTimeUserDataChapter
      item.value = chapter.title as NSString
      item.locale = Locale(identifier: chapter.language)
      return AVTimedMetadataGroup(
        items: [item],
        timeRange: CMTimeRange(
          start: CMTime(seconds: chapter.start, preferredTimescale: 1_000),
          end: CMTime(seconds: chapter.end, preferredTimescale: 1_000)))
    }
    let representativeItems = chapterSpec.map { chapter in
      let item = AVMutableMetadataItem()
      item.identifier = .quickTimeUserDataChapter
      item.value = chapter.title as NSString
      item.locale = Locale(identifier: chapter.language)
      return item
    }
    let representativeGroup = AVTimedMetadataGroup(
      items: representativeItems, timeRange: CMTimeRange(start: .zero, duration: .positiveInfinity))
    guard let metadataHint = representativeGroup.copyFormatDescription() else {
      throw MuxError.invalidChapters
    }
    try? FileManager.default.removeItem(at: outputURL)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let audioInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
    let metadataInput = AVAssetWriterInput(
      mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataHint)
    let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
    guard writer.canAdd(audioInput) else { throw MuxError.detail("audio input unsupported") }
    guard writer.canAdd(metadataInput) else { throw MuxError.detail("metadata input unsupported") }
    writer.add(audioInput)
    writer.add(metadataInput)
    guard audioInput.canAddTrackAssociation(
      withTrackOf: metadataInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
    else { throw MuxError.detail("chapter association unsupported") }
    audioInput.addTrackAssociation(
      withTrackOf: metadataInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)

    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = "Lectura fluida — prueba portátil" as NSString
    let language = AVMutableMetadataItem()
    language.identifier = .commonIdentifierLanguage
    language.value = "mul" as NSString
    writer.metadata = [title, language]

    let reader = try AVAssetReader(asset: source)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(readerOutput) else { throw MuxError.reader }
    reader.add(readerOutput)
    guard writer.startWriting() else { throw writer.error ?? MuxError.detail("start writing") }
    guard reader.startReading() else { throw reader.error ?? MuxError.reader }
    writer.startSession(atSourceTime: .zero)
    while reader.status == .reading {
      if audioInput.isReadyForMoreMediaData {
        guard let buffer = readerOutput.copyNextSampleBuffer() else { break }
        guard audioInput.append(buffer) else { throw writer.error ?? MuxError.detail("append audio") }
      } else {
        try await Task.sleep(for: .milliseconds(1))
      }
    }
    guard reader.status == .completed else { throw reader.error ?? MuxError.reader }
    audioInput.markAsFinished()
    for group in groups {
      var attempts = 0
      while !metadataInput.isReadyForMoreMediaData && attempts < 5_000 {
        guard writer.status == .writing else {
          throw writer.error ?? MuxError.detail("metadata readiness")
        }
        attempts += 1
        try await Task.sleep(for: .milliseconds(1))
      }
      guard metadataInput.isReadyForMoreMediaData, adaptor.append(group) else {
        throw writer.error ?? MuxError.detail("append chapter timeout")
      }
    }
    metadataInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? MuxError.detail("finish") }
  }

  struct Chapter: Decodable { let title: String; let language: String; let start: Double; let end: Double }
  enum MuxError: Error { case usage, noAudio, invalidChapters, reader, detail(String) }
}
