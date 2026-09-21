import Foundation

// MARK: - SpeakerProfileBenchmarkDataset

public struct SpeakerProfileBenchmarkDataset: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let observations: [SpeakerProfileBenchmarkObservation]

  public init(
    schemaVersion: Int = currentSchemaVersion,
    observations: [SpeakerProfileBenchmarkObservation]
  ) {
    self.schemaVersion = schemaVersion
    self.observations = observations
  }

  public func validated() throws -> Self {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw SpeakerProfileBenchmarkError.unsupportedSchemaVersion(schemaVersion)
    }
    guard !observations.isEmpty else {
      throw SpeakerProfileBenchmarkError.emptyDataset
    }

    var observationIDs = Set<String>()
    var sequences = Set<Int>()
    var canonicalSpeakerIDs: [String: String] = [:]
    var embeddingDimension: Int?
    var evaluationCount = 0

    for observation in observations {
      guard !observation.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SpeakerProfileBenchmarkError.emptyField("observation.id")
      }
      guard observationIDs.insert(observation.id).inserted else {
        throw SpeakerProfileBenchmarkError.duplicateObservationID(observation.id)
      }
      guard sequences.insert(observation.sequence).inserted else {
        throw SpeakerProfileBenchmarkError.duplicateSequence(observation.sequence)
      }
      guard !observation.speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SpeakerProfileBenchmarkError.emptyField("speakerID in \(observation.id)")
      }
      guard !observation.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SpeakerProfileBenchmarkError.emptyField("meetingID in \(observation.id)")
      }

      let canonicalSpeakerID = observation.speakerID.lowercased()
      if let existing = canonicalSpeakerIDs[canonicalSpeakerID],
         existing != observation.speakerID {
        throw SpeakerProfileBenchmarkError.caseInsensitiveSpeakerCollision(
          existing,
          observation.speakerID
        )
      }
      canonicalSpeakerIDs[canonicalSpeakerID] = observation.speakerID

      try Self.validate(
        embedding: observation.embedding,
        observationID: observation.id,
        expectedDimension: &embeddingDimension
      )
      for candidate in observation.queryEmbeddings {
        var candidateDimension = embeddingDimension
        try Self.validate(
          embedding: candidate,
          observationID: observation.id,
          expectedDimension: &candidateDimension
        )
      }

      if observation.mode != .enrollment {
        evaluationCount += 1
      }
    }

    guard evaluationCount > 0 else {
      throw SpeakerProfileBenchmarkError.missingEvaluation
    }
    return self
  }

  private static func validate(
    embedding: [Float],
    observationID: String,
    expectedDimension: inout Int?
  ) throws {
    guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
      throw SpeakerProfileBenchmarkError.invalidEmbedding(observationID)
    }
    if let expectedDimension, embedding.count != expectedDimension {
      throw SpeakerProfileBenchmarkError.embeddingDimensionMismatch(
        observationID: observationID,
        expected: expectedDimension,
        actual: embedding.count
      )
    }
    expectedDimension = embedding.count
  }
}

// MARK: - SpeakerProfileBenchmarkObservation

public struct SpeakerProfileBenchmarkObservation: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Equatable, Sendable {
    case enrollment
    case confirmedMeeting
    case evaluationOnly
  }

  public let id: String
  public let sequence: Int
  public let speakerID: String
  public let meetingID: String
  public let mode: Mode
  public let embedding: [Float]
  public let candidateEmbeddings: [[Float]]
  public let conditions: [String: String]

  public var queryEmbeddings: [[Float]] {
    candidateEmbeddings.isEmpty ? [embedding] : candidateEmbeddings
  }

  public init(
    id: String,
    sequence: Int,
    speakerID: String,
    meetingID: String,
    mode: Mode,
    embedding: [Float],
    candidateEmbeddings: [[Float]] = [],
    conditions: [String: String] = [:]
  ) {
    self.id = id
    self.sequence = sequence
    self.speakerID = speakerID
    self.meetingID = meetingID
    self.mode = mode
    self.embedding = embedding
    self.candidateEmbeddings = candidateEmbeddings
    self.conditions = conditions
  }

  private enum CodingKeys: String, CodingKey {
    case id, sequence, speakerID, meetingID, mode, embedding, candidateEmbeddings, conditions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sequence = try container.decode(Int.self, forKey: .sequence)
    speakerID = try container.decode(String.self, forKey: .speakerID)
    meetingID = try container.decode(String.self, forKey: .meetingID)
    mode = try container.decode(Mode.self, forKey: .mode)
    embedding = try container.decode([Float].self, forKey: .embedding)
    candidateEmbeddings = try container.decodeIfPresent(
      [[Float]].self,
      forKey: .candidateEmbeddings
    ) ?? []
    conditions = try container.decodeIfPresent(
      [String: String].self,
      forKey: .conditions
    ) ?? [:]
  }
}

