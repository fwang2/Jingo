import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - MacAudioSourceMode

enum MacAudioSourceMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case automatic
  case microphone
  case meetingAudio
  case meetingAndMicrophone

  static let selectableCases: [Self] = [
    .automatic,
    .microphone,
    .meetingAndMicrophone,
  ]

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .automatic:
      "Automatic"

    case .microphone:
      "In-person meeting"

    case .meetingAudio:
      "Mac audio"

    case .meetingAndMicrophone:
      "Online meeting"
    }
  }

  var includesMicrophone: Bool {
    switch self {
    case .automatic, .meetingAndMicrophone, .microphone:
      true

    case .meetingAudio:
      false
    }
  }

  var includesMeetingAudio: Bool {
    switch self {
    case .automatic, .microphone:
      false

    case .meetingAndMicrophone, .meetingAudio:
      true
    }
  }

  var combinesAudioSources: Bool {
    includesMicrophone && includesMeetingAudio
  }

  var requiresScreenCapturePermission: Bool {
    includesMeetingAudio
  }

  func resolved(
    detectedMeeting: Bool,
    canCaptureMeetingAudio: Bool = true
  ) -> Self {
    guard self == .automatic else {
      return self
    }
    return detectedMeeting && canCaptureMeetingAudio ? .meetingAndMicrophone : .microphone
  }
}

// MARK: - MacAudioSource

enum MacAudioSource: Hashable, Sendable {
  case microphone
  case meetingAudio
}

// MARK: - MacCapturedAudioChunk

struct MacCapturedAudioChunk: Sendable {
  let source: MacAudioSource
  let samples: [Float]
  let startUptime: TimeInterval
}

// MARK: - MacAudioTimelineBuffer

struct MacAudioTimelineBuffer {
  private(set) var baseFrame: Int64 = 0
  private(set) var samples: [Float] = []

  var endFrame: Int64 {
    baseFrame + Int64(samples.count)
  }

  mutating func append(_ newSamples: [Float], at startFrame: Int64) {
    guard !newSamples.isEmpty else {
      return
    }

    let effectiveStart = max(startFrame, baseFrame)
    let trimmedCount = Int(max(effectiveStart - startFrame, 0))
    guard trimmedCount < newSamples.count else {
      return
    }
    let incoming = newSamples.dropFirst(trimmedCount)

    if samples.isEmpty {
      baseFrame = effectiveStart
      samples = Array(incoming)
      return
    }

    if effectiveStart >= endFrame {
      let gap = Int(effectiveStart - endFrame)
      if gap > 0 {
        samples.append(contentsOf: repeatElement(0, count: gap))
      }
      samples.append(contentsOf: incoming)
      return
    }

    let destinationOffset = Int(effectiveStart - baseFrame)
    for (offset, sample) in incoming.enumerated() {
      let destinationIndex = destinationOffset + offset
      if destinationIndex < samples.count {
        samples[destinationIndex] = sample
      } else {
        samples.append(sample)
      }
    }
  }

  mutating func take(range: Range<Int64>) -> [Float] {
    guard !range.isEmpty else {
      return []
    }
    var result = Array(repeating: Float.zero, count: Int(range.count))
    let overlapStart = max(range.lowerBound, baseFrame)
    let overlapEnd = min(range.upperBound, endFrame)
    if overlapStart < overlapEnd {
      let sourceStart = Int(overlapStart - baseFrame)
      let destinationStart = Int(overlapStart - range.lowerBound)
      let count = Int(overlapEnd - overlapStart)
      result.replaceSubrange(
        destinationStart ..< destinationStart + count,
        with: samples[sourceStart ..< sourceStart + count]
      )
    }
    discard(before: range.upperBound)
    return result
  }

  private mutating func discard(before frame: Int64) {
    guard frame > baseFrame else {
      return
    }
    let count = min(Int(frame - baseFrame), samples.count)
    samples.removeFirst(count)
    baseFrame += Int64(count)
    if samples.isEmpty {
      baseFrame = max(baseFrame, frame)
    }
  }
}

