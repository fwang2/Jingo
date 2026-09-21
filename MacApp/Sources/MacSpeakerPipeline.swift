import FluidAudio
import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

// MARK: - MacTranscriptionChunk

struct MacTranscriptionChunk: Sendable {
  let text: String
  let startTimeMS: Int64
  let endTimeMS: Int64
  let language: String?

  func bounded(maxDurationMS: Int64) -> [MacTranscriptionChunk] {
    let durationMS = endTimeMS - startTimeMS
    guard maxDurationMS > 0, durationMS > maxDurationMS else { return [self] }

    let partCount = Int(ceil(Double(durationMS) / Double(maxDurationMS)))
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard words.count >= partCount else { return [] }

    return (0 ..< partCount).compactMap { index in
      let wordStart = words.count * index / partCount
      let wordEnd = words.count * (index + 1) / partCount
      guard wordEnd > wordStart else { return nil }

      return MacTranscriptionChunk(
        text: words[wordStart ..< wordEnd].joined(separator: " "),
        startTimeMS: startTimeMS + durationMS * Int64(index) / Int64(partCount),
        endTimeMS: startTimeMS + durationMS * Int64(index + 1) / Int64(partCount),
        language: language
      )
    }
  }
}

// MARK: - MacSpeakerWord

struct MacSpeakerWord: Codable, Equatable, Sendable {
  let text: String
  let startTimeMS: Int64
  let endTimeMS: Int64
}

// MARK: - MacSpeakerTurn

struct MacSpeakerTurn: Codable, Equatable, Sendable {
  let speakerID: String?
  let startTimeMS: Int64
  let endTimeMS: Int64
  let text: String
  let words: [MacSpeakerWord]
}

// MARK: - MacSpeakerDiarizationResult

struct MacSpeakerDiarizationResult: Sendable {
  let intervals: [SpeakerAttributionInterval]
  let speakerEmbeddings: [String: [Float]]
  let speakerEmbeddingCandidates: [String: [[Float]]]

  func enrollmentEmbedding() throws -> [Float] {
    let durations = intervals.reduce(into: [String: Int64]()) { result, interval in
      result[interval.speakerID, default: 0] += max(interval.endTimeMS - interval.startTimeMS, 0)
    }
    return try SpeakerProfileMatcher.enrollmentEmbedding(
      speechDurationMSBySpeaker: durations,
      speakerEmbeddings: speakerEmbeddings
    )
  }
}

// MARK: - MacSpeakerPipeline

actor MacSpeakerPipeline {
  private static let maximumAlignmentChunkDurationMS: Int64 = 30000

  private let forcedAligner: MacForcedAlignmentEngine
  private let diarizer = MacFluidAudioDiarizer()

  init(modelRootURL: URL) {
    forcedAligner = MacForcedAlignmentEngine(modelRootURL: modelRootURL)
  }

  func prepareModels(
    progressHandler: @escaping @Sendable (Double) -> Void
  ) async throws {
    async let prepareAlignment: Void = forcedAligner.prepareModel(progressHandler: progressHandler)
    async let prepareDiarization: Void = diarizer.prepareModels()
    try await prepareAlignment
    try await prepareDiarization
  }

  func diarize(_ fileURL: URL) async throws -> MacSpeakerDiarizationResult {
    try await diarizer.diarize(fileURL)
  }

  func diarize(_ samples: [Float]) async throws -> MacSpeakerDiarizationResult {
    try await diarizer.diarize(samples)
  }

  func alignAndMerge(
    samples: [Float],
    transcript: String,
    chunks: [MacTranscriptionChunk],
    diarization: [SpeakerAttributionInterval]
  ) async throws -> [MacSpeakerTurn] {
    let boundedChunks = chunks.flatMap {
      $0.bounded(maxDurationMS: Self.maximumAlignmentChunkDurationMS)
    }
    guard !boundedChunks.isEmpty else { return [] }

    let words = try await forcedAligner.align(samples: samples, chunks: boundedChunks)
    guard SpeakerAttributionCore.hasSufficientAlignmentCoverage(
      transcript: transcript,
      alignedWordTexts: words.map(\.text)
    ) else {
      return []
    }
    return SpeakerAttributionCore.merge(
      transcript: transcript,
      words: words,
      speakerIntervals: diarization
    )
    .map { turn in
      MacSpeakerTurn(
        speakerID: turn.speakerID,
        startTimeMS: turn.startTimeMS,
        endTimeMS: turn.endTimeMS,
        text: turn.text,
        words: turn.words.map {
          MacSpeakerWord(
            text: $0.text,
            startTimeMS: $0.startTimeMS,
            endTimeMS: $0.endTimeMS
          )
        }
      )
    }
  }
}

