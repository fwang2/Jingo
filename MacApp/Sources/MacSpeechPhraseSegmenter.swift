import Foundation

// MARK: - MacSpeechPhrase

struct MacSpeechPhrase: Equatable, Sendable {
  let samples: [Float]
  let startSample: Int64
  let endSample: Int64
}

// MARK: - MacSpeechPhraseSegmenter

/// Converts streaming VAD probabilities into bounded transcription phrases.
///
/// The segmenter keeps a short pre-roll so speech onsets are not clipped, waits
/// for a stable pause before closing a phrase, and periodically flushes long
/// speech so transcription feedback does not stall indefinitely.
struct MacSpeechPhraseSegmenter: Sendable {
  struct Configuration: Sendable {
    var sampleRate = 16000
    var speechThreshold: Float = 0.5
    var minimumSpeechDuration: TimeInterval = 0.25
    var silenceDuration: TimeInterval = 0.6
    var speechPadding: TimeInterval = 0.1
    var preRollDuration: TimeInterval = 0.2
    var maximumPhraseDuration: TimeInterval = 7
  }

  private let configuration: Configuration
  private var preRoll: [Float] = []
  private var phraseSamples: [Float] = []
  private var phraseStartSample: Int64 = 0
  private var processedSampleCount: Int64 = 0
  private var detectedSpeechSampleCount = 0
  private var trailingSilenceSampleCount = 0

  init(configuration: Configuration = .init()) {
    self.configuration = configuration
  }

  mutating func consume(
    samples: [Float],
    speechProbability: Float
  ) -> MacSpeechPhrase? {
    guard !samples.isEmpty else {
      return nil
    }
    let blockStartSample = processedSampleCount
    processedSampleCount += Int64(samples.count)
    let isSpeech = speechProbability >= configuration.speechThreshold

    if phraseSamples.isEmpty {
      guard isSpeech else {
        appendToPreRoll(samples)
        return nil
      }

      phraseStartSample = max(blockStartSample - Int64(preRoll.count), 0)
      phraseSamples = preRoll + samples
      preRoll.removeAll(keepingCapacity: true)
      detectedSpeechSampleCount = samples.count
      trailingSilenceSampleCount = 0
    } else {
      phraseSamples.append(contentsOf: samples)
      if isSpeech {
        detectedSpeechSampleCount += samples.count
        trailingSilenceSampleCount = 0
      } else {
        trailingSilenceSampleCount += samples.count
      }
    }

    if trailingSilenceSampleCount >= sampleCount(configuration.silenceDuration) {
      return finishPhrase(keepingTrailingPadding: true)
    }
    if phraseSamples.count >= sampleCount(configuration.maximumPhraseDuration) {
      return finishPhrase(keepingTrailingPadding: false)
    }
    return nil
  }

  mutating func flush() -> MacSpeechPhrase? {
    finishPhrase(keepingTrailingPadding: true)
  }

  private mutating func finishPhrase(
    keepingTrailingPadding: Bool
  ) -> MacSpeechPhrase? {
    guard !phraseSamples.isEmpty else {
      return nil
    }

    let minimumSpeechSamples = sampleCount(configuration.minimumSpeechDuration)
    let shouldEmit = detectedSpeechSampleCount >= minimumSpeechSamples
    let paddingSamples = keepingTrailingPadding
      ? min(trailingSilenceSampleCount, sampleCount(configuration.speechPadding))
      : 0
    let samplesToTrim = max(trailingSilenceSampleCount - paddingSamples, 0)
    let emittedCount = max(phraseSamples.count - samplesToTrim, 0)
    let emittedSamples = Array(phraseSamples.prefix(emittedCount))
    let phrase = shouldEmit && !emittedSamples.isEmpty
      ? MacSpeechPhrase(
        samples: emittedSamples,
        startSample: phraseStartSample,
        endSample: phraseStartSample + Int64(emittedSamples.count)
      )
      : nil

    let nextPreRollCount = min(sampleCount(configuration.preRollDuration), phraseSamples.count)
    preRoll = Array(phraseSamples.suffix(nextPreRollCount))
    phraseSamples.removeAll(keepingCapacity: true)
    detectedSpeechSampleCount = 0
    trailingSilenceSampleCount = 0
    return phrase
  }

  private mutating func appendToPreRoll(_ samples: [Float]) {
    preRoll.append(contentsOf: samples)
    let limit = sampleCount(configuration.preRollDuration)
    if preRoll.count > limit {
      preRoll.removeFirst(preRoll.count - limit)
    }
  }

  private func sampleCount(_ duration: TimeInterval) -> Int {
    max(Int((duration * Double(configuration.sampleRate)).rounded()), 1)
  }
}