// MARK: - MacRealtimeAudioMixer

final class MacRealtimeAudioMixer: @unchecked Sendable {
  static let sampleRate = 16000.0
  private static let outputFrameCount: Int64 = 1600
  private static let outputDelay: TimeInterval = 0.2

  private let queue = DispatchQueue(label: "com.feiyiwang.Jingo.audio-mixer")
  private var sourceBuffers: [MacAudioSource: MacAudioTimelineBuffer] = [:]
  private var recordingStartUptime: TimeInterval?
  private var nextOutputFrame: Int64 = 0
  private var timer: DispatchSourceTimer?
  private var output: (@Sendable ([Float]) -> Void)?

  func start(output: @escaping @Sendable ([Float]) -> Void) {
    queue.sync {
      sourceBuffers = [:]
      recordingStartUptime = ProcessInfo.processInfo.systemUptime
      nextOutputFrame = 0
      self.output = output

      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + Self.outputDelay, repeating: 0.1)
      timer.setEventHandler { [weak self] in
        self?.emitAvailableFrames()
      }
      self.timer = timer
      timer.resume()
    }
  }

  func append(_ chunk: MacCapturedAudioChunk) {
    queue.async { [weak self] in
      guard let self, let recordingStartUptime else {
        return
      }
      let relativeStart = max(chunk.startUptime - recordingStartUptime, 0)
      let startFrame = Int64((relativeStart * Self.sampleRate).rounded())
      var buffer = sourceBuffers[chunk.source] ?? MacAudioTimelineBuffer()
      buffer.append(chunk.samples, at: startFrame)
      sourceBuffers[chunk.source] = buffer
    }
  }

  func stop() {
    queue.sync {
      timer?.setEventHandler {}
      timer?.cancel()
      timer = nil

      let finalFrame = sourceBuffers.values.map(\.endFrame).max() ?? nextOutputFrame
      while nextOutputFrame < finalFrame {
        let endFrame = min(nextOutputFrame + Self.outputFrameCount, finalFrame)
        emit(range: nextOutputFrame ..< endFrame)
        nextOutputFrame = endFrame
      }

      sourceBuffers = [:]
      recordingStartUptime = nil
      output = nil
    }
  }

  private func emitAvailableFrames() {
    guard let recordingStartUptime else {
      return
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - recordingStartUptime - Self.outputDelay
    let availableFrame = Int64(max(elapsed, 0) * Self.sampleRate)
    while nextOutputFrame + Self.outputFrameCount <= availableFrame {
      let endFrame = nextOutputFrame + Self.outputFrameCount
      emit(range: nextOutputFrame ..< endFrame)
      nextOutputFrame = endFrame
    }
  }

  private func emit(range: Range<Int64>) {
    var mixed = Array(repeating: Float.zero, count: Int(range.count))
    for source in MacAudioSource.allCases {
      var buffer = sourceBuffers[source] ?? MacAudioTimelineBuffer()
      let sourceSamples = buffer.take(range: range)
      sourceBuffers[source] = buffer
      for index in mixed.indices {
        mixed[index] = min(max(mixed[index] + sourceSamples[index], -1), 1)
      }
    }
    output?(mixed)
  }
}

// MARK: - MacAudioSource + CaseIterable

extension MacAudioSource: CaseIterable {}

// MARK: - MacSystemAudioCapture

final class MacSystemAudioCapture: NSObject, @unchecked Sendable {
  private let captureQueue = DispatchQueue(label: "com.feiyiwang.Jingo.system-audio")
  private var stream: SCStream?
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var chunkHandler: (@Sendable (MacCapturedAudioChunk) -> Void)?
  private var failureHandler: (@Sendable (String) -> Void)?