// MARK: - MacForcedAlignmentEngine

private actor MacForcedAlignmentEngine {
  private static let modelName = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
  private static let sampleRate = 16000

  private let modelRootURL: URL
  private var model: Qwen3ForcedAlignerModel?

  init(modelRootURL: URL) {
    self.modelRootURL = modelRootURL
  }

  func prepareModel(
    progressHandler: @escaping @Sendable (Double) -> Void
  ) async throws {
    if model != nil {
      progressHandler(1)
      return
    }

    guard let repository = Repo.ID(rawValue: Self.modelName) else {
      throw MacSpeakerPipelineError.invalidForcedAlignmentModelIdentifier
    }

    let cache = HubCache(cacheDirectory: modelRootURL)
    let client = HubClient(cache: cache)
    let modelDirectory = try await ModelUtils.resolveOrDownloadModel(
      client: client,
      cache: cache,
      repoID: repository,
      requiredExtension: "safetensors",
      progressHandler: { progress in
        progressHandler(progress.fractionCompleted)
      }
    )
    try? FileManager.default.removeItem(
      at: cache.repoDirectory(repo: repository, kind: .model)
    )
    model = try await Qwen3ForcedAlignerModel.fromModelDirectory(modelDirectory)
    progressHandler(1)
  }

  func align(
    samples: [Float],
    chunks: [MacTranscriptionChunk]
  ) async throws -> [SpeakerAttributionWord] {
    try await prepareModel { _ in }
    guard let model else {
      throw MacSpeakerPipelineError.forcedAlignmentModelNotLoaded
    }

    var words: [SpeakerAttributionWord] = []
    for chunk in chunks where !chunk.text.isEmpty {
      let startSample = min(
        max(Int(chunk.startTimeMS) * Self.sampleRate / 1000, 0),
        samples.count
      )
      let endSample = min(
        max(Int(chunk.endTimeMS) * Self.sampleRate / 1000, startSample),
        samples.count
      )
      guard endSample > startSample else { continue }

      let result = model.generate(
        audio: MLXArray(Array(samples[startSample ..< endSample])),
        text: chunk.text,
        language: Self.alignmentLanguage(for: chunk)
      )
      words.append(contentsOf: result.items.compactMap { item in
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              item.startTime.isFinite,
              item.endTime.isFinite,
              item.startTime >= 0,
              item.endTime > item.startTime
        else {
          return nil
        }

        let startTimeMS = chunk.startTimeMS + Int64((item.startTime * 1000).rounded())
        let endTimeMS = min(
          chunk.startTimeMS + Int64((item.endTime * 1000).rounded()),
          chunk.endTimeMS
        )
        guard endTimeMS > startTimeMS else { return nil }
        return SpeakerAttributionWord(
          text: text,
          startTimeMS: startTimeMS,
          endTimeMS: endTimeMS
        )
      })
    }
    return words.sorted {
      if $0.startTimeMS == $1.startTimeMS {
        return $0.endTimeMS < $1.endTimeMS
      }
      return $0.startTimeMS < $1.startTimeMS
    }
  }

  private static func alignmentLanguage(for chunk: MacTranscriptionChunk) -> String {
    if chunk.text.unicodeScalars.contains(where: isHanCharacter) {
      // The aligner's Chinese tokenizer also handles embedded space-delimited words,
      // which makes it the safer choice for mixed Chinese/English text.
      return "Chinese"
    }
    return chunk.language?.isEmpty == false ? chunk.language! : "English"
  }

  private static func isHanCharacter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2CEAF:
      true
    default:
      false
    }
  }
}

