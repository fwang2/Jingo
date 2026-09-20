import ComposableArchitecture
import Dependencies
import FluidAudio
import Foundation

// MARK: - SpeakerDiarizationSegment

public struct SpeakerDiarizationSegment: Equatable, Sendable {
  public let speakerID: String
  public let startTimeMS: Int64
  public let endTimeMS: Int64
  public let qualityScore: Float

  public init(
    speakerID: String,
    startTimeMS: Int64,
    endTimeMS: Int64,
    qualityScore: Float
  ) {
    self.speakerID = speakerID
    self.startTimeMS = startTimeMS
    self.endTimeMS = endTimeMS
    self.qualityScore = qualityScore
  }
}

// MARK: - SpeakerDiarizationResult

public struct SpeakerDiarizationResult: Equatable, Sendable {
  public let segments: [SpeakerDiarizationSegment]
  public let speakerEmbeddings: [String: [Float]]

  public var speakerCount: Int {
    Set(segments.map(\.speakerID)).count
  }

  public init(
    segments: [SpeakerDiarizationSegment],
    speakerEmbeddings: [String: [Float]] = [:]
  ) {
    self.segments = segments
    self.speakerEmbeddings = speakerEmbeddings
  }

  public func enrollmentEmbedding() throws -> [Float] {
    let durations = segments.reduce(into: [String: Int64]()) { result, segment in
      result[segment.speakerID, default: 0] += max(segment.endTimeMS - segment.startTimeMS, 0)
    }
    return try SpeakerProfileMatcher.enrollmentEmbedding(
      speechDurationMSBySpeaker: durations,
      speakerEmbeddings: speakerEmbeddings
    )
  }
}

// MARK: - SpeakerDiarizationClient

@DependencyClient
public struct SpeakerDiarizationClient: Sendable {
  public var prepareModels: @Sendable () async throws -> Void
  public var diarize: @Sendable (
    _ fileURL: URL,
    _ progressCallback: @escaping @Sendable (Double) -> Void
  ) async throws -> SpeakerDiarizationResult
  public var unloadModels: @Sendable () async -> Void
}

// MARK: DependencyKey

extension SpeakerDiarizationClient: DependencyKey {
  public static let testValue = SpeakerDiarizationClient(
    prepareModels: {},
    diarize: { _, _ in SpeakerDiarizationResult(segments: []) },
    unloadModels: {}
  )

  public static let liveValue: SpeakerDiarizationClient = {
    let container = FluidAudioSpeakerDiarizer()

    return SpeakerDiarizationClient(
      prepareModels: {
        try await container.prepareModels()
      },
      diarize: { fileURL, progressCallback in
        try await container.diarize(fileURL, progressCallback: progressCallback)
      },
      unloadModels: {
        await container.unloadModels()
      }
    )
  }()
}

// MARK: - FluidAudioSpeakerDiarizer

private actor FluidAudioSpeakerDiarizer {
  private var manager: OfflineDiarizerManager?
  private var preparationTask: Task<Void, Error>?

  func prepareModels() async throws {
    if let preparationTask {
      try await preparationTask.value
      return
    }

    let manager = OfflineDiarizerManager(config: .default)
    self.manager = manager
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

  func diarize(
    _ fileURL: URL,
    progressCallback: @escaping @Sendable (Double) -> Void
  ) async throws -> SpeakerDiarizationResult {
    try await prepareModels()

    guard let manager else {
      throw NSError(
        domain: "SpeakerDiarizationClient",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "FluidAudio diarization models are not loaded."]
      )
    }

    let result = try await manager.process(fileURL) { completed, total in
      progressCallback(SpeakerDiarizationProgress.fraction(completed: completed, total: total))
    }

    return SpeakerDiarizationResultMapper.map(
      result.segments,
      speakerEmbeddings: result.speakerDatabase ?? [:]
    )
  }

  func unloadModels() {
    preparationTask?.cancel()
    preparationTask = nil
    manager = nil
  }
}

// MARK: - SpeakerDiarizationProgress

enum SpeakerDiarizationProgress {
  static func fraction(completed: Int, total: Int) -> Double {
    guard total > 0 else { return 0 }
    return min(max(Double(completed) / Double(total), 0), 1)
  }
}

// MARK: - SpeakerDiarizationResultMapper

enum SpeakerDiarizationResultMapper {
  static func map(
    _ segments: [TimedSpeakerSegment],
    speakerEmbeddings: [String: [Float]] = [:]
  ) -> SpeakerDiarizationResult {
    let mappedSegments = segments.compactMap { segment -> SpeakerDiarizationSegment? in
      let speakerID = segment.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
      let startTime = segment.startTimeSeconds
      let endTime = segment.endTimeSeconds

      guard !speakerID.isEmpty,
            startTime.isFinite,
            endTime.isFinite,
            startTime >= 0,
            endTime > startTime
      else {
        return nil
      }

      return SpeakerDiarizationSegment(
        speakerID: speakerID,
        startTimeMS: Int64((Double(startTime) * 1000).rounded()),
        endTimeMS: Int64((Double(endTime) * 1000).rounded()),
        qualityScore: segment.qualityScore
      )
    }
    .sorted {
      if $0.startTimeMS == $1.startTimeMS {
        return $0.endTimeMS < $1.endTimeMS
      }
      return $0.startTimeMS < $1.startTimeMS
    }

    let validSpeakerIDs = Set(mappedSegments.map(\.speakerID))
    let mappedEmbeddings = speakerEmbeddings.filter { speakerID, embedding in
      validSpeakerIDs.contains(speakerID)
        && !embedding.isEmpty
        && embedding.allSatisfy(\.isFinite)
    }

    return SpeakerDiarizationResult(
      segments: mappedSegments,
      speakerEmbeddings: mappedEmbeddings
    )
  }
}
