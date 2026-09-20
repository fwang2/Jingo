import Common
import ComposableArchitecture
import Dependencies
import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

// MARK: - ForcedAlignmentWord

public struct ForcedAlignmentWord: Equatable, Sendable {
  public let text: String
  public let startTimeMS: Int64
  public let endTimeMS: Int64

  public init(text: String, startTimeMS: Int64, endTimeMS: Int64) {
    self.text = text
    self.startTimeMS = startTimeMS
    self.endTimeMS = endTimeMS
  }
}

// MARK: - ForcedAlignmentResult

public struct ForcedAlignmentResult: Equatable, Sendable {
  public let words: [ForcedAlignmentWord]

  public init(words: [ForcedAlignmentWord]) {
    self.words = words
  }
}

// MARK: - ForcedAlignmentClient

@DependencyClient
public struct ForcedAlignmentClient: Sendable {
  public var prepareModels: @Sendable (
    _ progressCallback: @escaping @Sendable (Double) -> Void
  ) async throws -> Void
  public var align: @Sendable (
    _ fileURL: URL,
    _ segments: [Segment]
  ) async throws -> ForcedAlignmentResult
  public var unloadModel: @Sendable () async -> Void
}

// MARK: DependencyKey

extension ForcedAlignmentClient: DependencyKey {
  public static let testValue = ForcedAlignmentClient(
    prepareModels: { _ in },
    align: { _, _ in ForcedAlignmentResult(words: []) },
    unloadModel: {}
  )

  public static let liveValue: ForcedAlignmentClient = {
    let container = QwenForcedAligner()

    return ForcedAlignmentClient(
      prepareModels: { progressCallback in
        try await container.prepareModels(progressCallback: progressCallback)
      },
      align: { fileURL, segments in
        try await container.align(fileURL, segments: segments)
      },
      unloadModel: {
        await container.unloadModel()
      }
    )
  }()
}

// MARK: - QwenForcedAligner

private actor QwenForcedAligner {
  private static let modelName = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"

  private var model: Qwen3ForcedAlignerModel?

  func prepareModels(
    progressCallback: @escaping @Sendable (Double) -> Void
  ) async throws {
    #if targetEnvironment(simulator)
      throw NSError(
        domain: "ForcedAlignmentClient",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Qwen3 Forced Aligner requires MLX Metal and cannot run in the iOS Simulator.",
        ]
      )
    #else
      if model != nil {
        progressCallback(1)
        return
      }

      guard let repository = Repo.ID(rawValue: Self.modelName) else {
        throw NSError(
          domain: "ForcedAlignmentClient",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Invalid Qwen3 Forced Aligner model identifier."]
        )
      }

      let cache = HubCache(cacheDirectory: TranscriptionStream.modelDirURL)
      let client = HubClient(cache: cache)
      let modelDirectory = try await ModelUtils.resolveOrDownloadModel(
        client: client,
        cache: cache,
        repoID: repository,
        requiredExtension: "safetensors",
        progressHandler: { progress in
          progressCallback(progress.fractionCompleted)
        }
      )
      try? FileManager.default.removeItem(
        at: cache.repoDirectory(repo: repository, kind: .model)
      )

      model = try await Qwen3ForcedAlignerModel.fromModelDirectory(modelDirectory)
      progressCallback(1)
    #endif
  }

  func align(_ fileURL: URL, segments: [Segment]) async throws -> ForcedAlignmentResult {
    try await prepareModels { _ in }

    guard let model else {
      throw NSError(
        domain: "ForcedAlignmentClient",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Qwen3 Forced Aligner is not loaded."]
      )
    }

    let audioBuffer = try AudioProcessor.loadAudio(fromPath: fileURL.path)
    let samples = AudioProcessor.convertBufferToArray(buffer: audioBuffer)
    var alignedWords: [ForcedAlignmentWord] = []

    for segment in segments where !segment.text.isEmpty {
      let startSample = min(
        max(Int(segment.startTimeMS) * TranscriptionStream.sampleRate / 1000, 0),
        samples.count
      )
      let endSample = min(
        max(Int(segment.endTimeMS) * TranscriptionStream.sampleRate / 1000, startSample),
        samples.count
      )
      guard endSample > startSample else { continue }

      let result = model.generate(
        audio: MLXArray(Array(samples[startSample ..< endSample])),
        text: segment.text,
        language: "English"
      )
      alignedWords.append(contentsOf: ForcedAlignmentResultMapper.map(
        result.items,
        offsetMS: segment.startTimeMS,
        maximumEndTimeMS: segment.endTimeMS
      ).words)
    }

    return ForcedAlignmentResult(words: alignedWords)
  }

  func unloadModel() {
    model = nil
    Memory.clearCache()
  }
}

// MARK: - ForcedAlignmentResultMapper

enum ForcedAlignmentResultMapper {
  static func map(
    _ items: [ForcedAlignItem],
    offsetMS: Int64 = 0,
    maximumEndTimeMS: Int64? = nil
  ) -> ForcedAlignmentResult {
    let words = items.compactMap { item -> ForcedAlignmentWord? in
      let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty,
            item.startTime.isFinite,
            item.endTime.isFinite,
            item.startTime >= 0,
            item.endTime > item.startTime
      else {
        return nil
      }

      let startTimeMS = offsetMS + Int64((item.startTime * 1000).rounded())
      let endTimeMS = min(
        offsetMS + Int64((item.endTime * 1000).rounded()),
        maximumEndTimeMS ?? .max
      )
      guard endTimeMS > startTimeMS else { return nil }

      return ForcedAlignmentWord(
        text: text,
        startTimeMS: startTimeMS,
        endTimeMS: endTimeMS
      )
    }
    .sorted {
      if $0.startTimeMS == $1.startTimeMS {
        return $0.endTimeMS < $1.endTimeMS
      }
      return $0.startTimeMS < $1.startTimeMS
    }

    return ForcedAlignmentResult(words: words)
  }
}