  func start(
    chunkHandler: @escaping @Sendable (MacCapturedAudioChunk) -> Void,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws {
    guard CGPreflightScreenCaptureAccess() else {
      throw MacSystemAudioCaptureError.permissionDenied
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
      ?? content.displays.first
    else {
      throw MacSystemAudioCaptureError.noDisplayAvailable
    }

    let currentBundleIdentifier = Bundle.main.bundleIdentifier
    let excludedApplications = content.applications.filter {
      $0.bundleIdentifier == currentBundleIdentifier
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: excludedApplications,
      exceptingWindows: []
    )
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = Int(MacRealtimeAudioMixer.sampleRate)
    configuration.channelCount = 1
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3

    self.chunkHandler = chunkHandler
    self.failureHandler = failureHandler
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() async {
    guard let stream else {
      return
    }
    chunkHandler = nil
    failureHandler = nil
    do {
      try await stream.stopCapture()
      try stream.removeStreamOutput(self, type: .audio)
    } catch {
      // Capture may already have stopped because the selected source disappeared.
    }
    self.stream = nil
    converter = nil
    converterInputFormat = nil
  }

  private func handle(_ sampleBuffer: CMSampleBuffer) throws {
    guard sampleBuffer.isValid,
          var description = sampleBuffer.formatDescription?.audioStreamBasicDescription
    else {
      return
    }
    guard let inputFormat = withUnsafePointer(
      to: &description,
      { AVAudioFormat(streamDescription: $0) }
    ) else {
      return
    }

    let duration = Double(sampleBuffer.numSamples) / inputFormat.sampleRate
    let startUptime = ProcessInfo.processInfo.systemUptime - duration
    try sampleBuffer.withAudioBufferList { audioBufferList, _ in
      guard let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        bufferListNoCopy: audioBufferList.unsafePointer
      ) else {
        throw MacSystemAudioCaptureError.invalidAudioBuffer
      }

      let outputBuffer = try convertedBuffer(from: inputBuffer)
      guard let channel = outputBuffer.floatChannelData?.pointee else {
        return
      }
      let samples = Array(
        UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
      )
      chunkHandler?(MacCapturedAudioChunk(
        source: .meetingAudio,
        samples: samples,
        startUptime: startUptime
      ))
    }
  }

  private func convertedBuffer(from inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: MacRealtimeAudioMixer.sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw MacSystemAudioCaptureError.audioConversionFailed
    }
    if inputBuffer.format == outputFormat {
      return inputBuffer
    }

    if converter == nil || converterInputFormat != inputBuffer.format {
      converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
      converterInputFormat = inputBuffer.format
    }
    guard let converter else {
      throw MacSystemAudioCaptureError.audioConversionFailed
    }

    let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
    let capacity = max(1, Int(ceil(Double(inputBuffer.frameLength) * ratio)))
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: AVAudioFrameCount(capacity)
    ) else {
      throw MacSystemAudioCaptureError.audioConversionFailed
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
      guard !suppliedInput else {
        status.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      status.pointee = .haveData
      return inputBuffer
    }
    guard status != .error else {
      throw conversionError ?? MacSystemAudioCaptureError.audioConversionFailed
    }
    return outputBuffer
  }
}

// MARK: SCStreamOutput

extension MacSystemAudioCapture: SCStreamOutput {
  func stream(
    _: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .audio else {
      return
    }
    do {
      try handle(sampleBuffer)
    } catch {
      failureHandler?(error.localizedDescription)
    }
  }
}

// MARK: SCStreamDelegate

extension MacSystemAudioCapture: SCStreamDelegate {
  func stream(_: SCStream, didStopWithError error: any Error) {
    failureHandler?(error.localizedDescription)
  }
}

// MARK: - MacSystemAudioCaptureError

enum MacSystemAudioCaptureError: LocalizedError {
  case permissionDenied
  case noDisplayAvailable
  case invalidAudioBuffer
  case audioConversionFailed

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Mac audio capture requires Screen & System Audio Recording access."

    case .noDisplayAvailable:
      "No display is available for Mac audio capture."

    case .invalidAudioBuffer:
      "Mac audio returned an invalid buffer."

    case .audioConversionFailed:
      "Mac audio could not be converted to the transcription format."
    }
  }
}
