import Accelerate
import AVFoundation
import Common
import Foundation

public final class AudioProcessor: @unchecked Sendable {
  static let sampleRate = 16000

  private let lock = NSLock()
  private var storedAudioSamples: ContiguousArray<Float> = []
  private var storedAudioEnergy: [(relative: Float, average: Float)] = []
  private var audioEngine: AVAudioEngine?

  let minBufferLength = Int(Double(sampleRate) * 0.1)

  public init() {}

  var audioSamples: ContiguousArray<Float> {
    lock.withLock { storedAudioSamples }
  }

  var relativeEnergy: [Float] {
    lock.withLock { storedAudioEnergy.map(\.relative) }
  }

  func drainAudioSamples() -> [Float] {
    lock.withLock {
      let samples = Array(storedAudioSamples)
      storedAudioSamples.removeAll(keepingCapacity: true)
      return samples
    }
  }

  func startFileRecording(
    rawBufferCallback: (@Sendable (AVAudioPCMBuffer, [Float]) -> Void)? = nil
  ) throws -> AVAudioConverter {
    lock.withLock {
      storedAudioSamples = []
      storedAudioEnergy = []
    }

    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    let hardwareSampleRate = inputNode.inputFormat(forBus: 0).sampleRate
    guard hardwareSampleRate > 0, inputFormat.channelCount > 0,
          let nodeFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat,
            sampleRate: hardwareSampleRate,
            channels: inputFormat.channelCount,
            interleaved: inputFormat.isInterleaved
          )
    else {
      throw AudioProcessingError.audioProcessingFailed("The selected microphone has no active audio format.")
    }

    guard let desiredFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(Self.sampleRate),
      channels: 1,
      interleaved: false
    ) else {
      throw AudioProcessingError.audioProcessingFailed("Failed to create the 16 kHz mono format.")
    }

    guard let converter = AVAudioConverter(from: nodeFormat, to: desiredFormat) else {
      throw AudioProcessingError.audioProcessingFailed("Failed to create the microphone audio converter.")
    }

    inputNode.installTap(
      onBus: 0,
      bufferSize: AVAudioFrameCount(minBufferLength),
      format: nodeFormat
    ) { [weak self] inputBuffer, _ in
      guard let self else { return }

      do {
        let convertedBuffer = try Self.resampleBuffer(inputBuffer, with: converter)
        let samples = Self.convertBufferToArray(buffer: convertedBuffer)
        processBuffer(samples)
        rawBufferCallback?(inputBuffer, samples)
      } catch {
        logs.error("Failed to convert microphone audio: \(error)")
      }
    }

    audioEngine.prepare()
    try audioEngine.start()
    self.audioEngine = audioEngine
    return converter
  }

  func pauseRecording() {
    audioEngine?.pause()
  }

  func resumeRecordingLive() throws {
    try audioEngine?.start()
  }

  func stopRecording() {
    guard let audioEngine else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    audioEngine.reset()
    self.audioEngine = nil
  }

  private func processBuffer(_ samples: [Float]) {
    guard !samples.isEmpty else { return }

    lock.withLock {
      let referenceEnergy = storedAudioEnergy.suffix(20).map(\.average).min()
      let averageEnergy = Self.averageEnergy(of: samples)
      let relativeEnergy = Self.relativeEnergy(of: averageEnergy, relativeTo: referenceEnergy)
      storedAudioSamples.append(contentsOf: samples)
      if storedAudioSamples.count > Self.sampleRate * 65 {
        storedAudioSamples.removeFirst(Self.sampleRate * 5)
      }
      storedAudioEnergy.append((relativeEnergy, averageEnergy))
    }
  }

  static func requestRecordPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  static func loadAudio(fromPath audioFilePath: String) throws -> AVAudioPCMBuffer {
    guard FileManager.default.fileExists(atPath: audioFilePath) else {
      throw AudioProcessingError.loadAudioFailed("Audio file does not exist at \(audioFilePath).")
    }

    let audioFile = try AVAudioFile(
      forReading: URL(fileURLWithPath: audioFilePath),
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    guard let inputBuffer = AVAudioPCMBuffer(
      pcmFormat: audioFile.processingFormat,
      frameCapacity: AVAudioFrameCount(audioFile.length)
    ) else {
      throw AudioProcessingError.loadAudioFailed("Failed to allocate an audio buffer.")
    }
    try audioFile.read(into: inputBuffer)

    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(sampleRate),
      channels: 1,
      interleaved: false
    ) else {
      throw AudioProcessingError.loadAudioFailed("Failed to create the 16 kHz mono format.")
    }

    if inputBuffer.format.sampleRate == outputFormat.sampleRate,
       inputBuffer.format.channelCount == outputFormat.channelCount {
      return inputBuffer
    }

    guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
      throw AudioProcessingError.loadAudioFailed("Failed to create an audio converter.")
    }
    return try resampleBuffer(inputBuffer, with: converter)
  }

  static func resampleBuffer(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter
  ) throws -> AVAudioPCMBuffer {
    let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = max(1, Int(ceil(Double(buffer.frameLength) * sampleRateRatio)))
    guard let convertedBuffer = AVAudioPCMBuffer(
      pcmFormat: converter.outputFormat,
      frameCapacity: AVAudioFrameCount(capacity)
    ) else {
      throw AudioProcessingError.audioProcessingFailed("Failed to allocate the converted audio buffer.")
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outputStatus in
      if suppliedInput {
        outputStatus.pointee = .endOfStream
        return nil
      }
      suppliedInput = true
      outputStatus.pointee = .haveData
      return buffer
    }

    if status == .error {
      throw AudioProcessingError.audioProcessingFailed(
        conversionError?.localizedDescription ?? "Unknown audio conversion error."
      )
    }
    return convertedBuffer
  }

  static func convertBufferToArray(buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?.pointee else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }

  static func isVoiceDetected(
    in relativeEnergy: [Float],
    nextBufferInSeconds: Float,
    silenceThreshold: Float
  ) -> Bool {
    let valuesToConsider = max(1, Int(nextBufferInSeconds / 0.1))
    return relativeEnergy.suffix(valuesToConsider).contains { $0 > silenceThreshold }
  }

  private static func averageEnergy(of samples: [Float]) -> Float {
    var energy: Float = 0
    vDSP_rmsqv(samples, 1, &energy, vDSP_Length(samples.count))
    return energy
  }

  private static func relativeEnergy(of energy: Float, relativeTo reference: Float?) -> Float {
    let safeEnergy = max(energy, 1e-8)
    let safeReference = max(reference ?? 1e-3, 1e-8)
    let decibels = 20 * log10(safeEnergy)
    let referenceDecibels = 20 * log10(safeReference)
    let normalized = (decibels - referenceDecibels) / -referenceDecibels
    return max(0, min(normalized, 1))
  }
}