// MARK: - SpeakerProfileBenchmarkError

public enum SpeakerProfileBenchmarkError: LocalizedError, Equatable, Sendable {
  case caseInsensitiveSpeakerCollision(String, String)
  case duplicateObservationID(String)
  case duplicateSequence(Int)
  case embeddingDimensionMismatch(observationID: String, expected: Int, actual: Int)
  case emptyDataset
  case emptyField(String)
  case invalidEmbedding(String)
  case invalidMargin(Float)
  case invalidThreshold(Float)
  case missingEvaluation
  case unsupportedSchemaVersion(Int)

  public var errorDescription: String? {
    switch self {
    case let .caseInsensitiveSpeakerCollision(first, second):
      "Speaker IDs must also be unique when ignoring case: \(first), \(second)."

    case let .duplicateObservationID(id):
      "Observation ID \(id) appears more than once."

    case let .duplicateSequence(sequence):
      "Sequence \(sequence) appears more than once."

    case let .embeddingDimensionMismatch(observationID, expected, actual):
      "Observation \(observationID) has \(actual) embedding values; expected \(expected)."

    case .emptyDataset:
      "The benchmark dataset is empty."

    case let .emptyField(field):
      "The benchmark contains an empty \(field)."

    case let .invalidEmbedding(observationID):
      "Observation \(observationID) has an empty or non-finite embedding."

    case let .invalidMargin(margin):
      "Margin \(margin) must be between 0 and 1."

    case let .invalidThreshold(threshold):
      "Threshold \(threshold) must be between -1 and 1."

    case .missingEvaluation:
      "The benchmark needs at least one confirmedMeeting or evaluationOnly observation."

    case let .unsupportedSchemaVersion(version):
      "Unsupported benchmark schema version \(version)."
    }
  }
}

// MARK: - SpeakerProfileBenchmarkReport

public struct SpeakerProfileBenchmarkReport: Codable, Equatable, Sendable {
  public let dataset: SpeakerProfileBenchmarkDatasetSummary
  public let margin: Float
  public let runs: [SpeakerProfileBenchmarkRun]

  public init(
    dataset: SpeakerProfileBenchmarkDatasetSummary,
    margin: Float,
    runs: [SpeakerProfileBenchmarkRun]
  ) {
    self.dataset = dataset
    self.margin = margin
    self.runs = runs
  }
}

// MARK: - SpeakerProfileBenchmarkDatasetSummary

public struct SpeakerProfileBenchmarkDatasetSummary: Codable, Equatable, Sendable {
  public let observations: Int
  public let evaluations: Int
  public let enrollments: Int
  public let speakers: Int
  public let meetings: Int
}

// MARK: - SpeakerProfileBenchmarkRun

public struct SpeakerProfileBenchmarkRun: Codable, Equatable, Sendable {
  public let threshold: Float
  public let legacyAverage: SpeakerProfileBenchmarkAlgorithmResult
  public let representativeBank: SpeakerProfileBenchmarkAlgorithmResult
  public let conditionSlices: [SpeakerProfileBenchmarkConditionSlice]
}

// MARK: - SpeakerProfileBenchmarkAlgorithmResult

public struct SpeakerProfileBenchmarkAlgorithmResult: Codable, Equatable, Sendable {
  public let metrics: SpeakerProfileBenchmarkMetrics
  public let learning: SpeakerProfileBenchmarkLearningSummary
  public let finalProfiles: Int
  public let finalActiveSamples: Int
  public let finalPendingSamples: Int
}

// MARK: - SpeakerProfileBenchmarkConditionSlice

public struct SpeakerProfileBenchmarkConditionSlice: Codable, Equatable, Sendable {
  public let condition: String
  public let legacyAverage: SpeakerProfileBenchmarkMetrics
  public let representativeBank: SpeakerProfileBenchmarkMetrics
}

// MARK: - SpeakerProfileBenchmarkMetrics

public struct SpeakerProfileBenchmarkMetrics: Codable, Equatable, Sendable {
  public let evaluations: Int
  public let knownTrials: Int
  public let unknownTrials: Int
  public let correctKnown: Int
  public let wrongKnown: Int
  public let rejectedKnown: Int
  public let rejectedUnknown: Int
  public let acceptedUnknown: Int
  public let overallAccuracy: Double
  public let knownIdentificationRate: Double
  public let misidentificationRate: Double
  public let falseRejectionRate: Double
  public let falseAcceptanceRate: Double
}

// MARK: - SpeakerProfileBenchmarkLearningSummary

public struct SpeakerProfileBenchmarkLearningSummary: Codable, Equatable, Sendable {
  public let created: Int
  public let addedCoverage: Int
  public let duplicate: Int
  public let pending: Int
}
