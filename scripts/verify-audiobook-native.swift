import AVFoundation
import Foundation

@main
struct AudiobookNativeCheck {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw CheckError.usage }
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first, duration.seconds.isFinite, duration.seconds > 0 else {
      throw CheckError.invalidAsset
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: duration.seconds / 2, preferredTimescale: 1_000),
      duration: CMTime(seconds: 1, preferredTimescale: 1_000))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { throw CheckError.invalidAsset }
    reader.add(output)
    guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
      throw CheckError.seekFailed
    }
    let localizedChapters = try await asset.loadChapterMetadataGroups(
      bestMatchingPreferredLanguages: ["es", "pt", "en"])
    let titledChapters = asset.chapterMetadataGroups(
      withTitleLocale: Locale(identifier: "en"), containingItemsWithCommonKeys: [.commonKeyTitle])
    let chapterCount = max(localizedChapters.count, titledChapters.count)
    let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
    var timedTitles: [String] = []
    var chapterTimes: [CMTime] = []
    if let metadataTrack = metadataTracks.first {
      let metadataReader = try AVAssetReader(asset: asset)
      let metadataOutput = AVAssetReaderTrackOutput(track: metadataTrack, outputSettings: nil)
      metadataReader.add(metadataOutput)
      let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: metadataOutput)
      if metadataReader.startReading() {
        while let group = adaptor.nextTimedMetadataGroup() {
          timedTitles.append(contentsOf: group.items.compactMap(\.stringValue))
          chapterTimes.append(group.timeRange.start)
        }
      }
    }
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    var navigableChapters = 0
    for time in chapterTimes {
      if await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
        navigableChapters += 1
      }
    }
    let result: [String: Any] = [
      "native_open": true,
      "native_seek": true,
      "native_duration_seconds": duration.seconds,
      "native_audio_tracks": tracks.count,
      "native_chapters": max(chapterCount, timedTitles.count),
      "native_navigable_chapters": navigableChapters,
      "native_timed_titles": timedTitles,
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  enum CheckError: Error { case usage, invalidAsset, seekFailed }
}
