import AVFoundation
import Foundation

public enum AudioServiceError: Error, Equatable, Sendable {
  case invalidAudio
  case bufferFull
  case playbackFailed
}

@MainActor
public final class BoundedAudioPlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var pending = 0
  private var temporaryDirectories: Set<URL> = []
  private var currentFile: AVAudioFile?
  private var currentURL: URL?
  private var currentCompletion: (@MainActor () -> Void)?
  private var segmentStartFrame: AVAudioFramePosition = 0
  private var scheduleID = UUID()
  private let capacity: Int
  private var connectedFormat: AVAudioFormat?

  public init(capacity: Int = 2) {
    self.capacity = max(1, capacity)
    engine.attach(player)
    engine.attach(timePitch)
  }

  /// The whole player → time-pitch → mixer chain must be wired with the format of the audio being
  /// played. The time-pitch effect rejects a mono 24 kHz input feeding the mixer's stereo 44.1 kHz
  /// default (kAudioUnitErr_FormatNotSupported, -10868), so the engine never started and narration
  /// produced no sound at all. The mixer converts to the output device format on its own.
  private func prepareGraph(for format: AVAudioFormat) throws {
    if connectedFormat != format {
      if engine.isRunning { engine.stop() }
      engine.connect(player, to: timePitch, format: format)
      engine.connect(timePitch, to: engine.mainMixerNode, format: format)
      connectedFormat = format
    }
    if !engine.isRunning {
      engine.prepare()
      do { try engine.start() } catch { throw AudioServiceError.playbackFailed }
    }
  }

  public var isPlaying: Bool { player.isPlaying }
  public var rate: Float { timePitch.rate }

  public func pause() { player.pause() }

  public func resume() {
    guard pending > 0, !player.isPlaying else { return }
    player.play()
  }

  public func setRate(_ rate: Float) { timePitch.rate = min(2, max(0.5, rate)) }

  public func seek(by seconds: Double) {
    guard let file = currentFile, let url = currentURL, let completion = currentCompletion else {
      return
    }
    let renderedFrames =
      player.lastRenderTime
      .flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
    let delta = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
    let target = min(max(0, segmentStartFrame + renderedFrames + delta), max(0, file.length - 1))
    let shouldResume = player.isPlaying
    scheduleID = UUID()
    player.stop()
    schedule(file, url: url, startingAt: target, completion: completion)
    if shouldResume { player.play() }
  }

  public func enqueue(_ url: URL, completion: @escaping @MainActor () -> Void) throws {
    guard pending < capacity else { throw AudioServiceError.bufferFull }
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else { throw AudioServiceError.invalidAudio }
    try prepareGraph(for: file.processingFormat)
    pending += 1
    temporaryDirectories.insert(url.deletingLastPathComponent())
    currentFile = file
    currentURL = url
    currentCompletion = completion
    schedule(file, url: url, startingAt: 0, completion: completion)
    if !player.isPlaying { player.play() }
  }

  private func schedule(
    _ file: AVAudioFile, url: URL, startingAt frame: AVAudioFramePosition,
    completion: @escaping @MainActor () -> Void
  ) {
    segmentStartFrame = frame
    let id = UUID()
    scheduleID = id
    player.scheduleSegment(
      file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil
    ) { [weak self] in
      Task { @MainActor in
        guard let self, self.scheduleID == id else { return }
        self.pending = max(0, self.pending - 1)
        let directory = url.deletingLastPathComponent()
        self.temporaryDirectories.remove(directory)
        try? FileManager.default.removeItem(at: directory)
        self.currentFile = nil
        self.currentURL = nil
        self.currentCompletion = nil
        completion()
      }
    }
  }

  public func stop() {
    player.stop()
    engine.stop()
    scheduleID = UUID()
    pending = 0
    currentFile = nil
    currentURL = nil
    currentCompletion = nil
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
  }

}