// MARK: - MacFluidAudioDiarizer

private actor MacFluidAudioDiarizer {
  private static let shortSpeakerSpeechDurationMS: Int64 = 10000

  private static var configuration: OfflineDiarizerConfig {
    var configuration = OfflineDiarizerConfig.default
    configuration.exposeChunkEmbeddings = true
    return configuration
  }

  private let manager = OfflineDiarizerManager(config: MacFluidAudioDiarizer.configuration)
  private var preparationTask: Task<Void, Error>?

  func prepareModels() async throws {
    if let preparationTask {
      try await preparationTask.value
      return
    }

    let preparationTask = Task {
      try await manager.prepareModels()
    }
    self.preparationTask = preparationTask
    do {
      try await preparationTask.value
    } catch {
      self.preparationTask = nil
      throw error
    }
  }

  func diarize(_ fileURL: URL) async throws -> MacSpeakerDiarizationResult {
    try await prepareModels()
    let result = try await manager.process(fileURL)
    return Self.map(result)
  }

  func diarize(_ samples: [Float]) async throws -> MacSpeakerDiarizationResult {
    try await prepareModels()
    let result = try await manager.process(audio: samples)
    return Self.map(result)
  }

  private static func map(_ result: DiarizationResult) -> MacSpeakerDiarizationResult {
    let intervals: [SpeakerAttributionInterval] = result.segments.compactMap {
      segment -> SpeakerAttributionInterval? in
      let speakerID = segment.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !speakerID.isEmpty,
            segment.startTimeSeconds.isFinite,
            segment.endTimeSeconds.isFinite,
            segment.startTimeSeconds >= 0,
            segment.endTimeSeconds > segment.startTimeSeconds
      else {
        return nil
      }
      return SpeakerAttributionInterval(
        speakerID: speakerID,
        startTimeMS: Int64((Double(segment.startTimeSeconds) * 1000).rounded()),
        endTimeMS: Int64((Double(segment.endTimeSeconds) * 1000).rounded())
      )
    }
    .sorted {
      if $0.startTimeMS == $1.startTimeMS {
        return $0.endTimeMS < $1.endTimeMS
      }
      return $0.startTimeMS < $1.startTimeMS
    }

    let validSpeakerIDs = Set(intervals.map(\.speakerID))
    let speakerEmbeddings = (result.speakerDatabase ?? [:]).filter { speakerID, embedding in
      validSpeakerIDs.contains(speakerID)
        && !embedding.isEmpty
        && embedding.allSatisfy(\.isFinite)
    }
    let speechDurationMSBySpeaker = intervals.reduce(into: [String: Int64]()) { durations, interval in
      durations[interval.speakerID, default: 0] += max(
        interval.endTimeMS - interval.startTimeMS,
        0
      )
    }
    var speakerEmbeddingCandidates = speakerEmbeddings.mapValues { [$0] }
    for chunk in result.chunkEmbeddings ?? [] {
      guard let speechDurationMS = speechDurationMSBySpeaker[chunk.speakerId],
            speechDurationMS < Self.shortSpeakerSpeechDurationMS,
            !chunk.embedding256.isEmpty,
            chunk.embedding256.allSatisfy(\.isFinite)
      else {
        continue
      }

      // A short participant's cluster average can be diluted by silence or a nearby
      // speaker. Keep the clean per-window vectors as additional match candidates.
      speakerEmbeddingCandidates[chunk.speakerId, default: []].append(chunk.embedding256)
    }
    return MacSpeakerDiarizationResult(
      intervals: intervals,
      speakerEmbeddings: speakerEmbeddings,
      speakerEmbeddingCandidates: speakerEmbeddingCandidates
    )
  }
}

// MARK: - MacSpeakerPipelineError

private enum MacSpeakerPipelineError: LocalizedError {
  case invalidForcedAlignmentModelIdentifier
  case forcedAlignmentModelNotLoaded

  var errorDescription: String? {
    switch self {
    case .invalidForcedAlignmentModelIdentifier:
      "The forced-alignment model identifier is invalid."
    case .forcedAlignmentModelNotLoaded:
      "The forced-alignment model is not loaded."
    }
  }
}
